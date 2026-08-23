# Engine V12 End-to-End Workflow Summary

This document summarizes the V12 Apple Sensor Fusion jump engine as wired in the
current WatchOS SurfHub codebase. It follows the production path from Settings to
sensor ingestion, algorithm decisions, jump emission, refinement, logging, and
fallback behavior.

## 1. What V12 Is

V12 is an opt-in jump detection engine for Apple Watch. It fuses:

- `CMBatchedSensorManager` device motion for takeoff and landing timing.
- `CMAltimeter.relativeAltitude` for jump height.
- `CLLocation` speed and position for planing gate and distance.
- `CMWaterSubmersionManager` state when available for optional landing support.

The key design is split responsibility:

- IMU gives event timing: takeoff yank and landing evidence.
- Barometer gives height: relative altitude arc over the jump.
- GPS gives context: rider is planing and distance estimate.
- Water state is optional corroboration, never required.

## 2. Main Code Map

- Watch settings engine picker:
  `SPOTEQ/SPOTEQ Watch App/Views/SettingsView.swift`

- Engine enum and IMU sample model:
  `SPOTEQ/SPOTEQ Watch App/Models/Session.swift`

- Session engine factory and callback wiring:
  `SPOTEQ/SPOTEQ Watch App/Services/SessionManager.swift`

- V12 pure algorithm:
  `SPOTEQ/SPOTEQ Watch App/Services/JumpEngineV12.swift`

- V12 app adapter:
  `SPOTEQ/SPOTEQ Watch App/Services/JumpDetectorV12.swift`

- Sensor producer:
  `SPOTEQ/SPOTEQ Watch App/Services/MotionManager.swift`

- Diagnostic log metadata:
  `SPOTEQ/SPOTEQ Watch App/Services/SessionLogger.swift`

- SwiftPM synthetic pipeline check:
  `SPOTEQ/Tests/WatchLiveSessionCoreChecks/main.swift`

Reference source material:

- `engine_v12/refwexternal/JumpEngineV12.swift`
- `engine_v12/refwexternal/jumpEngineV12.ts`
- `engine_v12/refwexternal/V12_DEV_PLAN_WATCH_TEAM.md`

## 3. Settings to Session Startup

1. User selects `V12 Sensor Fusion` in Settings.
2. The selection is persisted in `@AppStorage("detectionEngine")`.
3. When a new session starts, `SessionManager` reads `detectionEngine`.
4. `makeJumpDetector(for:)` handles the engine factory decision.
5. If V12 readiness passes, SessionManager creates `JumpDetectorV12`.
6. If V12 readiness fails, SessionManager falls back to `JumpDetectorV11`, keeps
   the settings selection unchanged, shows a V12 unavailable notice, and logs the
   fallback reason.

Readiness checks include:

- watchOS 10+ API gate.
- `CMBatchedSensorManager` device motion support.
- Motion authorization not denied or restricted.
- Altimeter authorization not denied or restricted.
- `CMAltimeter.isRelativeAltitudeAvailable()`.

## 4. Sensor Pipeline

Session startup prepares the detector before sensors begin streaming. This keeps
the first IMU/GPS samples attached to the correct engine and session.

The session then starts:

1. Workout manager.
2. Location tracking.
3. Motion pipeline.
4. Optional water submersion manager.
5. Session logger.

`MotionManager` prefers high-rate `CMBatchedSensorManager` device motion when the
workout becomes active. If the workout does not become active quickly enough, it
falls back to `CMMotionManager` so the session still records motion instead of
dropping the beginning.

Each `IMUSample` now carries:

- Wall-clock timestamp for app/session compatibility.
- `motionTimestamp`, the CoreMotion monotonic timestamp.
- User acceleration and rotation.
- Gravity vector.
- Pressure in hPa.
- `relativeAltitude` in metres.
- `barometerTimestamp`, the CMAltimeter monotonic timestamp.
- Optional water submersion state/depth/pressure.

V12 uses monotonic timestamps so IMU, barometer, GPS, and water state share one
timebase.

## 5. V12 Adapter Flow

`JumpDetectorV12` conforms to `JumpDetecting`, so SessionManager can drive it the
same way as v7-v11.

Inputs:

- `updateGPS(...)` feeds speed and position into `JumpPipelineV12.addLocation`.
- `processSample(...)` feeds:
  - submersion state changes into `addSubmersion`
  - deduplicated barometer frames into `addBaro`
  - every motion sample into `addAccel`

The adapter runs the pure pipeline on a serial `pipelineQueue`, preventing GPS,
barometer, and IMU callbacks from racing each other.

The adapter maps `V12Jump` to the app `Jump` model:

- `heightM` -> `Jump.height`
- `airtimeSec` -> `Jump.airtime`
- `distanceM` -> `Jump.jumpDistance`
- `takeoffT` / `landingT` -> wall-clock `startTime` / `endTime`
- `apexT - takeoffT` -> `Jump.apexTime`
- `confidence * 100` -> app confidence score

## 6. Algorithm Workflow

### 6.1 Idle and Planing Gate

V12 starts in idle. A jump candidate can start only when:

- IMU acceleration magnitude crosses `yankG`.
- It is below `crashG`.
- The rider has recent GPS speed above `planingSpeedMs`.
- The engine is outside crash cooldown.
- A recent barometer water anchor exists.

The planing gate prevents stationary hand motion or beach movement from becoming
jump candidates.

### 6.2 Barometer Water Anchor

Before takeoff, V12 finds a water-level anchor from recent barometer samples:

- Uses samples before the yank.
- Excludes samples too close to the yank.
- Requires at least two usable samples.
- Uses a median-like anchor to reduce spike impact.

This anchor becomes the zero-height reference for the jump.

### 6.3 Takeoff Detection

Takeoff is detected from a fresh acceleration yank:

- `aMag >= yankG`
- `aMag < crashG`
- planing is true
- crash cooldown is clear
- barometer anchor exists

When takeoff is accepted, V12 freezes:

- takeoff time
- water anchor
- pre-jump chop level
- arc trackers

The app state changes to airborne.

### 6.4 Airborne Tracking

While airborne, V12 tracks:

- elapsed airtime
- acceleration chop
- impact evidence
- barometer arc points
- maximum barometer-relative altitude
- optional submersion state

It aborts candidates on:

- max airtime exceeded
- crash-level impact mid-arc
- a false-start pattern followed by a better restart candidate

### 6.5 Landing Detection

Landing can be detected by:

- impact above `landImpactG`
- chop returning toward pre-takeoff chop
- optional water submersion signal
- barometer returning near water level

The IMU gives the precise landing time. The barometer helps confirm that the
watch has returned to water level. If barometer samples go silent during the arc,
the engine can still trust IMU landing evidence rather than wait forever.

### 6.6 Height Reconstruction

V12 does not use raw max altitude as the final height. Instead, it fits the
barometer arc around takeoff and landing.

Preferred height path:

1. Collect barometer points inside the flight arc.
2. Fit a takeoff-anchored parabola when enough points exist.
3. Fall back to endpoint-anchored one-parameter fitting when sparse.
4. Fall back to airtime glide model only when no useful barometer arc exists.

The final instant height must pass `minJumpHeightM`.

### 6.7 Distance

Distance is estimated from GPS:

- Prefer straight-line haversine distance between nearest takeoff and landing
  fixes.
- If endpoint positions are missing but speed exists, use speed times airtime.
- If neither is available, distance is nil and the app stores zero.

### 6.8 Confidence

V12 confidence is built from:

- base confidence
- number of barometer arc points
- clean landing/chop behavior
- refinement drift result

The app stores confidence as 0-100.

## 7. Instant Jump and Refinement

V12 emits in two stages:

1. Instant jump at landing:
   - Height
   - Airtime
   - Distance
   - Confidence
   - Arc quality

2. Refined jump after drift check:
   - Uses post-landing barometer samples.
   - Measures return-to-zero drift.
   - Re-fits height with no-drift and linear-drift models.
   - Keeps the model with lower residual error.
   - Flags drift when `abs(rtz)` exceeds threshold.

If refinement remains valid, SessionManager replaces the existing jump in place.
If refinement drops below the minimum height or confidence collapses, SessionManager
retracts the previously emitted jump.

This uses the same update/retract shape already used by V9.

## 8. Logging and Diagnostics

SessionLogger now writes engine metadata in the binary log header:

- `schemaVersion`
- `engineVersion`

V12 also logs:

- readiness status
- takeoff/restart/debug events
- instant jump emission
- refined jump emission
- retractions
- session-end flush

The active engine is logged after fallback decisions, so logs reflect what really
ran during the session.

## 9. Fallback Behavior

If V12 is selected but cannot run, the app:

1. Keeps the V12 settings selection.
2. Falls back to V11 for the current session.
3. Shows a user notice.
4. Logs the fallback reason.
5. Starts the session normally.

Fallback reasons can include:

- no Series 8+ batched motion support
- motion authorization denied/restricted
- altimeter authorization denied/restricted
- relative altitude unavailable

## 10. Test Coverage Added

The SwiftPM core check includes a synthetic V12 pipeline test:

- feeds planing GPS
- feeds pre-yank barometer anchor
- emits an IMU takeoff yank
- feeds barometer arc points
- emits landing evidence
- confirms one instant jump
- feeds post-landing barometer samples
- confirms one refined jump

Command:

```bash
cd SPOTEQ
swift run WatchLiveSessionCoreChecks
```

Current result:

```text
WatchLiveSessionCoreChecks passed
```

JumpReplay now also includes an exact watch-adapter E2E self-test:

- Loader test verifies CSV replay preserves V12 metadata into `IMUSample`.
- V11 test feeds real `IMUSample` + GPS into `JumpDetectorV11`.
- V11 then runs `KitesurfSessionV11`, segment detection, physics analysis,
  ranking, adapter acceptance, and final `endSession()` flush.
- V12 test feeds real `IMUSample` + GPS into `JumpDetectorV12`.
- V12 includes `motionTimestamp`, `relativeAltitude`, `barometerTimestamp`, and
  chronological barometer/IMU/GPS frames like the live watch stream.
- V12 verifies instant jump emission, delayed refinement, same jump id update,
  no retraction, state transitions, height gate, and IMU landing airtime.
- JumpReplay supports `--engine v12` and v10/v11/v12 comparisons on the same log
  path.

Command:

```bash
cd SPOTEQ/Tools/JumpReplay
swift run JumpReplay --engine-e2e-selftest
```

Current result:

```text
replay loader preserves v12 sample metadata
v11 watch-adapter E2E synthetic jump
v12 watch-adapter E2E synthetic jump + refinement
```

## 11. Current Readiness Status

Source-level V12 is wired end to end:

- Settings selection exists.
- Runtime factory creates V12 when readiness passes.
- Sensors carry V12 metadata.
- Pipeline consumes GPS, IMU, barometer, and optional water state.
- Instant/refined jumps reach the live session model.
- Logs record active engine metadata.
- Synthetic pure-pipeline test passes.
- Exact V11/V12 watch-adapter E2E tests pass.

Remaining validation before field release:

- Run a real watchOS Xcode build.
- Test on Series 8+ hardware during an active workout.
- Confirm actual altimeter callback cadence.
- Record a LOG5-style session with Surfr reference.
- Tune thresholds from real 200 Hz device-motion and native relative-altitude data.
- Validate no-jump negative controls, crash sessions, and drift-heavy sessions.
