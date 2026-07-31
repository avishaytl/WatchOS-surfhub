# Apple Watch S9 / Ultra(2) — sensor capabilities for jump detection

Research for improving the V7 jump-height algorithm. The core finding from the
real Surfr kite log (`4173200D`): **the current 50 Hz CoreMotion stream + 0.4–1 Hz
barometer cannot recover a kitesurf airtime accurately**, because on the wrist the
glide accel ≈ riding accel and the baro is far too slow/coarse to see a 3–4 m, 3–4 s
arc. The fix is higher-rate sensing the watch *can* provide but we are not yet using.

## What we sample today

| signal | source | rate | problem |
|---|---|---|---|
| userAcceleration (g) | `CMMotionManager.deviceMotion` | **50 Hz** | OK for the pop, too coarse for the exact water-release/contact instant |
| rotationRate (rad/s) | `CMMotionManager.deviceMotion` | 50 Hz | fine |
| gravity vector | deviceMotion | 50 Hz | fine |
| pressure (hPa) | `CMAltimeter.relativeAltitude` | **~1 Hz (log showed 0.4 Hz)** | **blind** — only 1–2 baro samples per jump, 0.01 hPa (~8 cm) quantum |
| GPS speed | location | ~1 Hz | speed does NOT drop in a kite jump → useless as a jump gate |

## What the watch CAN provide (not yet used)

### 1. `CMBatchedSensorManager` — **800 Hz accel, 200 Hz gyro** ⭐ highest impact
- **Models:** Apple Watch Series 8 **and Ultra** (and later: S9/Ultra 2). Requires an
  active `HKWorkoutSession`, watchOS 10+.
- Delivers **batches once per second** (so it is for recording/analysis, not a 60 Hz UI),
  which is exactly our model: record raw → analyse offline.
- **Why it fixes airtime:** at 800 Hz the **water-release** (board leaves the water)
  and **water-contact** (landing) micro-impacts are sharp, resolvable transients
  (1.25 ms resolution vs 20 ms today). The kite "soft landing" that has no clear
  spike at 50 Hz becomes a detectable water-slap signature at 800 Hz. Airtime =
  release-transient → contact-transient, which is what Surfr effectively measures.
- 200 Hz gyro cleanly separates the take-off rotation from glide.
- **API:** `CMBatchedSensorManager.startDeviceMotionUpdates()` /
  `startAccelerometerUpdates()`; check `isDeviceMotionSupported` /
  `isAccelerometerSupported` / `authorizationStatus`.

### 2. `CMWaterSubmersionManager` — submersion **state** + depth/pressure (Ultra only)
- **Models:** Apple Watch **Ultra / Ultra 2** only, watchOS 9+.
- Gives an explicit **"submerged ↔ surfaced" event** (`CMWaterSubmersionEvent`) plus
  depth and water pressure. Depth/pressure update only every **~2–3 s** (too slow to
  time a jump), BUT the **submersion-state transition** is a *direct* "in water / out of
  water" signal — a ground-truth airtime bracket no IMU heuristic can match.
- **Best use:** not for the height number, but to **gate** real jumps (rider/board out
  of water) and to *validate / auto-calibrate* the IMU airtime against true
  out-of-water intervals. Pressure channel here is also a higher-quality baro than
  `CMAltimeter` during water sports.
- Needs the "Shallow Depth and Pressure" entitlement.

### 3. `CMAltimeter.startAbsoluteAltitudeUpdates` — absolute altitude (~1 Hz)
- Still 1 Hz, so it does **not** time a jump, but `CMAbsoluteAltitude` is sea-level
  referenced and can sanity-bound the slow baseline drift the relative baro suffers.
- Low priority vs the two above.

## Recommendation (ranked)

1. **Adopt `CMBatchedSensorManager` 800 Hz accel + 200 Hz gyro** for the recording
   path. This is the single change that makes a real airtime recoverable on the wrist
   → directly enables the ≤20 cm height target (height = ½·g·(f·airtime)², and the
   error today is dominated by airtime error, not f).
2. **On Ultra, fuse `CMWaterSubmersionManager` submersion-state** as the jump gate and
   the airtime ground truth (out-of-water bracket). This is the closest thing to what
   Surfr/Hoolan use and removes the "is this a jump or chop?" ambiguity that makes us
   over-detect (~20 vs Surfr's 4).
3. Keep the 50 Hz `CMMotionManager` path as the fallback for Series < 8 / non-Ultra.

## Implication for the algorithm

- The `.kslog` format should gain an **800 Hz accel block** (batched) alongside the
  50 Hz device-motion stream, and an optional **submersion-event channel**.
- `jumpEngineV7` airtime detection should, when the high-rate data is present, find
  the **water-release** and **water-contact** transients (sharp high-frequency energy
  bursts) instead of the coarse 50 Hz spike heuristic — then the kite ascent fraction
  (`symmetricAscentFraction ≈ 0.19`) maps airtime→height within target.

---

*Sources:*
- [What's new in Core Motion — WWDC23](https://developer.apple.com/videos/play/wwdc2023/10179/) (CMBatchedSensorManager 800 Hz accel / 200 Hz gyro; Series 8 + Ultra)
- [CMWaterSubmersionManager — Apple Developer](https://developer.apple.com/documentation/coremotion/cmwatersubmersionmanager) (Ultra, submersion state + depth/pressure)
- [Accessing submersion data — Apple Developer](https://developer.apple.com/documentation/coremotion/accessing-submersion-data)
- [startRelativeAltitudeUpdates — Apple Developer](https://developer.apple.com/documentation/coremotion/cmaltimeter/1616004-startrelativealtitudeupdates) (altimeter locked ~1 Hz)
