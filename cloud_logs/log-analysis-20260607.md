# Session Log Analysis — `log_20260607_133632_FFFB9869`

Analysis of the real watch session log (`last.kitelog.json`, build 36, app 1.0) used to
diagnose why the **v7 jump engine over-counts** and to drive a more specific refactor.

## Session at a glance

| Property | Value |
|---|---|
| Duration | **63.6 min** (3814 s) |
| Samples | 191,671 @ 50 Hz |
| Mode | Standard, **devMode: true** |
| Params | minSpeed 4.17 m/s · takeoffG 1.50 · landingG 2.00 · minAir 0.50s · maxAir 8.0s · cooldown 1.5s |
| State time | RIDING 81.4% · AIRBORNE 18.0% |
| AIRBORNE→RIDING transitions | 392 |
| **JUMPS ACCEPTED** | **252** (≈ 4.0 / min) |

> 252 accepted jumps in one hour is the core defect. A real kite session of this length
> would realistically produce ~10–40 jumps. **18% of the whole session was spent "AIRBORNE"** —
> physically impossible for a kiter. The engine is treating ordinary riding chop, hand motion,
> and barometer sensor artifacts as jumps.

## What the engine reported (the 252 "jumps")

| Metric | min | median | max | mean |
|---|---|---|---|---|
| Height (m) | 0.50 | 1.58 | **25.00** | 2.77 |
| Airtime (s) | 0.50 | 0.70 | 7.12 | 0.86 |
| Confidence | 48.6 | 77.4 | 100 | 74.6 |

Height buckets: `0–1m: 84 · 1–2m: 61 · 2–3m: 40 · 3–5m: 40 · 5–10m: 18 · 10m+: 9`
Airtime buckets: `~0.5s (min gate): 47 · 0.5–1s: 143 · 1–1.6s: 44 · ≥1.6s (timeout): 18`
Height source: `kinematic 119 · barometric 99 · blended 34`
Landing kind: `settle 161 · hardImpact 79 · timeout 12`

## Root causes (mapped to code)

### 1. Takeoff gate is far too permissive — fires on chop/hand motion
`isReleaseSpike` ([KitesurfJumpEngine.swift:757-766](../Kiters/Kiters%20Watch%20App/Services/KitesurfJumpEngine.swift#L757-L766))
accepts a takeoff on `|a| ≥ μ+Kσ` (or floor 1.30g) plus only **`gyroMag ≥ 1.5 rad/s`**.
On a wrist in choppy water that bar is trivially crossed.
- **9%** of accepted jumps had **no real takeoff spike** (peak `|a| < 1.5g` in the 1.5s before).
- There is **no GPS-speed arming gate**: `minSpeed (4.17 m/s)` is logged but never enforced in the FSM.
- **43% of accepted jumps occurred while max GPS speed in the prior 1.5s was below minSpeed** — i.e. the user was **not riding** when nearly half the "jumps" fired.

### 2. Barometric height is decoupled from physics (the "25 m" jumps)
`baroH = dP * 8.43` ([KitesurfJumpEngine.swift:364-374](../Kiters/Kiters%20Watch%20App/Services/KitesurfJumpEngine.swift#L364-L374))
trusts a raw pressure delta and fuses it with no cross-check against airtime.
The watch barometer is **quantized and zero-order-held**: it reads a flat value, then *snaps*.

Concrete false positive at **t≈1322s** (reported `h=25.0m, air=0.58s`):
```
baro flat at 1019.11 hPa for ~1s ... then SNAPS to 1023.99 (a 4.88 hPa quantum step)
|a| never exceeds ~1.2g the entire "airborne" window; GPS speed ≈ 1.5 m/s (not riding)
```
A 4.88 hPa step → ~41 m → clamped to 25 m. This is a **sensor ZOH artifact, not a jump**.
- **9 jumps ≥ 10 m** (incl. several at the 25 m clamp) — all `src=barometric`, all physically impossible.
- **81 / 99** barometric jumps have reported height **> 3×** the airtime-implied parabolic height
  (`h = g·t²/8`). A 0.5s airtime can only reach ~0.3 m, yet these report several metres.
- Session-wide baro span is **34 hPa** (≈285 m of weather/altitude drift) — the height pipeline
  has no protection against a baseline that wanders by orders of magnitude more than any jump.

### 3. No physics-consistency gate between height and airtime
Nothing validates that barometric height is compatible with the measured airtime. Real free-flight
obeys `h ≈ g·t²/8`; the engine should reject (or down-rank) any jump whose baro height implies an
airtime wildly inconsistent with the one actually measured.

### 4. Confidence floor too low; false positives still score high
Accept threshold is `confidence ≥ 0.40` ([KitesurfJumpEngine.swift:847](../Kiters/Kiters%20Watch%20App/Services/KitesurfJumpEngine.swift#L847)).
Median confidence of the (mostly bogus) 252 jumps is **77.4**, so the gate filters almost nothing.
The scorer ([:396-404](../Kiters/Kiters%20Watch%20App/Services/KitesurfJumpEngine.swift#L396-L404))
gives +0.10 for `maxSessionSpeed ≥ 2.0` (a *session* max, not the speed *at this jump*), so a single
fast moment early in the session inflates confidence for every later false positive.

### 5. Landing "settle" + short min-airtime → rapid re-triggering
`settle` accounts for 161/252 landings; min airtime is only 0.5s. Combined with a 1.5s cooldown,
the FSM cycles RIDING→AIRBORNE→RIDING very fast. **45 inter-jump gaps < 3s; 22 < 2s** — clusters
of detections from a single motion burst / landing bounce.

## What a *real* jump looks like in this log (for calibration)

High-confidence real jump at **t≈2927s** (`h=2.59m, air=1.48s, conf=100`):
- Sustained elevated `|a|` through the air phase with a clear landing spike (`|a|→2.19g`).
- Gyro genuinely active (multiple samples 4–8 rad/s).
- **GPS speed ≈ 6–7 m/s throughout** (actively riding).
- Baro changes *gradually* (1013.15 → 1012.83), consistent with a real ~2–3 m arc.

The discriminators that separate this from the false positives: **riding speed at takeoff**,
a **real sustained takeoff spike**, and **baro motion that is gradual and airtime-consistent**.

## Recommended fixes (summary — see plan for detail)
1. **GPS-speed arming gate**: require `maxSpeed-in-recent-window ≥ minSpeed` before a takeoff can arm.
2. **Reject ZOH baro steps**: detect a single-sample pressure step (quantum jump) and exclude it
   from `jumpMinPressure`; require the drop to develop over multiple samples.
3. **Physics-consistency gate**: reject/down-rank when baro height is incompatible with `g·t²/8`
   from the measured airtime (and tighten the 25 m clamp to a realistic ceiling).
4. **Stronger takeoff confirmation**: raise the gyro requirement and require ≥2 sustained spike
   samples (kill single-impulse triggers).
5. **Use speed-at-jump, not session-max, in confidence; raise the accept floor.**
6. **Longer refractory / higher min-airtime** to stop rapid re-triggering from one burst.
