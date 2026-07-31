# V12 Apple Sensor Fusion Jump Engine — Development Plan

## 1. Executive Summary

V12 (`JumpDetectionEngineV12` / "V12 — Apple Sensor Fusion") is an isolated, opt-in
engine added ALONGSIDE v7–v11. It fuses four Apple services — `CMAltimeter`
(primary height), `CMBatchedSensorManager` (take-off/landing timing at 200 Hz),
`CLLocationManager` (riding gate + jump distance), `CMWaterSubmersionManager`
(optional landing corroboration, Ultra only) — and emits height + airtime +
distance + confidence **at the landing (≤2 s)**, with a drift-checked refinement
~3 s later. Nothing in v7–v11, the default engine selection, `SessionLogger`, or
the CSV format changes.

A **validated reference implementation already exists** in the algorithm repo and
is the source of truth for the logic: `core/jumpEngineV12.ts` (pipeline) and
`core/JumpEngineV12.swift` (pipeline + full sensor acquisition layer,
Series 8+). The work here is INTEGRATION into the Surfer app's engine-selection,
logging and settings infrastructure — not re-derivation of the algorithm.

**One documented algorithm change vs. the brief (authorized by §17 of the
request):** height is NOT `maxSmoothedRelativeAltitude − baseline`. At the real
~1 Hz altimeter cadence a jump arc contains only 3–4 samples; the raw/smoothed
maximum systematically UNDER-reads (no sample lands on the apex, and smoothing
flattens it further). V12 instead runs an **endpoint-anchored least-squares arc
fit**: z = 0 at the IMU-timed take-off and landing (the wrist starts and ends at
water level), one free scale parameter on the parabola basis φ(τ)=4τ(T−τ)/T².
With 3–4 points, a 1-parameter anchored fit has far lower variance than a free
3-parameter parabola, and strictly dominates "take the max sample". The raw max
is kept in the debug snapshot as a sanity comparison. This is the parabolic
least-squares reconstruction the brief's §"שיחזור גובה השיא" itself asks for —
done with the anchors the physics provides.

Two experimental facts (measured on LOG2/LOG4 against Surfr on a second watch,
same wrist) ground the design — do not re-litigate them during implementation:
1. **Height is only in the barometer.** Oracle-constrained double integration of
   wrist IMU reads 0.4–2.0 m for real 3.1–3.8 m jumps (`core/tools/_v10imu.ts`).
   The brief's "no double integration as primary" is confirmed, hard.
2. **Timing is only in the IMU.** ~1 Hz baro cannot time a 2–4 s arc; the 200 Hz
   batched stream times the yank/landing to ±5 ms — that is the airtime.

## 2. Official Apple API Verification

> Rule applied: nothing below is assumed from symbol names. Items not
> re-checkable from here are marked `Needs Verification` and MUST be confirmed
> against current Apple docs before Phase 3.

### 2.1 CMAltimeter.relativeAltitude
- **Official role:** relative altitude changes derived from the barometric
  sensor. `startRelativeAltitudeUpdates(to:withHandler:)` delivers
  `CMAltitudeData` — `relativeAltitude` (NSNumber, metres, relative to session
  start), `pressure` (NSNumber, kPa), inherited `timestamp` (seconds since boot,
  stamped at measurement time).
- **Availability:** iOS 8+ / watchOS 2+. Hardware: barometer present on Apple
  Watch Series 3 and later — all target devices (S8+) have it.
- **Rate:** NO public rate parameter. Cadence is system-determined, ~1 Hz in
  practice. `Needs Verification` on-device: measure the real callback cadence
  inside an active workout (our field logs show 0.36 Hz — a THROTTLED/polling
  logger symptom, not the API limit).
- **Permissions:** Core Motion usage — `NSMotionUsageDescription` in Info.plist
  (`Needs Verification`: whether the existing app already declares it — it
  almost certainly does for the current engines).
- **Runtime availability:** `CMAltimeter.isRelativeAltitudeAvailable()`.
- **If unavailable:** V12 cannot produce heights → engine reports itself
  non-operational at start; factory falls back to the user's previous engine
  (see §8). Detection-only mode is NOT offered (a height product without height
  is a worse lie than a clean fallback).
- **Must NOT be used for:** absolute elevation claims; airtime timing (too
  slow); apex "detection" mid-flight (apex is reconstructed at landing).
- `startAbsoluteAltitudeUpdates` (iOS 15+/watchOS 8+,
  `isAbsoluteAltitudeAvailable()`): optional debug channel only. Not a V12
  dependency.

### 2.2 CMBatchedSensorManager
- **Official role:** high-rate batched sensor delivery during workouts:
  `accelerometerUpdates()` (800 Hz `CMAccelerometerData` batches) and
  `deviceMotionUpdates()` (200 Hz `CMDeviceMotion` batches), async sequences.
- **Availability:** watchOS 10+, **Apple Watch Series 8 and later**. Class
  properties `isAccelerometerSupported` / `isDeviceMotionSupported`.
- **Hard requirement:** an **active `HKWorkoutSession`** — updates do not flow
  without one. No additional entitlement known beyond HealthKit + motion usage
  (`Needs Verification`).
- **V12 choice (documented):** `deviceMotionUpdates()` at 200 Hz, feature =
  `|userAcceleration|` (gravity removed). Rationale: every threshold in the
  validated reference engine is calibrated on userAcceleration magnitude (the
  field logs' `aM` column); the 800 Hz raw stream includes gravity (|a|≈1 g at
  rest) and would silently shift all thresholds. 200 Hz times events to ±5 ms —
  far beyond need.
- **If unavailable** (pre-S8 hardware / no workout): V12 non-operational →
  fallback per §8. Do NOT silently substitute `CMMotionManager` 100 Hz in v1 of
  V12 (different delivery guarantees; can be a documented later extension).
- **Must NOT be used for:** height via double integration (§1 fact 1); pressure
  (CMDeviceMotion has NO pressure channel — any plan assuming baro-through-
  DeviceMotion is wrong).

### 2.3 CLLocationManager
- **Official role:** GPS fixes: `CLLocation` with `coordinate`,
  `speed` (m/s, <0 = invalid), `course`, `horizontalAccuracy` (<0 = invalid),
  `timestamp` (wall clock).
- **Availability:** all target watches (S8+ GPS models; LTE irrelevant).
- **Permissions:** `NSLocationWhenInUseUsageDescription` (watch + companion
  Info.plist), `requestWhenInUseAuthorization()`. With an active workout session
  the app keeps running and receiving updates. (`Needs Verification`: the
  existing app already holds this permission for v7–v11 sessions.)
- **Runtime:** `CLLocationManager.authorizationStatus`, delegate errors.
- **V12 usage rules (per brief, adopted):** speed gate (planing) with
  freshness ≤5 s and `speed ≥ 0`-validity; distance = **straight-line haversine
  take-off→landing** (documented choice: at 1 Hz a 2–4 s arc has 2–4 fixes;
  "path distance" adds GPS noise, not information); distance suppressed
  (`nil`, `distanceSource = none`) when either endpoint fix is missing, older
  than 2.5 s, or `horizontalAccuracy > 20 m` (`Needs Verification` threshold —
  calibrate on LOG5); fallback `takeoffSpeed × airtime` marked
  `distanceSource = speedModel`.
- **Must NOT be used for:** height (GPS vertical is ±3–5 m noise); jump
  confirmation on its own.

### 2.4 CMWaterSubmersionManager
- **Official role:** water submersion state, water depth/pressure, water
  temperature events via delegate.
- **Availability:** watchOS 9+, **Apple Watch Ultra family ONLY**
  (`CMWaterSubmersionManager.waterSubmersionAvailable`).
- **Permissions/entitlement:** requires the **Shallow Depth and Pressure
  entitlement** (`com.apple.developer.submerged-shallow-depth-and-water-temperature`)
  and carries automatic Water Lock behavior. `Needs Verification`: entitlement
  approval status for the Surfer app. **Because of the entitlement cost, V12
  ships fully functional WITHOUT it**; the provider is compiled in but activates
  only when `waterSubmersionAvailable == true` AND authorization granted.
- **V12 usage:** landing corroboration + `waterSignalStatus` debug/confidence
  field only. Never a dependency, never a height source, never a gate.
- **If unavailable/unauthorized:** `waterSignalStatus = unsupported/unauthorized`;
  zero behavioral change.

### 2.5 HKWorkoutSession / Existing Workout Infrastructure
- **Official role:** workout lifecycle on watchOS; keeps the app running in
  background, enables high-rate sensors (2.2), removes throttling.
- **Availability:** watchOS 2+ (API), configuration via
  `HKWorkoutConfiguration`. Activity type: use the app's existing type;
  `.surfingSports` fits (`Needs Verification`: exact enum case used today by
  the app; do NOT change it as part of V12).
- **Permissions:** HealthKit entitlement + `NSHealthShareUsageDescription` /
  `NSHealthUpdateUsageDescription` — already present if the app runs workouts
  today (`Needs Verification`).
- **Critical field finding:** our recorded sessions show 0.36 Hz altimeter — the
  signature of a suspended/polling logger. V12's acquisition MUST (a) run inside
  the active workout, (b) register the altimeter handler on a **dedicated serial
  `OperationQueue` with `.userInteractive` QoS** (delivery guarantee under UI/BT
  load), (c) log EVERY callback with `data.timestamp` (sensor-time) — never
  poll, never resample. Physics uses sensor timestamps, so queue jitter cannot
  corrupt measurements; the queue exists for delivery, not timing.

## 3. Existing Codebase Audit

> Scope honesty: this plan is written from the ALGORITHM repository
> (`surfhub-watch`), which is the declared source of truth the watch team ports
> from. The Surfer app's own repo is not visible from here; §3.5 lists exactly
> what the team must map before Phase 3. Nothing below assumes app-side file
> contents.

### 3.1 Current engines v7–v11 (algorithm repo ground truth)
- `core/jumpEngineV7.ts`, `core/jumpEngine.ts` (V8 physics), `core/jumpScanV9.ts`
  (V9 on-watch scan architecture + long-horizon confirmation),
  `core/trajectoryV9.ts` / `core/TrajectoryV9.swift` (endpoint-anchored MAP
  reconstruction), `core/KitesurfJumpEngine.swift`, `core/KitesurfJumpEngineV9.swift`,
  `core/JumpDetector.swift`, `core/jumpDetect.{ts,swift}`.
- **V12 reference (already implemented + smoke-tested):**
  `core/jumpEngineV12.ts` + `core/JumpEngineV12.swift`
  (`JumpPipelineV12` = pure logic, sensor-free, testable; `JumpSessionV12` =
  acquisition). App-side v10/v11 exist only in the app repo — map in Phase 1.
- Validation assets: `core/tools/validate_v9.ts` (LOG2/LOG3/LOG4 goldens),
  `core/tools/_v12replay.ts` (V12 harness), `core/tools/surfr_LOG4.json`,
  `core/tools/_v10imu.ts` (the IMU-height refutation), kslog codec
  (`core/kslog.ts`), Surfr reference data.

### 3.2 Current settings integration — app repo. `Needs Verification` (Phase 1):
engine enum, persistence key, default value, factory switch location.
### 3.3 Current logging/replay — app repo. Known from this side: the kslog binary
format (`core/kslog.ts` decodes it) and the CSV legacy path (`core/csvLog.ts`).
`SessionLogger.swift` internals: `Needs Verification`.
### 3.4 Current sensor pipeline — app repo. Known constraint from field data: the
current logger yields 0.36 Hz baro → it polls or runs throttled.
**`Risk`: if V12 reuses the existing sensor recorder as-is, it inherits the
0.36 Hz pathology and V12's accuracy claims collapse. V12 therefore brings its
own acquisition (2.5) and only SHARES the workout session.**
### 3.5 Risk areas + Phase-1 checklist (team fills in)
1. File map: `JumpDetector.swift`, engines v7–v11, state machine, `SessionLogger.swift`,
   settings screen/model/enum, engine factory, Jump/Session/Metrics models,
   iPhone sync payloads, CSV columns list, replay/debug harness, Info.plist keys,
   entitlements, workout session owner class.
2. For each: owner, public surface, who reads its output.
3. Confirm: adding a case to the engine enum does not break decoding of persisted
   settings (`Backward Compatibility Risk` — see §6).
4. Confirm: CSV appending columns at END keeps old parsers working
   (`Backward Compatibility Risk`).
5. Confirm: two consumers of `CMAltimeter` (existing logger + V12 provider) can
   coexist, or route altimeter through one shared provider
   (`Needs Verification` — Apple allows multiple CMAltimeter instances;
   verify no app-side singleton assumption breaks).

## 4. Proposed Architecture

### 4.1 New files (app repo; names follow the brief, mapped to the reference)
| File | Content | Reference source |
|---|---|---|
| `JumpDetectionEngineV12.swift` | conforms to the app's existing engine protocol; owns the pipeline; maps `V12Jump` → app `Jump` model | wraps `JumpPipelineV12` |
| `V12SensorProviderCoordinator.swift` | starts/stops providers, feeds frames, one monotonic clock | `JumpSessionV12` |
| `V12AltimeterProvider.swift` | dedicated `.userInteractive` serial queue; every callback → frame | `JumpSessionV12.start()` altimeter block |
| `V12BatchedMotionProvider.swift` | `deviceMotionUpdates()` 200 Hz; emits `|userAcceleration|` | `JumpSessionV12` accel task |
| `V12LocationProvider.swift` | fixes + validity/freshness flags; wall-clock→monotonic conversion | `JumpSessionV12` CLLocation delegate |
| `V12WaterSubmersionProvider.swift` | optional; availability+authorization guarded | `JumpSessionV12` submersion block |
| `V12JumpStateMachine.swift` + `V12JumpSegmentBuffer.swift` + `V12AltitudeBaselineTracker.swift` + `V12CandidateDetector.swift` + `V12JumpMetricCalculator.swift` | the pipeline internals, split to the brief's module names | `JumpPipelineV12` (state machine, rings, anchor, fit, metrics) |
| `V12ConfidenceScorer.swift`, `V12RejectionReason.swift`, `V12DebugSnapshot.swift` | scoring + reasons + debug record | extends reference `confidence` |
| `V12SensorFusionFrame.swift` | the typed frame (accel / baro / location / submersion variants, sensor timestamps) | TS input methods |

### 4.2 Modified files (small, additive only)
- Engine enum + factory: add `.v12AppleSensorFusion` case. **Default unchanged.**
- Settings view: one new row. Settings model: persists the new raw value.
- `SessionLogger.swift`: append-only V12 columns (§7) + `schemaVersion`,
  `engineVersion` if absent.
- Jump/Session model: new OPTIONAL fields (§7) — optionality preserves decoding
  of old records (`Backward Compatibility Risk` mitigated).
### 4.3 Interfaces/protocols — reuse the app's existing engine protocol
(`Needs Verification`, Phase 1). If none exists, introduce
`JumpEngineRunning { start(context:) / stop() / delegate }` and retrofit ONLY v12
to it (v7–v11 untouched).
### 4.4 Engine factory integration — factory instantiates V12 only when selected;
V12 `start()` returns operability (`.operational` / `.unavailable(reason)`);
unavailable → factory logs + falls back to the previously selected engine and
surfaces a non-blocking notice (§8).
### 4.5 Backward compatibility — v7–v11 not touched; default not changed; CSV
append-only; model fields optional; persisted-settings decoding verified with a
migration test (old value → still resolves; unknown value → default).

## 5. V12 Sensor Fusion Algorithm

> The normative logic is `core/jumpEngineV12.ts` (+ Swift twin) — keep
> line-for-line parity. This section defines it in the brief's structure.

### 5.1 Sensor frame model
`V12SensorFusionFrame` = enum(accel(t,|a|g) @200 Hz · baro(t,relAltM) @~1 Hz ·
location(t,lat,lng,spd,hAcc) @~1 Hz · submersion(t,state) event). All `t` on the
boot-monotonic sensor clock; CLLocation wall-clock converted once at ingest.
Frames are NEVER resampled or interpolated at ingest.

### 5.2 State machine (brief's 9 states, mapped to the physics)
```
IDLE → RIDING:            planing (GPS speed ≥3.5 m/s, fix ≤5 s fresh)
RIDING → CANDIDATE_TAKEOFF: |a| ≥ yankG (2.2 g) and < crashG (6 g), outside
                           crash cooldown (30 s), baseline anchor available
CANDIDATE_TAKEOFF → AIRBORNE: anchor frozen; preChop frozen  (same tick)
CANDIDATE_TAKEOFF → REJECTED(noBaseline | cooldown | notPlaning)
AIRBORNE → LANDING_CANDIDATE: impact ≥2 g | chop ≥0.8·preChop | submerged
AIRBORNE → REJECTED(maxAirExceeded 8 s | crashMidArc ≥6 g)
LANDING_CANDIDATE → AIRBORNE:  chop evidence not held 0.3 s
LANDING_CANDIDATE → VALIDATED_JUMP: airtime ∈ [1.2, 8] s AND fitted height ≥1.5 m
LANDING_CANDIDATE → REJECTED(tooShort | belowMinHeight)
VALIDATED_JUMP → COOLDOWN → IDLE/RIDING   (emission + refinement scheduling)
APEX_DETECTED: NOT a live state at ~1 Hz baro — the apex physically cannot be
  observed mid-flight; it is RECONSTRUCTED at landing (5.5). Kept in the enum
  for debug parity; entered retroactively in the debug snapshot only.
```
Per-state timeouts, sensor dependencies, rejection reasons and CSV fields are
enumerated in `V12RejectionReason` / §7. Sensor loss mid-state: baro loss →
abort candidate (`rejection=sensorLoss`), engine stays up for detection-less
logging; motion loss → engine non-operational → §8 fallback.

### 5.3 Altitude baseline — `V12AltitudeBaselineTracker`
Median of the last 4 on-water baro samples, all ≤8 s old, ending ≥0.3 s before
the yank (excludes the rise). Stability check: rejected (`baselineUnstable`) if
fewer than 2 usable samples. Spike handling: median (not mean) + the existing
despike heuristics. No session-level rebase needed — everything is deltas
against the per-jump anchor (relativeAltitude's own zero is irrelevant).
Rationale vs the brief's "1–3 s window": at ~1 Hz that is 1–3 samples — too few
for a median; 4 samples ≈ 4 s keeps the drift bound (±0.2–0.4 m measured on the
worst log) while surviving one outlier.

### 5.4 Take-off detection — |a| yank ≥2.2 g while planing (200 Hz), crash-gated
(≥6 g = water impact, not take-off; 30 s cooldown after any crash — a wet baro
port paints fake humps, measured on LOG4). `Needs Verification` on LOG5: yank
threshold at true 200 Hz (field logs are 50 Hz-smeared; expect recalibration).
### 5.5 Apex detection — reconstructed at landing by the anchored fit (§1);
`apexTime = takeoff + T/2` (model); debug snapshot stores the raw max sample too.
### 5.6 Landing detection — earliest of: impact ≥2 g (after ≥1.2 s), chop-resume
≥0.8·preChop held 0.3 s (soft landings; reference = the rider's own pre-take-off
chop — glassy-water safe), submersion event (when available). Timeout 8 s →
rejection (a "jump" that never lands is a drift artifact).
### 5.7 Height — endpoint-anchored LSQ (§1). `heightSource = baroAnchoredFit`
when ≥1 arc sample; `= airtimeGlideModel` (h = g·(T/2.63)²/8) ONLY when the arc
contains zero baro samples (sub-1 s hop) — and such jumps also fail the 1.5 m
display floor unless airtime says otherwise; flagged low-confidence. This is the
brief-permitted secondary use of the airtime formula, never primary.
### 5.8 Airtime — `landingTime − takeoffTime`, both IMU-timed (±5 ms @200 Hz).
### 5.9 Distance — §2.3 rules (straight-line haversine; accuracy/freshness
guards; speed×airtime fallback; `distanceSource` recorded).
### 5.10 Confidence — `V12ConfidenceScorer`, additive multi-signal:
base 0.55 · +0.15 ≥1 arc baro sample · +0.10 ≥2 samples · +0.05 clean landing
chop signature · +0.05 fresh accurate GPS at both endpoints · +0.05 submersion
corroboration (when available) · −0.15 refinement drift flag (§5.11).
`confidenceLevel`: <0.55 low / 0.55–0.75 medium / >0.75 high. UI must show
low-confidence jumps as tentative (existing UI convention — Phase 8).
### 5.11 Rejection reasons — `V12RejectionReason`:
`notPlaning · baselineUnstable · crashEntry · crashCooldown · crashMidArc ·
maxAirExceeded · tooShort · belowMinHeight · sensorLoss · staleGPS(dist-only)`.
REFINEMENT (not rejection): ~3 s post-landing, measure return-to-zero (post-
landing water level − anchor). |rtz| > 0.25 m → correct height by −rtz/2, set
`driftSuspect`, reduce confidence; re-emit the same jump id refined.

## 6. Settings Screen Integration
- Engine enum: add `case v12AppleSensorFusion` (raw value chosen to not collide;
  `Needs Verification` of raw-value scheme). Display name: “V12 — Apple Sensor
  Fusion”.
- Settings model/persistence: same store as today (UserDefaults/AppStorage —
  Phase 1 maps it). Unknown/legacy stored values must resolve to the current
  default — add a decoding test.
- **Default engine: UNCHANGED** (explicit per brief).
- Factory: switch gains one case; v12 only constructed when selected.
- Active-engine indication: existing debug surface + `engineVersion` in every
  log row/session payload.
- Runtime inability (no S8/watchOS 10, no motion permission): selection remains
  v12, session falls back (§8) with a logged reason + one-line UI notice; no
  crash, no silent engine swap in settings.

## 7. Logging, CSV, Debugging and Replay
- CSV: append-only new columns, exactly the brief's list:
  `v12_state, v12_candidate_id, v12_baseline_altitude, v12_smoothed_altitude,
  v12_max_altitude, v12_altitude_delta, v12_takeoff_detected, v12_apex_detected,
  v12_landing_detected, v12_motion_quality, v12_location_quality,
  v12_water_signal_status, v12_confidence, v12_rejection_reason`
  plus `schemaVersion` and `engineVersion` if missing today. Old files remain
  readable (columns only appended; names untouched).
- Jump payload fields (§7 of the brief): all present in `V12Jump` + the debug
  snapshot; new model fields OPTIONAL for backward compatibility.
- Replay: (a) app-side — run recorded sessions through
  `JumpDetectionEngineV12` and diff v10/v11/v12 per session (counts, times,
  heights, rejections); (b) algorithm-repo — `core/tools/_v12replay.ts` already
  replays kslogs and prints instant+refined emissions vs Surfr truth. Reports:
  FP/FN vs known-jump sessions (LOG2: 10 known · LOG3: 9 known · LOG4: 3 known +
  5 known drift phantoms + 1 known crash — the richest negative-control set).
- **`Risk` (measurement, not code):** current logs are 50 Hz/0.36 Hz — V12
  thresholds CANNOT be finalized on them (yanks smeared ×4–16). Replay on old
  logs validates plumbing and negative controls; threshold calibration and
  accuracy acceptance REQUIRE one LOG5-spec session
  (`NEXT_LOG_RECORDING_SPEC.md`): 200 Hz deviceMotion + every altimeter callback
  + full GPS + Surfr reference on the same wrist + a filmed shared stopwatch.

## 8. Graceful Degradation and Permissions
| Scenario | Behavior |
|---|---|
| No altimeter / motion permission denied | v12 `unavailable` → factory falls back to previous engine; notice + log |
| No `CMBatchedSensorManager` (pre-S8 / <watchOS 10) | same fallback; settings row shows “requires Series 8+” |
| No location permission / GPS poor | detection continues; `notPlaning` gate relaxes to last-known-speed ≤10 s (`Needs Verification` on LOG5); distance suppressed; confidence −0.05 |
| Submersion unsupported/unauthorized | `waterSignalStatus` records it; zero behavior change |
| Sensor stream stops mid-session | active candidate → `sensorLoss`; engine attempts one restart of the provider; second failure → fallback + log |
| Workout stops / background transition | providers stop with the workout (batched stream requires it); pipeline `flush()` emits due refinements |
| Battery constraints | V12 adds no polling; all streams are event/batch-driven; CPU budget §9 |

## 9. Performance Plan for watchOS
- All per-sample work O(1): trailing-window chop via ring buffer (0.3 s @200 Hz
  = 60 samples); baro ring ≤ ~40 samples; location ring ≤ 30 s.
- No allocations in the sample path (rings pre-sized; frames are value types).
- Handlers on dedicated serial queues (`.userInteractive` for altimeter,
  batched stream consumed on its own task); NOTHING on main thread.
- Fit runs once per jump (≤8 baro points, closed-form LSQ — microseconds).
- Logging buffered through the existing `SessionLogger` batching.
- No ML, no offline analysis on-watch.

## 10. Testing and Validation Plan
- **Unit (pipeline is sensor-free — inject frames):** baseline median/stability;
  anchored fit vs synthetic arcs (exact recovery on noiseless data; under-read
  bound at 1 Hz); take-off gates (yank/crash/cooldown/planing); landing paths
  (impact, chop-resume incl. glassy-water case, submersion, timeout); airtime;
  distance guards (stale/inaccurate/missing GPS, speed fallback); confidence
  monotonicity; every `V12RejectionReason` reachable; refinement rtz
  correction/flag; unsupported-API paths (providers report unavailable).
- **Replay:** LOG2 (10 known), LOG3 (9 known), LOG4 (3 known + 5 drift phantoms
  + crash + beach walk = negative controls); a no-jump chop session; v10/v11/v12
  comparison report. Expectation stated honestly: plumbing + negative controls
  pass now; accuracy numbers gated on LOG5.
- **Regression:** v7–v11 outputs byte-identical on fixture sessions; settings
  round-trip incl. legacy values; CSV old-parser test; watchOS + companion iOS
  builds green.

## 11. Incremental Implementation Steps
- **Phase 0 — Docs verification:** every `Needs Verification` in §2 resolved
  against current Apple docs; entitlement inventory; risk list signed off.
- **Phase 1 — Codebase audit:** §3.5 checklist filled with real file names;
  engine protocol + factory + settings + logger mapped; audit doc committed.
- **Phase 2 — Architecture sign-off:** this plan amended with Phase-1 names.
- **Phase 3 — Minimal integration:** enum + settings row + factory case +
  `JumpDetectionEngineV12` skeleton returning `unavailable`; mocks; build green;
  regression suite green.
- **Phase 4 — Providers:** the four providers + coordinator; a diagnostics
  screen/log proving real cadences (altimeter ≥0.8 Hz inside workout — THE
  go/no-go gate for the 0.36 Hz pathology).
- **Phase 5 — Detection logic:** port `JumpPipelineV12` verbatim; unit tests.
- **Phase 6 — Metrics:** metric calculator + confidence + rejection + snapshot.
- **Phase 7 — Logging/replay:** CSV columns; replay harness; v10/v11/v12 report.
- **Phase 8 — UI/settings polish:** fallback notices; active-engine debug.
- **Phase 9 — Validation:** LOG5 field session (with Surfr reference, filmed
  stopwatch sync); threshold calibration at true 200 Hz/1 Hz; battery/CPU
  profile; acceptance below.

## 12. Acceptance Criteria
1. v7–v11 byte-identical behavior; default engine unchanged; settings/CSV
   backward compatible (tests, not claims).
2. In-workout altimeter cadence measured ≥0.8 Hz on-device (kills the 0.36 Hz
   pathology) — hard gate.
3. On LOG4 negative controls (replayed): 0 of the 5 known drift phantoms, 0
   crash-jumps, 0 beach detections.
4. On LOG5 (with Surfr reference): jump count parity with Surfr; height RMS
   ≤0.30 m on jumps ≥1.5 m; airtime within ±0.3 s; instant emission ≤2 s after
   landing; refinement ≤5 s; zero crashes across permission-denial matrix.
5. Battery: session overhead vs v11 within +10% (`Needs Verification` baseline).
6. Every emitted jump carries confidence + (if any) rejection breadcrumbs; no
   unconditional height display.

## 13. Open Questions / Things That Must Be Verified Before Coding
1. All §2 `Needs Verification` items (cadence on-device, Info.plist inventory,
   submersion entitlement status, workout activity type in use).
2. Phase-1 audit outputs: real names of engine protocol, factory, settings
   store, CSV writer; persisted-enum decoding behavior for unknown values.
3. Can the existing session logger and V12's altimeter provider run
   concurrently, or should V12's provider become the single altimeter source
   feeding both? (Preferred: single source — also fixes the legacy logger's
   cadence.)
4. LOG5 scheduling: device (S8 vs Ultra — prefer BOTH, one session each),
   rider, Surfr on second watch, filmed stopwatch start.
5. Yank/chop thresholds at true 200 Hz — expect recalibration from the 50 Hz-
   smeared values; keep them in config, not constants.
6. Product decision: display floor 1.5 m confirmed (Surfr parity)?
7. Whether v10/v11 (app-side, not in the algorithm repo) share models the
   audit must protect — unknown from here, Phase 1 must answer.
