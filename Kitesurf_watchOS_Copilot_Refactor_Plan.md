# Kitesurf watchOS Jump Detection — Copilot Refactor Plan

**Audience:** GitHub Copilot Chat / coding agent working inside the Swift watchOS project.  
**Goal:** Refactor the current jump-detection code safely, add a rolling motion-context buffer, improve false-positive handling, and preserve the current deterministic state-machine behavior.

---

## 0. Copilot instruction block

Paste this section into Copilot Chat before asking it to edit code:

```text
You are working on a Swift/watchOS kitesurfing app. The app detects riding sessions, route, speed, jumps, jump height, airtime, rotations, distance, and confidence.

Do not rewrite the detector from scratch.
Preserve the current JumpDetector state machine:
IDLE -> RIDING -> AIRBORNE -> COOLDOWN.

Add a 20-40 sample rolling context buffer as an evidence layer.
Use it first for logging and confidence only.
Do not hard-reject jumps from the new score until replay logs prove it separates real jumps from false positives.

Keep watchOS performance safe:
- no blocking on the sensor thread
- no heavy allocations inside the 50 Hz loop
- no large per-sample sorting
- pressure filtering only when a new barometer value arrives
- use existing SessionLogger async I/O

Every detected or rejected jump must be explainable from:
GPS speed, sustained takeoff spike, low-G evidence, pressure curve, landing evidence, gyro chaos, and confidence.

Use the uploaded plan as the implementation contract.
Implement in phases and stop after each phase for review.
```

---

## 1. Source-of-truth files

The current codebase pieces are:

| Area | File | Role |
|---|---|---|
| Main algorithm | `Kiters Watch App/Services/JumpDetector.swift` | State machine, takeoff, airborne tracking, landing, height, confidence |
| Session models | `Kiters Watch App/Models/Session.swift` | `Session`, `Jump`, `GPSPoint`, `IMUSample`, `DetectionMode`, `JumpDetectionConfig` |
| Debug logging | `Kiters Watch App/Services/SessionLogger.swift` | Per-sample CSV logging, event logging, mode/config header |
| Replay tooling | `Tools/JumpReplay/` | Offline replay/regression against logs |
| Test logs | `logs/` or uploaded JSON/CSV logs | Normal sessions, short realistic sessions, failure cases |

Primary logs already analyzed:

| Log | Samples | Duration | Approx. rate | Speed | Purpose |
|---|---:|---:|---:|---|---|
| `kitesurf_session_5min_3jumps.json` | 15,000 | ~300s | ~50Hz | ~10–14 m/s | Main normal-session test, expected 3 real jumps |
| `kitesurf_session_5min_3jumps.original.json` | 3,000 | ~300s | ~10Hz | ~9–15 m/s | Lower-rate/raw-unit variant; do not copy thresholds blindly |
| `kitesurf_ultra_realistic_log.json` | 700 | ~14s | ~50Hz | no GPS in file | Short realistic motion/pressure test |
| `kitesurf_extreme_failure_case_log.json` | 900 | ~18s | ~50Hz | no GPS in file | False-positive / chaotic-hand-motion rejection test |

Important unit warning:

```text
Some logs are Android-style or raw-unit logs.
Acceleration may be m/s²-like in some files and g-like user acceleration in others.
Gyro may be deg/s in some logs and rad/s in CoreMotion.
The replay loader must normalize units before thresholds are applied.
Never tune watchOS thresholds directly from a raw log without checking distributions.
```

---

## 2. Current algorithm summary

The current `JumpDetector` already has a strong base. Do not replace it.

### 2.1 State machine

```text
IDLE -> RIDING -> AIRBORNE -> COOLDOWN
```

Responsibilities:

| State | Responsibility |
|---|---|
| `IDLE` | Wait until GPS speed reaches `minSpeed`, unless `devMode` is enabled |
| `RIDING` | Maintain pressure baseline and watch for sustained takeoff spike |
| `AIRBORNE` | Track airtime, pressure minimum, vertical integration/apex, rotations, landing |
| `COOLDOWN` | Prevent duplicate detection from landing bounce or post-landing hand motion |

### 2.2 Detection pipeline

Current takeoff logic:

```text
RIDING:
  accel >= takeoffG for >= 2 consecutive samples
  then low-G for >= 3 consecutive samples
  if no low-G within ~0.5s, reject false takeoff
```

At 50Hz:

```text
2 samples ~= 40ms
3 samples ~= 60ms
40 samples ~= 0.8s
```

Current landing logic:

```text
AIRBORNE:
  hard landing if accel >= landingG and airtime >= minAirtime
  OR barometer recovery near baseline
  OR soft landing if verticalAccelG returns near 1g for 6 of last 8 samples
  timeout if airtime > maxAirtime
```

### 2.3 Height formulas

Primary barometric height:

```text
baroHeight = (baselinePressure - minPressureDuringJump) * 8.3
```

Fallback kinematic height:

```text
kinematicHeight = kinematicCalibration * 9.81 * airtime^2 / 8
```

Final height selection:

```text
if hasBaro && baroHeight > 0.2:
    height = baroHeight
else:
    height = kinematicHeight

height = clamp(height, 0.3, 25.0)
```

### 2.4 Confidence

Current confidence starts at `50`, then adjusts:

```text
+20 barometer confirms height > 0.3m
+15 strong clean takeoff
+8  normal clean takeoff
+10 ride-away speed after landing
+5  airtime >= 1s
-20 stationary takeoff
-15 chaotic gyro
```

A jump is accepted when:

```text
confidence >= 50
```

---

## 3. Refactor north star

The detector should not decide from one sample.

Target behavior:

```text
A real kite jump is a short temporal pattern:
riding speed -> sustained force/spike -> unloading/low-G -> pressure dip -> landing/recovery -> ride-away

A false hand movement/watch toss is usually:
chaotic gyro -> one-sample or noisy spike -> no stable speed context -> no clean low-G sequence -> no believable pressure/landing story
```

Therefore, add:

```text
recentMotion: RingBuffer<SensorFrame>(capacity: 40)
windowAnalyzer: JumpWindowAnalyzer
lastTakeoffEvidence: TakeoffWindowEvidence?
```

The buffer is an **evidence layer**, not a replacement state machine.

---

## 4. Target architecture

```text
CoreMotion / GPS / Barometer
        |
        v
IMUSample + GPS speed
        |
        v
JumpDetector.processSample()
        |
        +--> Pressure filter
        +--> Baseline tracking
        +--> Vertical accel bias buffer
        +--> Recent motion context buffer  <-- new
        |
        v
State machine:
IDLE -> RIDING -> AIRBORNE -> COOLDOWN
        |
        +--> JumpWindowAnalyzer             <-- new
        |       returns TakeoffWindowEvidence
        |
        +--> HeightEstimator logic
        +--> Confidence logic
        +--> SessionLogger events
        +--> onJumpDetected(Jump)
```

Recommended first implementation location:

```text
JumpDetector.swift
  private struct SensorFrame
  private struct TakeoffWindowEvidence
  private struct JumpWindowAnalyzer
  private struct RingBuffer<Element>
```

After behavior is stable, these can be extracted to:

```text
Services/JumpDetection/RingBuffer.swift
Services/JumpDetection/JumpWindowAnalyzer.swift
Services/JumpDetection/PressureFilter.swift
Services/JumpDetection/HeightEstimator.swift
```

Start private/nested to reduce public API churn.

---

## 5. Phase plan

## Phase 0 — Safety baseline, no behavior change

### Objective

Before changing behavior, make the current detector measurable and safe to compare.

### Tasks

1. Run the existing app/tests/replay.
2. Save current replay output for each available log.
3. Confirm current behavior on:
   - `kitesurf_session_5min_3jumps.json`
   - `kitesurf_session_5min_3jumps.original.json`
   - `kitesurf_ultra_realistic_log.json`
   - `kitesurf_extreme_failure_case_log.json`
4. Do not tune thresholds yet.
5. Do not change detection decisions yet.

### Expected output

Create or update a local note/report:

```text
Before refactor:
- detected jump count
- accepted jump count
- rejected jump count
- confidence values
- heights
- airtimes
- false positives in extreme failure log
```

### Acceptance criteria

```text
Project compiles.
Replay tool runs.
Current behavior is documented before edits.
```

---

## Phase 1 — Fix logger safety and prepare richer evidence logs

### Objective

The new analyzer will log rich evidence strings. `SessionLogger` currently writes CSV manually, so event text must be CSV-safe.

### Tasks in `SessionLogger.swift`

1. Fix the comment that says `20 total`; current header has 19 columns:

```text
idx,t,ax,ay,az,aM,gx,gy,gz,gM,gvX,gvY,gvZ,baro,baseBaro,spd,lowG,state,evt
```

2. Add CSV escaping for `state` and `event`.

```swift
private func csv(_ text: String) -> String {
    if text.contains(",") || text.contains("\"") || text.contains("\n") || text.contains("\r") {
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return text
}
```

3. Use `csv(event)` and `csv(state)` when writing rows.

4. Prefer pipe-delimited event reasons:

```text
reason=sustainedSpike|moving|stableSpeed|verticalDrop
```

Do not use commas in `evt` unless CSV escaping is confirmed.

### Acceptance criteria

```text
SessionLogger still writes valid CSV.
Existing log readers still parse the original 19 columns.
Event strings with commas/quotes/newlines do not corrupt the CSV.
No sensor-thread blocking is introduced.
```

---

## Phase 2 — Add rolling context buffer, logging-only

### Objective

Add the 20–40 sample buffer and analyzer, but do not change jump decisions yet.

### Why 40 samples?

At 50Hz:

```text
20 samples = 0.4s
40 samples = 0.8s
```

This is enough to capture:

```text
pre-takeoff riding context
spike shape
low-G beginning
gyro chaos
speed stability
pressure movement
```

### Add `RingBuffer`

Add as private nested type first:

```swift
private struct RingBuffer<Element> {
    private var storage: [Element?]
    private var writeIndex: Int = 0
    private(set) var count: Int = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % storage.count
        count = min(count + 1, storage.count)
    }

    func snapshot() -> [Element] {
        guard count > 0 else { return [] }

        let start = count == storage.count ? writeIndex : 0
        var result: [Element] = []
        result.reserveCapacity(count)

        for offset in 0..<count {
            let index = (start + offset) % storage.count
            if let element = storage[index] {
                result.append(element)
            }
        }

        return result
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: storage.count)
        writeIndex = 0
        count = 0
    }
}
```

### Add `SensorFrame`

Do not store only `IMUSample`. Store derived values so the analyzer does not recompute everything.

```swift
private struct SensorFrame {
    let timestamp: Date
    let accelMag: Double
    let verticalG: Double
    let gyroMag: Double
    let speed: Double
    let rawPressure: Double?
    let filteredPressure: Double
    let baselinePressure: Double
    let pressureDrop: Double
    let state: JumpState
}
```

### Add properties to `JumpDetector`

```swift
private var recentMotion = RingBuffer<SensorFrame>(capacity: 40)
private let windowAnalyzer = JumpWindowAnalyzer()
private var lastTakeoffEvidence: TakeoffWindowEvidence?
```

Reset them in `reset()` and `clearJumpState()` as appropriate:

```swift
recentMotion.removeAll()
lastTakeoffEvidence = nil
```

Important: clearing `recentMotion` on every jump finalization may remove useful cooldown context. For the first implementation, clear only in `reset()`. Clear `lastTakeoffEvidence` in `clearJumpState()`.

### Append a frame in `processSample`

After pressure filtering and baseline update, before `switch state`:

```swift
let frame = SensorFrame(
    timestamp: sample.timestamp,
    accelMag: accel,
    verticalG: verticalAccelG(of: sample),
    gyroMag: sample.rotationMagnitude,
    speed: speed,
    rawPressure: sample.pressure,
    filteredPressure: filteredPressure,
    baselinePressure: baselinePressure,
    pressureDrop: max(0, baselinePressure - filteredPressure),
    state: state
)

recentMotion.append(frame)
```

### Add `TakeoffWindowEvidence`

```swift
private struct TakeoffWindowEvidence {
    let score: Double
    let spikeCount: Int
    let lowGCount: Int
    let maxAccel: Double
    let minVerticalG: Double
    let avgGyro: Double
    let maxGyro: Double
    let avgSpeed: Double
    let speedStable: Bool
    let pressureDrop: Double
    let chaoticMotion: Bool
    let reason: String

    var isStrong: Bool {
        score >= 70 && !chaoticMotion
    }

    var isSuspicious: Bool {
        score < 35 || chaoticMotion
    }
}
```

### Add `JumpWindowAnalyzer`

Initial scoring rules:

```text
+25 sustained spike: >= 2 samples over takeoffG
+25 low-G evidence: >= 3 samples under lowGCeiling
+15 moving: average speed >= minSpeed
+10 stable speed: window speed spread < 4.0 m/s
+10 vertical drop: minVerticalG < lowGCeiling
+10 pressureDrop > 0.02 hPa, if available

-15 single-sample impulse
-15 spike exists but no low-G yet
-20 stationary: avgSpeed < stationarySpeed
-25 chaotic gyro: avgGyro > 8.0 and maxGyro > 15.0
```

Analyzer should only consume `SensorFrame` values, not `JumpDetector` internals.

```swift
private struct JumpWindowAnalyzer {

    func analyzeTakeoffWindow(
        _ frames: [SensorFrame],
        mode: DetectionMode,
        lowGCeiling: Double,
        stationarySpeed: Double
    ) -> TakeoffWindowEvidence {
        guard !frames.isEmpty else {
            return TakeoffWindowEvidence(
                score: 0,
                spikeCount: 0,
                lowGCount: 0,
                maxAccel: 0,
                minVerticalG: 999,
                avgGyro: 0,
                maxGyro: 0,
                avgSpeed: 0,
                speedStable: false,
                pressureDrop: 0,
                chaoticMotion: false,
                reason: "empty"
            )
        }

        let accelValues = frames.map(\.accelMag)
        let verticalValues = frames.map(\.verticalG)
        let gyroValues = frames.map(\.gyroMag)
        let speedValues = frames.map(\.speed)

        let maxAccel = accelValues.max() ?? 0
        let minVerticalG = verticalValues.min() ?? 999
        let spikeCount = frames.filter { $0.accelMag >= mode.takeoffG }.count
        let lowGCount = frames.filter { $0.accelMag < lowGCeiling || $0.verticalG < lowGCeiling }.count

        let avgGyro = gyroValues.reduce(0, +) / Double(gyroValues.count)
        let maxGyro = gyroValues.max() ?? 0

        let avgSpeed = speedValues.reduce(0, +) / Double(speedValues.count)
        let minSpeed = speedValues.min() ?? 0
        let maxSpeed = speedValues.max() ?? 0
        let speedStable = avgSpeed >= mode.minSpeed && (maxSpeed - minSpeed) < 4.0

        let pressureDrop = frames.map(\.pressureDrop).max() ?? 0
        let chaoticMotion = avgGyro > 8.0 && maxGyro > 15.0

        var score: Double = 0
        var reasons: [String] = []

        if spikeCount >= 2 {
            score += 25
            reasons.append("sustainedSpike")
        } else if spikeCount == 1 {
            score -= 15
            reasons.append("singleImpulse")
        }

        if lowGCount >= 3 {
            score += 25
            reasons.append("lowG")
        } else if spikeCount >= 2 {
            score -= 15
            reasons.append("noLowGYet")
        }

        if avgSpeed >= mode.minSpeed {
            score += 15
            reasons.append("moving")
        }

        if speedStable {
            score += 10
            reasons.append("stableSpeed")
        }

        if minVerticalG < lowGCeiling {
            score += 10
            reasons.append("verticalDrop")
        }

        if pressureDrop > 0.02 {
            score += 10
            reasons.append("pressureDrop")
        }

        if avgSpeed < stationarySpeed {
            score -= 20
            reasons.append("stationary")
        }

        if chaoticMotion {
            score -= 25
            reasons.append("chaoticGyro")
        }

        return TakeoffWindowEvidence(
            score: max(0, min(100, score)),
            spikeCount: spikeCount,
            lowGCount: lowGCount,
            maxAccel: maxAccel,
            minVerticalG: minVerticalG,
            avgGyro: avgGyro,
            maxGyro: maxGyro,
            avgSpeed: avgSpeed,
            speedStable: speedStable,
            pressureDrop: pressureDrop,
            chaoticMotion: chaoticMotion,
            reason: reasons.joined(separator: "|")
        )
    }
}
```

### Log evidence in `handleRiding`

When `takeoffSpikeCount >= takeoffConfirmSamples`, analyze the window and log it.

Do not reject yet.

```swift
let evidence = windowAnalyzer.analyzeTakeoffWindow(
    recentMotion.snapshot(),
    mode: mode,
    lowGCeiling: lowGCeiling,
    stationarySpeed: stationarySpeed
)

lastTakeoffEvidence = evidence

logger.logEvent(
    "WINDOW_TAKEOFF score=\(Int(evidence.score)) spike=\(evidence.spikeCount) lowG=\(evidence.lowGCount) maxA=\(String(format: "%.2f", evidence.maxAccel)) minVG=\(String(format: "%.2f", evidence.minVerticalG)) avgGyr=\(String(format: "%.2f", evidence.avgGyro)) maxGyr=\(String(format: "%.2f", evidence.maxGyro)) spd=\(String(format: "%.2f", evidence.avgSpeed)) drop=\(String(format: "%.3f", evidence.pressureDrop)) reason=\(evidence.reason)",
    state: "RIDING",
    speed: speed
)
```

### Acceptance criteria

```text
Project compiles.
No behavior change in accepted/rejected jumps.
Logs now contain WINDOW_TAKEOFF events.
Real jumps should generally score higher than false-motion windows.
Extreme failure log should show suspicious evidence, especially chaoticGyro/stationary/noLowGYet.
```

---

## Phase 3 — Use window evidence in confidence, not hard rejection

### Objective

Make the evidence useful while preserving real-jump recall.

### Modify `computeConfidence`

Add `lastTakeoffEvidence` as an input or read the property inside the function.

Recommended first scoring:

```swift
if let evidence = lastTakeoffEvidence {
    if evidence.score >= 75 && !evidence.chaoticMotion {
        conf += 8
    } else if evidence.score >= 60 && !evidence.chaoticMotion {
        conf += 4
    } else if evidence.score < 35 {
        conf -= 8
    }

    if !devMode && evidence.chaoticMotion {
        conf -= 10
    }
}
```

### Important

Do not make this too strong at first. The existing confidence system already penalizes stationary takeoff and chaotic gyro from `jumpSamples`. The window score should refine confidence, not dominate it.

### Add logging to finalize

Append the window score to the final jump event:

```swift
let winStr = lastTakeoffEvidence.map { " win=\(Int($0.score)) \($0.reason)" } ?? ""
logger.logEvent("JUMP_\(result)\(winStr)", state: "FINALIZE", speed: speed)
```

### Acceptance criteria

```text
Normal 3-jump session still accepts the expected jumps.
False-positive log confidence decreases.
No real jump is rejected only because of the new confidence adjustment unless its original confidence was already borderline and evidence is suspicious.
```

---

## Phase 4 — Add soft rejection only for obvious false positives

### Objective

After evidence logs prove separation, use the buffer to reject only the clearest hand-motion/watch-toss cases.

### Safe rejection rule

Do not use:

```text
if score < 60 reject
```

That is too aggressive because low-G might not have happened yet at the spike moment.

Use only obvious false-positive patterns:

```swift
let obviousHandMotion =
    evidence.chaoticMotion &&
    evidence.lowGCount == 0 &&
    evidence.avgSpeed < mode.minSpeed &&
    !devMode

if obviousHandMotion {
    logger.logEvent(
        "TAKEOFF_REJECTED_BY_WINDOW score=\(Int(evidence.score)) reason=\(evidence.reason)",
        state: "RIDING",
        speed: speed
    )

    takeoffTime = nil
    jumpSamples.removeAll()
    lowGCount = 0
    takeoffSpikeCount = 0
    takeoffPeakVerticalG = 0
    lastTakeoffEvidence = nil
    return
}
```

Optional stronger rule after validation:

```text
reject if:
chaoticMotion
AND lowGCount == 0
AND pressureDrop < 0.02
AND avgSpeed < minSpeed
```

### Acceptance criteria

```text
Extreme failure log has zero accepted false jumps.
Normal 3-jump log still detects expected jumps.
No production jump can be rejected solely from high gyro if speed/low-G/pressure evidence is otherwise good.
Dev mode bypasses production rejection rules.
```

---

## Phase 5 — Refactor internal modules after behavior is stable

Only extract classes after replay results are stable.

Recommended extraction order:

1. `RingBuffer.swift`
2. `JumpWindowAnalyzer.swift`
3. `PressureFilter.swift`
4. `HeightEstimator.swift`
5. `JumpConfidenceScorer.swift`

### 5.1 `PressureFilter`

Move:

```text
pressureMedianBuffer
pressureMedianSize
pressureLP1
pressureLP2
filteredPressure
filterPressure(_:)
```

into:

```swift
struct PressureFilter {
    mutating func update(rawPressure: Double) -> Double
    mutating func reset()
}
```

Rules:

```text
Only call update when raw pressure changes.
Keep median size 7.
Do not update baseline inside PressureFilter.
PressureFilter only filters pressure; JumpDetector owns baseline/minPressure.
```

### 5.2 `HeightEstimator`

Move:

```text
computeBaroHeight()
computeKinematicHeight(airtime:)
```

into pure functions:

```swift
struct HeightEstimator {
    static func barometricHeight(baseline: Double, minPressure: Double, factor: Double = 8.3) -> Double
    static func kinematicHeight(airtime: Double, calibration: Double) -> Double
}
```

### 5.3 `JumpConfidenceScorer`

Move the final score into a small testable unit:

```swift
struct JumpConfidenceInputs {
    let airtime: Double
    let baroHeight: Double
    let hasBaro: Bool
    let peakTakeoff: Double
    let landingSpeed: Double
    let takeoffSpeed: Double
    let avgGyro: Double
    let maxGyro: Double
    let windowEvidence: TakeoffWindowEvidence?
    let devMode: Bool
}
```

Keep the output:

```swift
struct ConfidenceResult {
    let score: Double
    let reasons: [String]
}
```

This makes confidence explainable and easier to test.

---

## 6. Replay and regression workflow

### Required test set

Run every phase against:

```text
Normal:  kitesurf_session_5min_3jumps.json
Raw:     kitesurf_session_5min_3jumps.original.json
Short:   kitesurf_ultra_realistic_log.json
Failure: kitesurf_extreme_failure_case_log.json
```

### Expected direction

| Log | Expected behavior |
|---|---|
| `kitesurf_session_5min_3jumps.json` | Detect and accept the known real jumps; do not reduce recall |
| `kitesurf_session_5min_3jumps.original.json` | Use only after loader normalization; do not directly tune thresholds from this raw variant |
| `kitesurf_ultra_realistic_log.json` | Good for pressure/motion plausibility |
| `kitesurf_extreme_failure_case_log.json` | Should not create accepted jumps; should log suspicious evidence |

### Regression commands

Use project tooling where available:

```bash
cd Tools/JumpReplay
./verify.sh --verbose
./verify.sh
```

Only bless baselines after manual review:

```bash
./verify.sh --bless
```

### Compare these metrics per run

```text
jump count
accepted count
rejected count
takeoff offset
airtime
height
height source: baro | kinematic
apex time
confidence
rotations
jump distance
landing type
window score
window reasons
false-positive count
```

### Tolerances

Use existing replay tolerances where defined:

```text
jump count: exact
airtime: +/- 0.2s
height: +/- 15%
apex: +/- 0.3s
accepted flag: exact
```

---

## 7. Concrete code-edit checklist for Copilot

### Edit 1 — `SessionLogger.swift`

- [ ] Fix column-count comment from 20 to 19, unless adding a real new column.
- [ ] Add `csv(_:)`.
- [ ] Escape `event`.
- [ ] Escape `state`.
- [ ] Keep async I/O on `ioQueue`.
- [ ] Do not block sensor thread.

### Edit 2 — `JumpDetector.swift`: add types/properties

- [ ] Add `RingBuffer<Element>`.
- [ ] Add `SensorFrame`.
- [ ] Add `TakeoffWindowEvidence`.
- [ ] Add `JumpWindowAnalyzer`.
- [ ] Add `recentMotion`.
- [ ] Add `windowAnalyzer`.
- [ ] Add `lastTakeoffEvidence`.
- [ ] Reset new state safely.

### Edit 3 — `JumpDetector.swift`: append frames

- [ ] Build `SensorFrame` in `processSample`.
- [ ] Append to `recentMotion`.
- [ ] Do not snapshot/analyze every sample.
- [ ] Only snapshot when takeoff candidate is interesting.

### Edit 4 — `JumpDetector.swift`: evidence logging

- [ ] Analyze recent window when sustained spike is confirmed.
- [ ] Log `WINDOW_TAKEOFF`.
- [ ] Store `lastTakeoffEvidence`.
- [ ] Do not change accept/reject behavior in this phase.

### Edit 5 — confidence integration

- [ ] Add window evidence to confidence.
- [ ] Keep adjustment small.
- [ ] Log window score in final jump event.
- [ ] Run replay before and after.

### Edit 6 — soft rejection

- [ ] Reject only obvious hand motion.
- [ ] Use `chaoticMotion && lowGCount == 0 && avgSpeed < minSpeed`.
- [ ] Skip rejection in dev mode.
- [ ] Log `TAKEOFF_REJECTED_BY_WINDOW`.

---

## 8. Implementation cautions

### 8.1 Do not overfit

Do not tune thresholds to make one log pass if another realistic log fails.

Bad:

```text
Increase takeoffG until extreme failure passes.
```

Good:

```text
Use temporal evidence:
singleImpulse, noLowGYet, stationary, chaoticGyro, no pressure story.
```

### 8.2 Do not make pressure alone decide jumps

A pressure drop can happen from noise, weather drift, water impact, or strap movement. Pressure is primary for height, not by itself enough for takeoff.

### 8.3 Do not update baseline while airborne

The current code correctly updates baseline only while idle/riding. Keep that rule.

### 8.4 Do not ignore speed in production

GPS speed is a major false-positive guard. `devMode` may skip it for testing, but production detection should use it.

### 8.5 Do not assume gyro units

CoreMotion gyro is rad/s. Some imported logs may be deg/s. Replay loader must normalize before `rotationMagnitude` and thresholds.

### 8.6 Avoid high-cost code in the 50Hz loop

Allowed per sample:

```text
simple arithmetic
append to fixed-size ring buffer
a few scalar updates
logger call already designed async
```

Avoid per sample:

```text
large map/filter/reduce over arrays
sorting large arrays
JSON encoding
file I/O
network calls
ML inference
```

Snapshot/analyze only on candidate events.

---

## 9. Suggested event names

Use consistent event names for offline analysis:

```text
WINDOW_TAKEOFF
TAKEOFF_REJECTED_BY_WINDOW
CONFIDENCE_WINDOW_BONUS
CONFIDENCE_WINDOW_PENALTY
RIDING_TO_AIRBORNE
FALSE_TAKEOFF_NO_LOWG
HARD_LAND
BARO_LAND
SOFT_LAND
AIRBORNE_TIMEOUT
JUMP_ACCEPTED
JUMP_REJECTED
```

Current code already logs similar events. Keep existing event names where possible; add new ones only when useful.

Example event:

```text
WINDOW_TAKEOFF score=72 spike=3 lowG=3 maxA=2.11 minVG=0.21 avgGyr=2.40 maxGyr=6.70 spd=11.80 drop=0.044 reason=sustainedSpike|lowG|moving|stableSpeed|verticalDrop|pressureDrop
```

False-positive example:

```text
TAKEOFF_REJECTED_BY_WINDOW score=10 reason=singleImpulse|stationary|chaoticGyro|noLowGYet
```

---

## 10. Definition of done

The refactor is done when:

```text
1. JumpDetector still uses the original state machine.
2. Recent 20-40 sample buffer is implemented.
3. Window evidence is logged and explainable.
4. Confidence uses window evidence gently.
5. Obvious hand-motion false positives can be rejected.
6. Normal 3-jump log still detects the real jumps.
7. Extreme failure log does not produce accepted jumps.
8. SessionLogger CSV remains parseable.
9. Replay/regression workflow is documented.
10. Code remains watchOS-safe and efficient.
```

---

## 11. First Copilot task prompt

Use this prompt first:

```text
Implement Phase 1 and Phase 2 only.

Files:
- Kiters Watch App/Services/SessionLogger.swift
- Kiters Watch App/Services/JumpDetector.swift

Goals:
1. Make SessionLogger event/state CSV-safe.
2. Add a private RingBuffer<SensorFrame> to JumpDetector.
3. Add TakeoffWindowEvidence and JumpWindowAnalyzer.
4. Append SensorFrame in processSample.
5. On sustained takeoff spike, log WINDOW_TAKEOFF evidence.
6. Do not change jump accept/reject behavior yet.
7. Do not change height formulas.
8. Do not change the existing state machine.
9. Keep all new types private initially.
10. Show me the diff before continuing to confidence/rejection changes.
```

---

## 12. Second Copilot task prompt

Use this after replay logs confirm window scores are useful:

```text
Implement Phase 3 only.

Use lastTakeoffEvidence to adjust confidence gently:
+8 for very strong clean evidence,
+4 for decent clean evidence,
-8 for low score,
-10 for chaoticMotion outside devMode.

Add the window score/reasons to the final jump log event.
Do not add hard rejection yet.
Show the diff and summarize replay changes.
```

---

## 13. Third Copilot task prompt

Use this only after the extreme failure log still shows false positives:

```text
Implement Phase 4 only.

Add soft rejection for obvious hand-motion/watch-toss takeoff candidates:
chaoticMotion && lowGCount == 0 && avgSpeed < mode.minSpeed && !devMode.

Log TAKEOFF_REJECTED_BY_WINDOW.
Do not reject based only on score < 60.
Run replay against normal and failure logs.
Show the diff and results.
```

---

## 14. Final architecture after stabilization

After behavior is stable, the codebase should look like this:

```text
Services/
  JumpDetector.swift                 // state machine only
  SessionLogger.swift                // async CSV/event logging

Services/JumpDetection/
  RingBuffer.swift                   // fixed-size buffer
  SensorFrame.swift                  // derived per-sample context
  JumpWindowAnalyzer.swift           // temporal evidence score
  PressureFilter.swift               // median + IIR pressure smoothing
  HeightEstimator.swift              // baro + kinematic height
  JumpConfidenceScorer.swift         // explainable confidence
```

Do extraction only after replay confirms no regression.

---

## 15. Product-level outcome

The goal is an iSurf-style watchOS kitesurf analytics engine that can say:

```text
Accepted jump because:
- rider was moving fast enough
- takeoff spike was sustained
- low-G followed
- barometer dipped and recovered
- landing was detected
- rider rode away
- confidence was high

Rejected candidate because:
- one-sample impulse
- chaotic wrist/hand motion
- no low-G sequence
- stationary or unstable speed context
- no believable pressure story
```

This is the correct long-term direction: deterministic, explainable, efficient, and testable before any advanced ML or heavier modeling is considered.
