# V16 — hand-off to the watch team

Everything needed to run the V16 big-air engine on the Kiters watch app, plus
three findings from a review of the current code.

Base checkout this was prepared against: `WatchOS-surfhub-main` /
`Kiters.xcodeproj` (`objectVersion = 77`, Xcode 16).

---

## ⚠️ Correction to an earlier report

An earlier note from us claimed "the watch does not run V15, it runs the old
`JumpDetect.swift`". **That was about a different repository** — an older, much
simpler app under `surfhub-watch/watchos/` on our side.

The Kiters code is fine: V15 is fully implemented (`JumpEngineV15.swift`, 1,761
lines) with a proper `JumpDetecting` adapter, single-consumer barometer
handling, timestamp alignment and per-engine dispatch queues; V12/V13/V14 the
same. Please disregard the "add the file to the target / replace batch with
streaming" advice — it is already the case here.

---

## 1. What to apply

### `01_NEW_FILES/` — drop in, no edits needed

| File | Destination |
|---|---|
| `JumpEngineV16.swift` | `Kiters Watch App/Services/` |
| `JumpDetectorV16.swift` | `Kiters Watch App/Services/` |

The project uses `PBXFileSystemSynchronizedRootGroup`, so files dropped into
`Services/` are picked up automatically — **no `project.pbxproj` edit**.

### `02_WIRING_PATCHES/` — four small diffs

```bash
cd <repo>/Kiters
git apply ../V16_HANDOFF/02_WIRING_PATCHES/*.patch
```

| Patch | What it adds |
|---|---|
| `Session.patch` | `DetectionEngine.v16BigAir` + displayName + description |
| `SessionManager.patch` | `makeJumpDetector` case + immediate IMU start |
| `ReplaySessionController.patch` | `makeDetector` case |
| `main.patch` | `--engine v16` in the JumpReplay CLI |

Every `switch` over `DetectionEngine` in the repo is covered; the compiler will
tell you immediately if one was missed.

---

## 2. ⚠️ The one thing that is easy to get wrong: the g domain

`V16Config.popMinG = 1.4` is calibrated in the **magnitude** domain —
`|userAcceleration|`, which reads **~0 g at rest**:

```swift
let loadG = sample.accelerationMagnitude     // ✅ what V16 wants
```

It is **not** `JumpDetectorV15.verticalLoadG`, the gravity-projected load that
reads **~1 g at rest**:

```swift
projected = (a · ĝ) / |ĝ|;  load = projected + |g|    // ❌ do not feed this to V16
```

Feeding the load shifts every pop by a whole g and makes the 1.4 g floor
meaningless. Symptom: either no emissions at all, or an emission on every pop.
This is documented at the top of `JumpDetectorV16.swift`.

## 3. What V16 consumes

| Channel | Use |
|---|---|
| `IMUSample.accelerationMagnitude` | pop trigger |
| 3-axis `userAcceleration` + `attitudeQuaternion` | vertical channel: lift shelf + height |
| GPS | **metrics only** (takeoff speed, distance). No detection gate reads it |
| Barometer (abs / rel / pressure) | **not consumed at all** — `processAbsoluteAltitude` stays the protocol no-op |

`IMUSample` already carries the quaternion and the three axes, so
**MotionManager needs no change**.

---

## 4. Acceptance test

We have **not** been able to compile this (no Xcode on the machine it was
prepared on). Every symbol and signature was verified statically against your
sources — but **build first**.

Then run the CLI on the known logs; the numbers must match our TypeScript twin
exactly:

```bash
swift run JumpReplay --engine v16 --log log_287_20260728_182822_05D47F19.kslog
```

| Log | Truth | Expected from V16 |
|---|---|---|
| `log_287` (big air, 2.1–8.5 m) | 14 jumps | **14/14**, height MAE **0.52 m**, 1 phantom |
| `log_neg` (pops + waves, no jumps) | 0 | **0 emissions** |
| `log_clean` (small jumps) | 4 | 2 — outside V16's regime, V15 is better there |

If the counts are wrong, check the g domain (§2) first.

---

## 5. Review findings — `03_OPTIONAL_FIXES/`

These are **separate from the V16 work**. Each is a reviewable diff, not applied.

### FIX-A — `logSample` is a no-op in all 7 adapters &nbsp; *(severity: high)*

`SessionLogger.logSample`'s first line is `guard !event.isEmpty else { return }`,
and all seven adapter call sites omit `event:`. Every call does nothing — but
still costs an `NSLock` (via `currentState()`) and a function call **on every
sample**: ~200 wasted lock acquisitions per second at 200 Hz. It also misleads
anyone reading the code into thinking samples are being logged. MOTION rows
actually reach the log via `SessionLogger.logMotionSamples` on the MotionManager
batch path.

The patch shows the removal for V15; the identical block is in V7, V10, V11,
V12, V13 and V14.

### FIX-B — `precision` is discarded, and it is the only working health gate &nbsp; *(severity: high)*

`JumpDetectorV15.processAbsoluteAltitude` does `_ = precisionM`. Measured over
7,612 absolute-altitude samples of `log_287`:

| `precision` | samples | distinct values | reported `accuracy` | reality |
|---|---|---|---|---|
| 5.0 | 968 | **2 (0 %)** | 0.002 – 2.9 → "excellent" | **frozen** |
| 0.5 | 6,644 | **5,339 (80 %)** | ~9.5 → "poor" | **live at 3 Hz** |

`accuracy` is inverted with respect to usefulness, and the engine's
accuracy-based drop rule therefore trusts exactly the wrong samples. On
`log_287` the barometer was coarse for 11 of the 12 reference jumps — including
an 8.5 m one — while Surfr on identical hardware measured them all.

**This is the highest-value fix in the package.** It changes V15's behaviour, so
validate it on your own logs before shipping.

### FIX-C — two independent `bootWallClock` captures &nbsp; *(severity: medium)*

`MotionManager` and each detector adapter separately compute
`Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime`. That
quantity is **not constant**: `systemUptime` does not advance during deep sleep
and the wall clock is NTP-corrected.

IMU samples enter the engine on the raw `motion.timestamp` (uptime domain),
while GPS enters through `monotonicTime(from: CLLocation.timestamp)` — so any
drift between the two capture moments shows up as a **GPS-vs-IMU time skew**.

- For **V16** this degrades cleanly: GPS is metrics-only, so a skew beyond the
  3 s match tolerance just yields `takeoffSpeedMS = nil` / `distanceM = nil`.
- For **V15** it is worse, because GPS participates in the gates.

The patch marks the site and sketches the fix. You already solved the identical
problem for the altimeter with `alignedAbsoluteTimestamp` / `TimestampNormalizer`
— the same treatment should apply to `CLLocation.timestamp`.

### Reviewed and found correct — no action

`sampleBuffer` access (serial `motionProcessingQueue`, correct `.sync` on stop /
pause) · 103 consistent `[weak self]` captures in escaping closures ·
`maxConcurrentOperationCount = 1` on all three sensor `OperationQueue`s ·
the altimeter `generation` guard against stale-stream leakage ·
`CMBatchedSensorManager` → `CMMotionManager` fallback with a 5 s watchdog and a
re-entry guard.

---

## 6. Known limits of V16 — please read before shipping

| Limit | Status |
|---|---|
| **Airtime** | MAE 0.54 s vs 0.78 s for a constant predictor — it barely beats a constant. **Never gate on it.** Shown with a caveat or not at all |
| **Jump distance** | Inherits the airtime error: 6.27 m. With a correct airtime it would be 2.78 m |
| Takeoff speed | 0.64 m/s — reliable, read straight from GPS |
| Jumps < 2.5 m | Their lift shelf (0.2–0.6 s) overlaps the noise floor. **Route to V15** |
| Above 8.5 m | Unvalidated — a fixed 4.5 s window cannot cover a 25 s big-air jump |

**V16 does not replace V15 — it complements it.** V15 reaches 11/12 on
small-jump sessions using GPS discriminators that do not depend on shelf length;
V16 reaches 14/14 on big air with no barometer at all. Route by regime.

---

## 7. Documents — `04_DOCS/`

| File | Contents |
|---|---|
| `V16_SPEC_HE.pdf` | The full physics and mathematics: quaternion rotation, the lift-plateau derivation, the bounded double integration (including why the window must be fixed), airtime, distance |
| `V16_WATCH_INTEGRATION_REVIEW_HE.pdf` | This integration plus the review findings, in Hebrew |
| `V15_2_SPEC_HE.pdf` | The V15.2 engine V16 complements |
