# Skill: watchOS Kitesurf Session & Jump Intelligence

## Purpose
This skill teaches an AI coding agent how to work efficiently on a Swift/watchOS kitesurfing app that tracks riding sessions, route, speed, jumps, jump height, airtime, distance, rotations, and confidence — similar in spirit to iSurf-style riding analytics.

The agent must treat the Apple Watch as a noisy wearable sensor platform. It must never trust a single sensor alone. Jump detection and metrics must be based on sensor fusion: GPS + barometer + accelerometer + gravity vector + gyroscope + time continuity.

---

## Project Context
The current project contains a `JumpDetector.swift` module using a barometer-first jump detection model.

Current state machine:

```text
IDLE → RIDING → AIRBORNE → COOLDOWN
```

Meaning:

- `IDLE`: wait until GPS speed passes `minSpeed`.
- `RIDING`: monitor for a real takeoff candidate.
- `AIRBORNE`: track pressure curve, acceleration, airtime, landing, rotations.
- `COOLDOWN`: prevent duplicate jump detection after a landing.

The current detector is intentionally simple but robust: barometer is primary for height, IMU is used for confirmation, fallback, filtering, and confidence.

---

## Core Sensor Inputs
The agent should expect samples shaped roughly like this:

```swift
timestamp
accX, accY, accZ          // user acceleration or acceleration components
 gravX, gravY, gravZ      // gravity vector
baro                       // pressure in hPa
 gyrX, gyrY, gyrZ         // gyroscope / rotation rate
gpsLat, gpsLon
gpsAcc(m)
gpsSpeed(m/s)
```

The agent must always check units before changing formulas. Some logs may use acceleration close to raw m/s², while newer processed logs may behave like user acceleration in g-like values. Do not blindly mix thresholds between logs without checking value ranges.

---

## Main Formulas

### 1. Barometric jump height
Primary height formula:

```text
heightMeters = (baselinePressure - minPressureDuringJump) × 8.3
```

Where:

- `baselinePressure` is the filtered rolling pressure before takeoff while riding.
- `minPressureDuringJump` is the lowest filtered pressure during airborne state.
- `8.3 m/hPa` is the approximate near-sea-level pressure-to-height factor.

Rules:

- Use filtered pressure, not raw pressure.
- Update baseline only in `IDLE` or `RIDING`, never during `AIRBORNE`.
- Track `minPressure` only while airborne.
- Accept barometer height when barometer exists and height is reasonable, for example `> 0.2m`.
- Clamp final height to a reasonable range, currently `0.3m...25m`.

### 2. Kinematic fallback height
Fallback when barometer is missing or unreliable:

```text
heightMeters = calibrationFactor × g × airtime² / 8
```

Current default pattern:

```text
g = 9.81
calibrationFactor ≈ 1.12
```

This assumes a roughly symmetric jump arc, but kite jumps are often asymmetric, so the calibration factor compensates for typical underestimation.

### 3. Jump distance
Approximate horizontal jump distance:

```text
jumpDistance = min(150, takeoffSpeed × airtime)
```

Where:

- `takeoffSpeed` is GPS speed at takeoff in m/s.
- `airtime` is seconds from takeoff to landing.

### 4. Vertical acceleration in world frame
Use gravity projection to make acceleration robust to watch rotation:

```text
gMag = sqrt(gravX² + gravY² + gravZ²)
dot = (accX×gravX + accY×gravY + accZ×gravZ) / gMag
verticalAccelG = abs(dot + gMag)
```

Interpretation:

- At rest: around `1.0g`.
- In free fall / airborne low-load phase: closer to `0.0g`.
- Hard landing: above `1.0g`.

This is preferred over raw acceleration magnitude because the watch rotates on the wrist during jumps.

### 5. Rotation count
Integrate gyroscope magnitude during airborne samples:

```text
rotationMagnitude = sqrt(gyrX² + gyrY² + gyrZ²)
totalRadians += rotationMagnitude × dt
rotations = Int(totalRadians / (2π))
```

Important: confirm whether gyroscope values are radians/sec or degrees/sec. If logs or APIs use degrees/sec, convert to radians/sec before integration:

```text
radPerSec = degPerSec × π / 180
```

---

## Pressure Filtering Pipeline
Use this pressure filter before baseline/minPressure logic:

```text
raw pressure → median window(7) → IIR low-pass α=0.30 → IIR low-pass α=0.15
```

Rules:

- Filter only when a new raw pressure value arrives.
- Apple Watch barometer may update slower than IMU; do not push duplicated pressure values repeatedly through the IIR filter.
- Median removes short spikes from board impact, vibration, wrist movement, or strap rattle.
- Cascaded IIR creates a smooth pressure curve for jump height.

---

## Jump Detection Logic

### State: IDLE
Transition to `RIDING` when:

```text
gpsSpeed >= minSpeed
```

Do not detect jumps while stationary unless dev/test mode explicitly disables the GPS gate.

### State: RIDING
A jump candidate requires a sustained takeoff spike:

```text
accelerationMagnitude >= takeoffG
for at least 2 consecutive samples
```

At 50Hz, 2 samples ≈ 40ms. This rejects many one-sample hand-wave impulses.

Then confirm airborne using low-G:

```text
accelerationMagnitude < lowGCeiling
OR
verticalAccelG < lowGCeiling
```

Current low-G rule:

```text
lowGCeiling = 0.40
lowGConfirmSamples = 3
```

At 50Hz, 3 samples ≈ 60ms.

If low-G is not confirmed within about 0.5 seconds after takeoff spike, reject as false takeoff.

### State: AIRBORNE
Track:

- `airtime`
- filtered pressure minimum
- vertical velocity estimate
- apex time
- gyro integration for rotations
- landing signals

Landing conditions can be:

1. Hard landing:

```text
accelerationMagnitude >= landingG
AND airtime >= minAirtime
```

2. Barometric recovery:

```text
filteredPressure >= baselinePressure - max(currentDrop × 0.08, 0.03)
```

3. Soft landing:

```text
verticalAccelG returns to about 1g, ±0.3, for 6 of last 8 samples
```

Timeout if:

```text
airtime > maxAirtime
```

### State: COOLDOWN
After a completed jump, wait `cooldown` seconds before detecting another jump. This prevents duplicate detections from landing bounce or post-landing hand motion.

---

## Confidence Score
Start at:

```text
confidence = 50
```

Add:

```text
+20 if barometer confirms height > 0.3m
+15 if takeoff spike is clean and strong
+10 if rider still moves after landing, e.g. speed > 2m/s
+5  if airtime > 1s
```

Subtract:

```text
-20 if takeoff was stationary
-15 if gyro is chaotic, indicating possible watch toss or aggressive hand motion
```

Clamp:

```text
confidence = 0...100
```

Recommended acceptance rule:

```text
accept jump if confidence >= 50
```

---

## Handling Excessive Hand Movement
The agent must protect against false jumps caused by hand movement.

Use these gates together:

1. GPS movement gate:

```text
speed >= minSpeed
```

2. Sustained takeoff spike, not one sample.

3. Low-G confirmation after takeoff spike.

4. Pressure drop confirmation when available.

5. Ride-away speed after landing.

6. Chaotic gyro penalty.

7. Optional vertical/world-frame acceleration checks.

A hand wave often has high acceleration but lacks a clean pressure curve, lacks true low-G, may happen while stationary, and may show chaotic gyro.

---

## Calibration Workflow
When the user provides logs, the agent should analyze them like this:

1. Identify sample rate:

```text
sampleRate = sampleCount / durationSeconds
```

2. Detect units and distributions:

- acceleration median and max
- gyro median and max
- speed min/avg/max
- pressure min/max/range

3. Segment possible jumps:

- sustained acceleration spike
- low-G window
- barometric pressure drop
- pressure recovery
- landing impact or soft-landing normalization

4. Compare detected jumps to expected jump count.

5. Tune only one or two thresholds at a time.

6. Re-run the same logs after every algorithm change.

7. Keep separate logs for:

- normal session with real jumps
- realistic noisy session
- extreme failure case
- stationary / hand movement / watch toss

---

## Current Log Observations From Provided Files

From the provided logs:

- `kitesurf_session_5min_3jumps.json`: about 15,000 samples over about 300 seconds, approximately 50Hz. GPS speed is around 10–14 m/s, suitable for active riding. Pressure range is around 0.956 hPa, equivalent to roughly 7.9m possible barometric swing if treated as full jump range.
- `kitesurf_session_5min_3jumps.original.json`: about 3,000 samples over about 300 seconds, approximately 10Hz. Acceleration values are closer to raw m/s² style, so thresholds must not be copied blindly from the 50Hz normalized file.
- `kitesurf_ultra_realistic_log.json`: about 700 samples over about 14 seconds, approximately 50Hz, with a pressure range around 0.653 hPa, roughly 5.4m equivalent range.
- `kitesurf_extreme_failure_case_log.json`: about 900 samples over about 18 seconds, approximately 50Hz, with very high acceleration and chaotic gyro. This should be used as a false-positive rejection test.

---

## Agent Rules For Editing Swift/watchOS Code

When changing the code, the agent must:

1. Preserve the state machine unless there is a clear reason to refactor.
2. Keep sensor-processing code efficient for watchOS.
3. Avoid heavy allocations in 50Hz loops.
4. Avoid sorting large arrays per sample.
5. Keep pressure filtering cheap because barometer updates slowly.
6. Avoid blocking the main thread.
7. Keep GPS updates thread-safe.
8. Add logs around state transitions and jump finalization.
9. Make every threshold configurable via `DetectionMode` or config.
10. Never “fix” false positives by making thresholds unrealistically strict without testing against real jump logs.

---

## Recommended DetectionMode Parameters

Keep these as the main user-tunable parameters:

```text
minSpeed
 takeoffG
landingG
minAirtime
maxAirtime
cooldown
kinematicCalibration
```

Suggested starting point:

```text
minSpeed: 4.0–6.0 m/s
stationarySpeed: 1.0 m/s
takeoffConfirmSamples: 2
lowGCeiling: 0.40g
lowGConfirmSamples: 3
minAirtime: 0.4–0.6s
maxAirtime: 6–8s
cooldown: 1.0–2.0s
baroFactor: 8.3 m/hPa
kinematicCalibration: 1.12
```

Exact values must be calibrated against real rider logs.

---

## Output Metrics Per Jump
Each detected jump should output:

```text
startTime
endTime
height
airtime
jumpDistance
rotations
confidence
apexTime
sourceOfHeight: barometer | kinematic
rejectionReason, if rejected
```

For debugging, also log:

```text
baselinePressure
minPressure
baroHeight
kinematicHeight
takeoffSpeed
peakTakeoffAccel
avgGyro
maxGyro
landingType: hard | baroRecovery | soft | timeout
```

---

## What The Agent Should Do When Given New Logs
When a new log is uploaded, the agent should respond with:

1. Session summary: duration, sample rate, speed range, pressure range, acceleration/gyro stats.
2. Detected candidate jump windows.
3. For each candidate: takeoff time, landing time, airtime, baro height, kinematic height, confidence, reason accepted/rejected.
4. Calibration recommendation.
5. Exact Swift changes only if needed.

---

## Do Not Do
The agent must not:

- Use acceleration magnitude alone to detect jumps.
- Treat every pressure drop as a jump.
- Update baseline pressure while airborne.
- Ignore GPS speed for production detection.
- Ignore hand movement and watch toss false positives.
- Assume gyro units without checking.
- Use large ML models on-watch for real-time detection before deterministic logic is stable.
- Overfit thresholds to one log.

---

## North Star
The goal is not just to detect “a jump.” The goal is to produce trusted kitesurfing session intelligence:

```text
fast route tracking + accurate speed + robust jump detection + believable height + low false positives + explainable confidence
```

Every detected jump should be explainable from evidence: speed, takeoff, low-G, pressure curve, landing, and confidence.
