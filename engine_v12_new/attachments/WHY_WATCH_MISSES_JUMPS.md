# Why the watch misses jumps (but the dashboard sees them)

**Field logs 2026-07-05** (`log5_195245`, `logv11_204000`, `log_221837`).

## The short answer

The jump-detection ENGINE is correct — it detects every throw when the sensor
streams are time-aligned. The watch misses them because of **acquisition/recording
bugs in the app layer**, not the engine.

## Root cause — two clocks

The app feeds MOTION and BARO/ABSALT on **different clocks**:

| stream | first timestamp (real log) |
|--------|----------------------------|
| motion | ~1 s |
| baro / absAlt | ~804,928,694 s |

They share a huge origin offset **and** a per-session **random skew (−1.5 to
−1.8 s)**. In real time the altitude arc reaches the pipeline at a time that does
**not** line up with the IMU take-off yank → the engine cannot fuse "when you
jumped" (IMU) with "how high" (baro) → **0 jumps**.

`CMDeviceMotion.timestamp` and `CMAltitudeData.timestamp` are BOTH seconds-since-
boot — the **same clock**. The bug is app code that re-zeroes one stream and not
the other.

## Why the dashboard DOES see them

The dashboard is **not** the watch's real-time path. It post-corrects the clock
offset + skew **offline** (`log5FromStreams` alignment) and feeds absolute
altitude, so the arcs re-align and all throws detect. The watch runs live with the
raw broken timestamps and cannot do that.

## Two aggravating bugs (same logs)

- **`baroSource = relativeAltitude` (0.39 Hz, smoothed/laggy)** instead of
  `absoluteAltitude` (3 Hz, fast). The dashboard always feeds absolute.
- **Low Power Mode ON the whole session** — throttles the barometer.

## The fix (watch app, not the engine)

1. **One clock** — feed the pipeline each stream's RAW `data.timestamp`
   unchanged; never re-zero one stream and not another. Add a SYNC record at
   session start.
2. **`baroSource = .absoluteAltitude`** (the fast channel).
3. **Exit Low Power** + keep an active `HKWorkoutSession`.

Details + Swift: `V12_WATCH_APP_REVIEW_AND_SPEC.md §3–4`. Engine reference (already
correct): `core/JumpEngineV12.swift`.
