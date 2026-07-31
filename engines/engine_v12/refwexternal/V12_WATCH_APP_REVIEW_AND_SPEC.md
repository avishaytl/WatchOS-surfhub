# V12 Watch-App Integration — Review, Corrections & Expanded Spec

Review of the app team's "Engine V12 End-to-End Workflow Summary" against the
validated algorithm work (`core/jumpEngineV12.ts` + `core/JumpEngineV12.swift`,
`V12_INSTANT_ARCHITECTURE.md`, `LOG5_RECORDING_FORMAT.md`). The team's wiring is
**solid and mostly correct** — this document confirms what is right, fixes what is
mis-stated, and expands the areas the brief emphasised: **watchOS performance +
maximum delta-altitude rate + the different altitude APIs + combining several
paths for Δh**, plus the offline-within-5 s reconstruction, the as-built
algorithm, and the LOG5 binary recording requirement. Practical Swift throughout.

Legend: ✅ correct · ⚠️ correction needed · ➕ addition.

---

## 1. Verdict on the team's plan (section by section)

| § | Verdict | Note |
|---|---|---|
| 1 What V12 is | ⚠️ | Height source listed as `relativeAltitude` **only**. That is the SMOOTHED, lagged channel — the single most important correction. See §2. |
| 2 Code map | ✅ | Good separation (pure engine / adapter / producer / logger). |
| 3 Settings→startup + readiness | ✅ | Readiness gates are right. ➕ add absolute-altitude availability probe (§2), thermal/low-power awareness (§3). |
| 4 Sensor pipeline | ✅ mostly | `IMUSample` carries pressure + relativeAltitude — good. ⚠️ also carry **absolute altitude** + its own timestamp; feed the fit from it (§2). |
| 5 Adapter flow | ✅ | Serial `pipelineQueue` is correct. ➕ ensure the barometer handlers run at max QoS (§3). |
| 6 Algorithm | ✅ good outline | ⚠️ several details are the OLD design — landing is now two-stage, height is a FREE parabola, apex is the vertex. See §6. |
| 7 Instant + refine | ✅ | Two-sided drift refit + model selection described correctly. ➕ note the ≤5 s budget explicitly (§5). |
| 8 Logging | ⚠️ | Header carries `schemaVersion`/`engineVersion` — good, but the **stream format must be KSLG v2** (per-callback, multi-channel) or the 0.36 Hz pathology returns. See §7. |
| 9 Fallback | ✅ | Correct. ➕ add a fallback when absolute altitude is unavailable → pressure-derived, not straight to v11 (§2). |
| 10 Tests | ✅ | ➕ add negative controls (crash, no-jump, drift) + a channel-lag check (§8). |
| 11 Readiness | ✅ | The remaining-validation list is right; §8 makes it concrete. |

---

## 2. ⚠️ THE height-source correction — relative vs pressure vs absolute (and combining them)

**The plan uses `CMAltimeter.relativeAltitude` as the only height source. That is
the wrong channel for a fast jump.** Measured + field-observed finding:

- `relativeAltitude` is Apple's **cumulative, drift-managed, SMOOTHED** value. It
  visibly changes only every ~2–3 s (the smoothing, not the sensor). For a 1–2 s
  jump it **lags and under-reads** — in our demo it peaked at 2.23 m @ 3.2 s where
  the truth was 3.14 m @ 2.4 s.
- The barometer's **fast delta** is surfaced with least lag by:
  - **`CMAltimeter.startAbsoluteAltitudeUpdates`** — a SEPARATE, faster stream
    (field-observed to track height changes in real time). Its slow sea-level
    reference offset is *constant across a 1–2 s jump*, so it **cancels** against
    the per-jump water anchor, leaving the fast delta. **This is V12's default.**
  - **`CMAltitudeData.pressure`** (kPa, delivered in the relativeAltitude
    callback) — closer-to-raw; `Δh ≈ −8.43 m/hPa · Δp`. Lower-lag than the
    smoothed relative, same 1 Hz cadence.

**Why the offset cancels (the key insight):** V12 anchors every jump to a local
water level (median of the ~4 baro samples before the yank) and reports
`apex − anchor`. Any slow reference offset (GPS/weather in absolute; the arbitrary
zero in relative) is the same at the anchor and the apex over 1–2 s, so it drops
out of the subtraction. The choice of channel is therefore about **lag**, not
absolute accuracy — which is exactly why the fast (absolute/pressure) channels win.

### Combining multiple paths for Δh

Record all three and let a per-jump arbiter (or the field LOG5) pick the best:

1. **Primary:** absolute-altitude delta (fastest, offset-cancelled).
2. **Fallback:** pressure-derived delta (when absolute is unavailable — some
   configs, or `isAbsoluteAltitudeAvailable() == false`).
3. **Safety net / cross-check:** relativeAltitude (always available; use it to
   sanity-bound the fast channels — if absolute and pressure disagree with a
   smoothed relative by more than a few σ, flag low confidence).

The engine's `BaroSource` enum already models this: `{ relativeAltitude,
pressureDerived, absoluteAltitude }`, default `.absoluteAltitude` with a
pressure fallback.

### Swift — acquire all three, feed the fast one, record everything

```swift
// availability first — absolute is a separate capability from relative
guard CMAltimeter.isRelativeAltitudeAvailable() else { throw V12Error.noAltimeter }
let hasAbsolute = CMAltimeter.isAbsoluteAltitudeAvailable()

enum BaroSource { case relativeAltitude, pressureDerived, absoluteAltitude }
var baroSource: BaroSource = hasAbsolute ? .absoluteAltitude : .pressureDerived

var pressureAnchorHpa: Double? = nil
var absAnchorM: Double? = nil

// (1) relative + pressure — ONE callback, on a dedicated max-QoS queue (see §3)
altimeter.startRelativeAltitudeUpdates(to: altQueue) { data, _ in
    guard let d = data else { return }
    let t = d.timestamp                          // sensor-monotonic — never wall clock
    let relAlt = d.relativeAltitude.doubleValue  // SMOOTHED (lagged)
    let hPa = d.pressure.doubleValue * 10.0       // kPa → hPa
    if pressureAnchorHpa == nil { pressureAnchorHpa = hPa }
    let pDeriv = -(hPa - pressureAnchorHpa!) * 8.43   // FAST candidate

    switch baroSource {
    case .relativeAltitude: pipeline.addBaro(t: t, relAltM: relAlt)
    case .pressureDerived:  pipeline.addBaro(t: t, relAltM: pDeriv)
    case .absoluteAltitude: break                 // fed from the faster stream below
    }
    recorder?.baro(t: t, relAlt: relAlt, pressureHpa: hPa)   // LOG5: record BOTH
}

// (2) absolute — SEPARATE faster stream; offset cancels against the jump anchor
if hasAbsolute {
    altimeter.startAbsoluteAltitudeUpdates(to: altQueue) { data, _ in
        guard let d = data else { return }
        if absAnchorM == nil { absAnchorM = d.altitude }
        if baroSource == .absoluteAltitude {
            pipeline.addBaro(t: d.timestamp, relAltM: d.altitude - absAnchorM!)
        }
        recorder?.absAlt(t: d.timestamp, altM: d.altitude,
                         accuracy: d.accuracy, precision: d.precision)  // LOG5
    }
}
```

> `Needs Verification` on-device (LOG5, §8): the exact absolute-vs-relative
> cadence and which channel is lowest-lag on a real jump. Build for absolute,
> record all three, confirm in the field.

---

## 3. ➕ watchOS performance — getting the MAXIMUM delta-altitude rate

The barometer's intrinsic rate is fixed (~1 Hz for relative; the OS gives no rate
knob). So there is **no "faster API" for Δh** — what varies enormously is whether
you actually RECEIVE the full rate. The 0.36 Hz we measured on an earlier logger
was throttling, not the sensor. The levers:

| Technique | Verdict | Why |
|---|---|---|
| **`HKWorkoutSession` active** | **REQUIRED** | Removes app throttling/suspension AND is the precondition for `CMBatchedSensorManager` 200 Hz. The likeliest root cause of a 0.36 Hz logger is that no workout was active. |
| **Dedicated `OperationQueue`, QoS `.userInteractive`** | **YES (implemented)** | `startRelativeAltitudeUpdates(to:)` takes an `OperationQueue`. A max-QoS serial queue guarantees DELIVERY under UI/BT load (it does not raise the sensor rate — the fit uses `data.timestamp`, so queue jitter never corrupts it). Never `.main`. |
| **`WKExtendedRuntimeSession`** | **not needed** | Its session types (`.physicalTherapy/.mindfulness/.smartAlarm/.selfCare`) don't fit kitesurf and it doesn't grant high-rate sensor access. `HKWorkoutSession` is correct and sufficient. |
| **Screen ON / Always-On** | **marginal** | Inside an active workout the app already runs at full rate in the background. Keeping the screen lit is a battery cost with little rate benefit. |
| **Low Power Mode** | **detect, can't force** | Reduces background refresh + sensor rates. Read `ProcessInfo.isLowPowerModeEnabled`; when on, lower confidence + record it (you cannot disable it from code). |
| **Thermal state** | **detect + record** | `.serious/.critical` throttles CPU + sensors and can collapse the 1 Hz. Read `ProcessInfo.processInfo.thermalState`; record it so a rate drop is explainable. |
| **Battery** | **record** | Low battery can trigger reduced modes. Record `WKInterfaceDevice.batteryLevel`. |

**Extra levers (not in the team's list):** a *single* `CMAltimeter` consumer (two
concurrent consumers can fight — route one provider to both the fit and the
logger); a **live measured cadence** (`baroHz`) as an in-session go/no-go (below
0.8 Hz inside a workout ⇒ something is throttling, not the sensor); `CMBatched-
SensorManager` at 200 Hz is the big rate lever for the *timing* side.

### Swift — the dedicated queue + the STATUS monitor that PROVES the rate

```swift
// dedicated, serial, max-QoS — DELIVERY guarantee, not timing
let altQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "v12.altimeter"
    q.qualityOfService = .userInteractive
    q.maxConcurrentOperationCount = 1
    return q
}()

// STATUS every 2 s — the only way to prove/explain the delivered rate
statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
    guard let self else { return }
    let thermal: Int
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: thermal = 0; case .fair: thermal = 1
    case .serious: thermal = 2; case .critical: thermal = 3
    @unknown default: thermal = 0
    }
    let low = ProcessInfo.processInfo.isLowPowerModeEnabled
    WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    let batt = Int((WKInterfaceDevice.current().batteryLevel * 100).rounded())
    self.recorder?.status(t: ProcessInfo.processInfo.systemUptime,
                          thermal: thermal, lowPower: low, batteryPct: batt,
                          baroSource: 2 /*absolute*/, baroHz: self.baroHzEwma)
}
```

Where `baroHzEwma` is an EWMA of `1/Δt` between altimeter callbacks — surface it
in-session; if it sinks below ~0.8 Hz inside an active workout, warn (throttling).

---

## 4. Sampling & timing — 200 Hz motion, one timebase, dedup

✅ The team already: prefers `CMBatchedSensorManager` device motion (falls back to
`CMMotionManager`), carries a CoreMotion monotonic `motionTimestamp` + a separate
`barometerTimestamp`, and dedupes barometer frames. All correct. Emphasise:

- **Use `deviceMotionUpdates()` (200 Hz) and feed `|userAcceleration|`** (gravity
  removed) — every g-threshold in the engine is calibrated on that scale. The
  800 Hz raw `accelerometerUpdates()` includes gravity (≈1 g at rest) and would
  shift every threshold; keep it OFF in production (calibration logs only).
- **One monotonic timebase.** Motion + barometer already use CoreMotion
  timestamps. **Convert `CLLocation.timestamp` (wall clock) once** to the same
  boot-monotonic clock so all streams align:

```swift
let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
    for l in locs {
        let tMono = l.timestamp.timeIntervalSince1970 - bootWallClock
        pipeline.addLocation(t: tMono, lat: l.coordinate.latitude,
                             lng: l.coordinate.longitude, speedMs: max(l.speed, 0))
    }
}
```

- **±5 ms timing** at 200 Hz is what lets the height be emitted *at* the landing.
- Rate-aware g-thresholds: a 20–40 ms impact reads ~×4 sharper at 200 Hz than the
  50 Hz field logs. Keep `yankG/crashG/landImpactG` in config, not constants
  (demo used 2.6 / 9.0 / 2.4 for 200 Hz; final values from LOG5).

---

## 5. ➕ Offline airborne reconstruction inside the ≤5 s budget

The brief's key relaxation: **airborne tracking may be computed offline — the only
hard requirement is a result within 5 s of landing.** V12 exploits this with a
two-stage emission so the wrist never feels slow while accuracy still improves:

| Stage | When | What | Accuracy |
|---|---|---|---|
| **INSTANT** | at the landing evidence (~0.2–1 s) | one-sided anchor (pre-take-off only) + the current arc points | ±~0.2 m, provisional |
| **REFINED** | ≤5 s after landing | waits for 2–3 post-landing baro samples → **two-sided anchor** → linear drift measured + removed → re-fit | the canonical number |

The 5 s budget is spent buying the **rear anchor**: 2–3 on-water baro samples after
the landing let V12 *measure* the linear drift across the arc (front vs rear
anchor) and remove it analytically — instead of guessing. On the dirty-baro demo
this is the difference between ±1.5 m and ±0.3 m. The HUD shows INSTANT, then
updates the same jump id to REFINED (the exact update/retract shape v9 already
uses). Everything after the landing is offline reconstruction — no real-time
constraint beyond the 5 s deadline.

```swift
// scheduled ~refineDelaySec after the instant emission (offline reconstruction)
func refine(now: TimeInterval, jump j: V12Jump) {
    let post = baro.filter { $0.t > j.landingT + 0.4 && $0.t <= now }   // rear anchor
    guard !post.isEmpty else { emitRefined(j); return }
    let b1 = median(post.map(\.alt)); let t1 = post.map(\.t).reduce(0,+) / Double(post.count)
    let b0 = anchor(for: j);          let t0 = j.takeoffT - 2.0
    let drift = (t1 - t0) > 1 ? (b1 - b0) / (t1 - t0) : 0                // MEASURED, not guessed
    // fit under no-drift and linear-drift; keep the lower-residual model (see §6.3)
    let h = bestModelHeight(driftRate: drift, jump: j)
    emitRefined(j.with(height: h, driftSuspect: abs(b1 - b0) > rtzTol))
}
```

---

## 6. ⚠️ As-built algorithm — where the plan's §6 is out of date

The team's §6 outline is right in spirit; these are the specifics that changed as
the algorithm was hardened (all in `jumpEngineV12.ts` + the Swift twin).

### 6.1 Landing is now TWO-STAGE, not "earliest of"

The IMU gives the precise **time** (evidence); the barometer **confirms** water
contact. Evidence = earliest of impact (`|a| ≥ landImpactG` after `minAirSec`),
chop-resume (held `chopResumeHoldSec`, referenced to the rider's own pre-take-off
chop → glassy-water safe), or a submersion event. It only becomes a landing once a
baro sample near the water confirms it (**`baroOnWater`: low + flat, drift-
tolerant, within ~1.3 s of the evidence**). Otherwise the evidence **goes stale
after 2 s** and the arc continues — this is what stops a **mid-flight bar-work
spike** from cutting a jump short (observed in simulation). A third path,
**baro-return**, lands a soft glassy jump directly when the arc returns to the
anchor. If the baro goes silent (> 2.5 s) mid-arc, trust the IMU alone.

### 6.2 Candidate RESTART (new)

A fresh take-off-grade yank *while the current arc shows no baro elevation* means
the current candidate was a false start (a chop spike). The state machine
**restarts** the candidate rather than staying stuck — otherwise a stale candidate
swallows the real jump behind it (this bug was caught in simulation).

### 6.3 Height is a FREE parabola (not just endpoint-anchored)

- **≥2 arc baro points → take-off-anchored FREE parabola** `z = b·τ + c·τ²`
  (z(0)=0). The **vertex is the height, independent of landing-time error** — a
  soft landing detected ±1 s late does not bias it. (The earlier endpoint-anchored
  one-parameter basis DID bias by ~1 m for a late landing.) `apexTime` = the
  vertex time, not a fixed `takeoff + T/2`.
- **1 point →** endpoint-anchored one-parameter basis `φ(τ)=4τ(T−τ)/T²`.
- **0 points →** glide model `h = g·(T/2.63)²/8` (secondary use of airtime only).

### 6.4 Refine = two-sided anchor + MODEL SELECTION

The team's §7 is correct and worth stating precisely: fit the arc under **(a)
no-drift** and **(b) linear-drift** (drift measured from the two-sided anchor);
keep the model with the lower residual (SSE). This prevents a splash-triggered
drift that turns on only at landing from over-correcting a clean arc. A refit that
falls below the display floor **retracts** the jump (confidence collapses).

### 6.5 Gates & guards (confirm these are present)

`crashG` (≥ ~6 g entry = water impact, not take-off) · `crashCooldownSec` (~30 s
after a crash — a wet baro port paints fake humps, measured on LOG4) ·
`maxArcBracketSec` ceiling (a bracket wider than any real flight is a drift ramp) ·
the planing gate.

---

## 7. ➕ Logging — must be KSLG v2 (binary), not a single smoothed channel

The team logs `schemaVersion`/`engineVersion` — good — but the STREAM format
matters as much as the header. A single forward-filled row (the v1 shape) is
exactly what produced the 0.36 Hz pathology. The recording MUST be **KSLG v2**:
**stream-tagged records, each with its own µs timestamp**, per LOG5. Full spec:
`LOG5_RECORDING_FORMAT.md`; codec: `core/kslog2.ts` (shared TS — the dashboard
decodes the same bytes the watch writes).

### What to record (binary KSLG v2)

| Record (tag) | Rate | Fields |
|---|---|---|
| **MOTION (3)** | 200 Hz | t · userAccel xyz · rotationRate xyz · quaternion |
| **BARO (5)** | every callback (~1 Hz) | t · relativeAltitude (m) · **pressure (hPa)** |
| **ABSALT (6)** ⭐ | every callback (~2 Hz) | t · altitude (m) · accuracy · precision |
| **GPS (7)** | 1 Hz | t · lat · lng · speed · course · hAcc · vAcc · gpsAlt |
| **SUBMERSION (8)** | events | t · kind · value (Ultra only) |
| **EVENT (9)** | events | t · state · engine event string |
| **SYNC (10)** | once/session | t · wallClockUnixMs · label (Surfr alignment, §8) |
| **STATUS (11)** | ~0.5 Hz | t · thermal · lowPower · batteryPct · baroSource · **baroHz** |

**Record relative AND pressure AND absolute** — the whole point of §2 is that the
field data must be able to compare their lag. **Record STATUS** — it is the only
proof the acquisition got the full rate (§3). Header carries `schemaVersion 2`,
`engineVersion`, `t0BootUs` + `wallClockAtT0Ms` (the wall-clock bridge), device,
and the active/candidate engines.

### Swift — a minimal KSLG v2 recorder shape (wire to `SessionLogger`)

```swift
// each stream appends a tagged record with its OWN µs timestamp — never resample
protocol V12Recorder {
    func baro(t: TimeInterval, relAlt: Double, pressureHpa: Double)
    func absAlt(t: TimeInterval, altM: Double, accuracy: Double, precision: Double)
    func motion(t: TimeInterval, ua: SIMD3<Double>, rr: SIMD3<Double>, q: simd_quatd)
    func gps(t: TimeInterval, lat: Double, lng: Double, spd: Double, course: Double,
             hAcc: Double, vAcc: Double, gpsAlt: Double)
    func submersion(t: TimeInterval, kind: Int, value: Double)
    func status(t: TimeInterval, thermal: Int, lowPower: Bool, batteryPct: Int,
                baroSource: Int, baroHz: Double)
    func event(t: TimeInterval, state: Int, evt: String)
    func sync(t: TimeInterval, wallClockUnixMs: Int64, label: String)
}
```

The byte layout (little-endian, v1-compatible magic/sentinels) is fully specified
in `LOG5_RECORDING_FORMAT.md §2`; mirror `core/kslog2.ts` so a watch-written log
decodes byte-for-byte in the dashboard.

---

## 8. ⚠️ Corrected acceptance / validation

The team's §11 remaining-validation list is right; make it concrete with the
findings above:

1. **Rate proof** — in an active workout, measured altimeter cadence ≥ 0.8 Hz
   (relative) / the absolute stream ≥ ~1.5 Hz; STATUS shows nominal thermal, not
   low-power. This is the go/no-go for the throttling pathology.
2. **Δh channel lag** — on the LOG5 field session (Surfr on a second watch, filmed
   stopwatch sync), confirm absolute (and/or pressure) tracks the jump apex with
   less lag than the smoothed relative; set the production `BaroSource` default to
   the winner.
3. **Accuracy** — height RMS ≤ 0.30 m vs Surfr on jumps ≥ 1.5 m; airtime within
   ±0.3 s; INSTANT ≤ 2 s and REFINED ≤ 5 s after landing.
4. **Negative controls** — a no-jump chop session (0 jumps), a crash session (the
   crash produces no jump), a drift-heavy session (no ramp phantoms).
5. **Permission matrix** — motion/altimeter/location denied each fall back
   cleanly (absolute-unavailable → pressure, not straight to v11); no crashes.
6. **Threshold calibration** — recompute the g-gates from real 200 Hz
   device-motion (not the 50 Hz-smeared field logs).
7. **Battery/thermal** — session overhead within +10 % of v11; thermal stays ≤
   fair.

### ➕ Swift synthetic test additions (extend the existing SwiftPM check)

- A **channel-lag check**: feed a synthetic arc into `relative` (low-passed) vs
  `absolute` (fast); assert the fit on absolute recovers the apex within tol while
  relative under-reads — locks in the §2 behaviour.
- **Negative controls**: chop-only stream → 0 jumps; a ≥9 g crash → 0 jumps; a
  slow drift ramp → 0 jumps.
- **Mid-flight spike**: an arc with a bar-work spike mid-flight → still ONE jump
  with the correct airtime (not cut short) — locks in the two-stage landing (§6.1).

---

## 9. Practical Swift snippet index

| Need | Snippet | Section |
|---|---|---|
| Acquire relative + pressure + absolute, feed the fast one | `startRelative/AbsoluteAltitudeUpdates` | §2 |
| Max-QoS delivery queue | `OperationQueue(.userInteractive)` | §3 |
| Prove/explain the delivered rate | STATUS timer (thermal/low-power/battery/baroHz) | §3 |
| One monotonic timebase for GPS | `bootWallClock` conversion | §4 |
| Offline refine within 5 s | two-sided anchor + model selection | §5 |
| Binary log | KSLG v2 recorder protocol | §7 |

**Canonical references:** `core/JumpEngineV12.swift` (the acquisition + pipeline
twin), `V12_INSTANT_ARCHITECTURE.md §10` (the complete as-built pipeline),
`LOG5_RECORDING_FORMAT.md` (recording spec + §6 the full API/technique analysis),
`V12_DEV_PLAN_WATCH_TEAM.md` (the formal integration plan).
