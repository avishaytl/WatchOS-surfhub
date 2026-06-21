# SurfHub Jump Detection — V7 Algorithm & Calibration

How the watch turns raw wrist IMU + barometer into a jump's **height**, **airtime**,
and **distance**, and how those numbers were calibrated against a professional
reference app (Surfr). This is the single source of truth for the V7 engine that
runs both on the watch and in the admin WATCH CALIB dashboard.

- Engine (TS, runs on the dashboard): [`core/jumpEngineV7.ts`](core/jumpEngineV7.ts)
- Engine (Swift, runs on the watch): [`core/KitesurfJumpEngine.swift`](core/KitesurfJumpEngine.swift)
- Session metrics wrapper: [`core/sessionAnalysis.ts`](core/sessionAnalysis.ts)
- Dashboard: `surfhub-admin/src/app/(admin)/calib/CalibWorkbench.tsx` (imports this
  core via a `file:` symlink, so edits here are live on the dashboard with no build)

The Swift (`KitesurfJumpEngine.swift`) and TS (`jumpEngineV7.ts`) engines are kept
**line-for-line equivalent** — identical formulas, parameters, gates, and the
Big-Air baro extension. The TS is the calibration mirror the dashboard runs on
uploaded logs; the Swift is what ships to the watch. Any tuning change must be made
in both.

---

## 1. The sensor reality (why a naïve approach fails)

The watch is on the **wrist**, sampling at ~50 Hz. Two hard facts drive everything:

1. **The barometer cannot see small jumps.** Its quantum is ≈0.01 hPa (~8 cm),
   held (ZOH) for ~0.3–0.5 s, and `baseBaro` (the watch's rolling baseline) tracks
   the rider — so for a 3–4 m jump `baseBaro − baro ≈ 0`. In real logs (`log1`,
   `log2`, build-46) **no dip exceeded 0.15 hPa**. Height for normal jumps therefore
   **must** come from time-of-flight, not pressure.

2. **`userAcceleration` has gravity removed**, so a still or free-falling watch both
   read |a| ≈ 0 g. "Airborne" can't be a low-g threshold. Detection is
   **transition-based**: an adaptive release spike (+gyro) → ballistic flight →
   landing (water-contact spike + gyro burst).

3. **The wrist is not the centre of mass.** Vertical-velocity integration of the
   wrist accel was tested and **fails** — at take-off the wrist's vertical accel
   even reads negative (the arm flails/rotates independently of the body). So a
   v0²/2g integration height is not reliable. **Airtime is the only reliable
   kinematic signal on the wrist.**

---

## 2. The height model (kite-aware, reference-validated)

A kite **holds the rider up**, so the descent is far longer than the ascent. The
total airtime hugely over-estimates height via the symmetric `g·t²/8`
(a 4.6 s airtime would imply ~25 m). The real height comes from the **rise time**
(take-off → apex):

```
h = ½ · g · t_rise²        where  t_rise = symmetricAscentFraction · airtime
```

### Calibrating `symmetricAscentFraction`

Solved against the **Surfr reference session** (`log2`, beach jump dropped):

| Surfr height | Surfr airtime | implied ascent fraction (on physical airtime) |
|---|---|---|
| 3.77 m | 4.33 s | 0.146 |
| 3.45 m | 4.12 s | 0.141 |
| 3.17 m | 4.59 s | 0.139 |

Plus pro **Big Air** data points (same model, full range):

| height | airtime | ascent fraction |
|---|---|---|
| 30 m | 16.5 s | 0.150 |
| 20 m | 10 s   | 0.147 |
| 23 m | 9 s    | 0.176 |
| 15 m | 8 s    | 0.160 |

Across **all** points the fraction is **0.144 ± 0.019** — the same rise-time model
holds from 3 m to 30 m. Value chosen: **`symmetricAscentFraction = 0.143`**
(minimax over the three clean low-range jumps). This reproduces the reference
heights within **0.16 m** (mean 0.14 m), under the dashboard's 0.20 m target.

> Note the watches were **unsynced** (Surfr ran on a *separate* watch), so per-jump
> timing and count need not align between the recorded log and the reference —
> calibration is by **height** (Surfr = ground truth), matched by rank.

---

## 3. Airtime (displayed vs physical)

The engine measures **physical airtime** = take-off spike → water-contact spike
(the full flight including the kite glide), ~5.8–6 s for the reference jumps. Surfr
**displays a shorter airtime** (~4.1–4.6 s) — it trims the glide tail.

The internal `airTimeSec` stays **physical** (it drives the height model). Only the
*displayed* airtime is scaled, in `toJumpEvent`:

```
displayed_airtime = physical_airtime · displayedAirtimeScale   (0.73)
```

After scaling, displayed airtime matches Surfr within ~0.3 s (4.20–4.40 s vs
4.12–4.59 s). The remaining gap is unsynced-watch noise (Surfr's airtime isn't even
monotonic in height).

---

## 4. Dual-path height: LOW kinematic, HIGH barometric

`height ∝ airtime²`, so any landing-detection error on a **long** window explodes
the height (a 16 s window → 27 m). On the wrist, a clean single-jump airtime tops
out ~6.5 s; beyond that is almost always two chained jumps or a glide. So:

- **Low range (≤ ~6 m)** — **kinematic**. `maxAirTimeSec = 6.5` caps the window;
  the rise-time model gives the height. The baro is blind here.
- **High range (6 – 45 m+)** — **barometric**. A 15–30 m jump moves the baro by
  **1.8–3.6 hPa** — a huge, unambiguous dip (`h = ΔP · 8.43`). This is how a real
  Big Air is measured; it does **not** depend on a long, reliable airtime.

### Big-Air baro extension

A 30 m jump has ~16 s of hangtime — the kinematic watchdog times out mid-flight
before the pressure apex. On a **timeout with a developing dip**, the engine scans
**baro-only up to 30 s** for the true pressure minimum and its recovery, *without*
extending the kinematic `airTimeSec`. The symmetric ceiling that gates the baro
then uses the **baro flight time** (t0 → baro-landing), so a genuine Big Air is not
clipped. Verified on synthetic 15/20/30 m jumps → detected 14.98 / 19.98 / 28.52 m.

---

## 5. Drift rejection (the "13 m" bug)

Build-27's dashboard showed a phantom **13.38 m** jump: a slow barometric **drift**
(dP ≈ 1.6 hPa) was read as height. A drift **ramps monotonically and never returns**;
a real jump's pressure traces a **valley** (dips to the apex, then climbs back on
landing). The baro is trusted only when **both** hold:

1. **Airtime supports it** — `baroH ≤ (g · t_flight² / 8) · airtimeCeilingTolerance`
   (using the baro flight time). Big Air passes; a big dP on a short airtime fails.
2. **The valley turns** — the pressure minimum is not at the window's end and the
   pressure climbs back ≥50 % of the dip (or ≥15 % if the minimum is clearly past,
   for a watchdog-cut Big Air). A monotone drift fails this.

`maxPlausibleHeightM = 50` is a loose final guard (Big Air records exceed 45 m) —
**not** the drift filter; the valley test is.

---

## 6. Detection state machine (`detectJumpsV7`)

```
RIDING ──(release spike + weak gyro)──▶ AIRBORNE ──(first water contact)──▶ RIDING
```

- **Take-off**: `aM ≥ releaseFloorG (1.7)` with a fixed-floor-dominated threshold
  (the adaptive median+Kσ balloons during chop and *hides* real take-offs), gated by
  a **weak** gyro floor (≥0.3 rad/s — the wrist pop's gyro is small, ~0.35 rad/s).
- **Landing = FIRST water contact**: a board slap (`aM ≥ landingContactG 1.15`) with
  a **wrist-rotation burst** (`gyro ≥ landingContactGyro 2.0`), or a hard impact
  (`aM ≥ landingSpikeG 1.4` + gyro ≥ 1.0). Stopping at the *first* contact keeps two
  consecutive jumps from merging. The old "settle" landing is removed — the kite
  settles the wrist mid-flight and would cut the airtime (and height) short.
- **Refractory** 1 s after a landing.

---

## 7. Default parameters (`DEFAULT_V7_PARAMS`)

| param | value | role |
|---|---|---|
| `symmetricAscentFraction` | **0.143** | rise-time fraction of airtime (kite-aware height) |
| `displayedAirtimeScale` | **0.73** | trims displayed airtime to match Surfr |
| `releaseFloorG` | 1.70 g | fixed take-off spike floor |
| `releaseSigmaK` | 1.5 | small adaptive term (floor dominates) |
| `landingContactG` / `landingContactGyro` | 1.15 g / 2.0 rad/s | first water-contact landing |
| `landingSpikeG` | 1.40 g | hard-impact landing |
| `minAirTimeSec` / `maxAirTimeSec` | 2.0 / 6.5 s | reject pops / kinematic watchdog |
| `minJumpHeightM` | 1.5 m | display gate (matches Surfr ≥1.5 m) |
| `baroNoiseFloorHPa` | 0.03 | below this baro is pure noise |
| `baroTrustLoHPa` / `baroTrustHiHPa` | 0.06 / 0.18 | baro SNR trust ramp |
| `airtimeCeilingTolerance` | 1.25 | baro may exceed the ceiling by ≤25 % |
| `maxPlausibleHeightM` | 50.0 | loose final sanity cap (Big Air > 45 m) |
| `kinematicCalibration` | 1.0 | rise-time scale (absorbed by ASC) |

---

## 8. Verification

| Log / case | Result |
|---|---|
| `log2` (Surfr reference) | 4 top jumps 3.63/3.56/3.33/3.26 m vs ref 3.77/3.45/3.17/3.14 — mean |Δh| 0.14 m; max 3.63 m; displayed airtime 4.2–4.4 s vs ref 4.1–4.6 s |
| `log1` | max 3.9 m, all kinematic, all heights ≤ 4 m |
| Synthetic 15 / 20 / 30 m | detected 14.98 / 19.98 / 28.52 m (barometric) |
| 13 m baro drift | rejected (valley test) |

### Open items

1. The **high-range baro path is verified on synthetic data only**. The recovery
   thresholds (0.5 / 0.15 · dP) and `airtimeCeilingTolerance` should be re-tuned
   when a **real watch log containing a high (>10 m) jump with a known reference
   height** is available — same procedure as the low-range calibration.

2. **Live-watch Big-Air buffer.** The offline detector (`process`, run by the
   dashboard on a full log) can scan 30 s for the baro apex. The live streaming
   FSM (`KitesurfSession`) currently caps the airborne capture at the kinematic
   watchdog, so a very long (>6.5 s) Big-Air hangtime is buffer-limited on the
   watch itself. For full on-watch Big-Air baro capture, the airborne phase must
   keep recording until the pressure recovers (decoupled from the kinematic
   watchdog). The dashboard analysis is unaffected.

---

## 9. Pipeline limits (answer to "what's the max detectable")

| kinematic `maxAirTimeSec` | max kinematic height | displayed airtime |
|---|---|---|
| 6.5 s (current) | 4.2 m | 4.7 s |

Above ~6 m the **barometer** takes over (no airtime cap), so the practical ceiling
is the baro horizon (30 s scan) and `maxPlausibleHeightM = 50 m` — comfortably
covering Big Air records.

---

*Temporary calibration logs live in the `calib-logs` Supabase bucket (dev-only,
gated by `CALIB_TOKEN` — remove before production). The dashboard loads them via the
`calib-log` Edge Function.*
