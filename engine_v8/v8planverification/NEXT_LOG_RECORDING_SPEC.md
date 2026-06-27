# Next-log recording spec — what the watch team MUST capture

**Bottom line, proven from the data:** with what was recorded in
`4173200D` we cannot reach ±20 cm. The ceiling is ~0.65 m, and it is set by the
**barometer**, not by the algorithm. Two hard, measured facts:

1. **The kite rise is NOT in the wrist accelerometer.** For the biggest jump
   (baro height 3.37 m) the physics needs a take-off vertical velocity
   `v0 = √(2gh) = 8.13 m/s`. The IMU's net upward impulse to the apex integrates
   to **0.02 m/s** — essentially zero. The barometer's own rise rate is
   **8.87 m/s** — exactly what the physics demands. A kite lifts the rider in a
   smooth, canopy-borne, elevator-like rise: the wrist feels almost no vertical
   acceleration, only chop (vertical-accel chop RMS ≈ 3.2 m/s², which *swamps*
   any jump signal). → **double-integration of wrist accel can never size a kite
   jump.** Height must come from the barometer.

2. **The barometer was recorded far too slowly.** Measured rate in the log:
   **0.36 Hz** (one update every ~2.8 s), 0.01 hPa (≈8 cm) quantum. A 1–2 s jump
   therefore gets ~1 sample near the apex, so the sampled peak misses the true
   apex and under-reads height by ~0.5–1 m (baro-only top-4 came out
   2.53/2.53/2.53 vs Surfr 3.45/3.17/3.14). Even Apple's *default* `CMAltimeter`
   is **1 Hz** — so the team isn't even getting the full default rate.

## What to record in the next session

Record a **raw buffer** (we analyse offline; no real-time needed). Per stream:

| stream | API | rate | why |
|---|---|---|---|
| **Barometric pressure** (relative + **absolute**) | `CMAltimeter.startRelativeAltitudeUpdates` (+ `startAbsoluteAltitudeUpdates`) | **as fast as the OS gives — ≥1 Hz** (we currently get 0.36 Hz) | THE height source for kite jumps; need ≥4–5 samples per jump to catch the apex |
| **High-rate accelerometer** | `CMBatchedSensorManager.startAccelerometerUpdates` | **800 Hz** (S8/S9/Ultra) | resolves the water-release & water-contact micro-impacts → exact **airtime**, and the **take-off pop** timing to bracket the baro apex |
| **High-rate device motion** (gyro + gravity/attitude) | `CMBatchedSensorManager.startDeviceMotionUpdates` | **200 Hz** | clean attitude for world-vertical projection; pop/rotation detection |
| **Water submersion state** (Ultra only) | `CMWaterSubmersionManager` (`didUpdate` events) | event-driven | a **direct out-of-water signal** = ground-truth airtime bracket; the cleanest jump gate possible |
| GPS speed + **location** | `CLLocationManager` | 1 Hz | distance (the log had speed but NO lat/lng — add location for true displacement) |

Notes for the team:
- Keep an **active `HKWorkoutSession`** — `CMBatchedSensorManager` requires it.
- Record **absolute altitude** too: it is sea-level referenced and bounds the
  slow baseline drift the relative channel suffers.
- Store raw timestamps per stream (they run at different rates) — do **not**
  resample on-watch; the offline analyser aligns them.
- Add **lat/lng** (the current log only had `spd`), so distance is real GPS
  displacement, not speed×airtime.

## What this unlocks

- **Height ≤20 cm:** a ≥1 Hz baro resolves the apex directly; fused with the
  800 Hz accel (which pins take-off/landing timing) the apex is sampled tightly.
- **Exact airtime:** 800 Hz water-release→water-contact, or the Ultra submersion
  state, gives airtime to a few ms instead of ±0.3 s.
- **Distance:** real GPS displacement with lat/lng.

Until that log exists, the production algorithm is **baro-centric** (see
`jumpEngineV8.ts`): height = barometric apex with parabolic apex interpolation;
the IMU is used only to DETECT the jump (pop) and to bracket the window, never to
size it. Expected accuracy on the current 0.36 Hz data: ~0.5–0.7 m. With a 1 Hz
baro it should reach ~0.2–0.3 m; with the full stack, ≤0.2 m.

## Barometer reliability under real conditions (and why the IMU cross-check matters)

The barometer is the height source, so its real-world behaviour matters:
- **Weather** drifts pressure over minutes–hours (1 hPa ≈ 8 m). The rolling-median
  baseline (±15 s) removes it entirely — a jump is a 1–2 s event. No issue.
- **Waves / sea surface** add ~0.5–1 m of apparent altitude (crest vs trough) =
  0.06–0.12 hPa. The median baseline absorbs it; a jump (0.4 hPa) is larger. A
  small noise floor remains.
- **⚠️ Wet watch / wetsuit sleeve over the baro port** is the real risk: a sleeve
  low-passes the port and ATTENUATES the fast jump pressure change; water in the
  port distorts it. Sensitivity drops.

This is exactly why V8 now **cross-validates with the IMU** (§3.3.2 in the plan):
the "calm window" (the wrist goes quiet while airborne — no water chop) and the
"bar-pull" (sustained pull before take-off) DETECT the jump and MEASURE airtime
**without the baro**. So a degraded baro loses only HEIGHT PRECISION, not
detection or airtime. The two paths confirm each other and reject noise (a baro
dip with no airborne IMU signature is rejected; an airborne signature with no
baro still flags a jump, height-uncertain).

> On Samsung/Garmin, `TYPE_PRESSURE` can be sampled at 10–25 Hz — sample it fast.
> That, plus the IMU cross-check, gives accurate height even with a damp port.
