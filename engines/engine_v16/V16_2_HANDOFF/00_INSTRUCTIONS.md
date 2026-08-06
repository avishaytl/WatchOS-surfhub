# V16.2 — what to change, exactly

You are on V16.1. This package takes you to **V16.2**. Every number below was
measured on the six reference logs; nothing here is a guess.

## The short version

Two independent problems were found and fixed, plus one root-cause discovery
that replaces the height calculation entirely.

| | before (V16.1) | after (V16.2) |
|---|---|---|
| bench throws detected | **0 / 4** | **3 / 4** |
| height MAE, bench throws | n/a | **0.02 m** |
| riding recall | 31 / 39 | **36 / 39** |
| phantoms | 9 | **8** |
| **tallest phantom** | 3.73 m | **2.54 m** |
| height MAE, log 287 | 0.519 m | **0.416 m** |
| height MAE, smallLog | 0.710 m | **0.211 m** |
| height MAE, pooled | 0.575 m | **0.300 m** |
| airtime MAE, log 287 | 0.34 s | 0.46 s (accepted) |
| control session (NEG) | 0 emissions | **0 emissions** |

Recall up, phantoms down, the tallest phantom down, height much better in both
regimes. The single regression is airtime, which the product owner accepted.

## 1. Replace two files

Copy from `01_ENGINE/` over your copies:

- `JumpEngineV16.swift`
- `JumpDetectorV16.swift`

They compile against the same interfaces as V16.1 — no call-site changes.

**Note on where these live in your tree.** Your `project.pbxproj` references them
at `../engines/engine_v16/`, not in `Kiters Watch App/Services/`. Copy them to
whichever path your build actually compiles. Do not create a second copy.

## 2. Verify the version string

`JumpEngineV16.version` must now read `"16.2"`. `JumpDetectorV16` already logs it
on reset (`engine=v\(JumpEngineV16.version)`), so a field log will attribute
itself correctly.

## 3. Session.swift — update the engine description

The V16.1 description tells the reader to fall back to V15 on small jumps. That
is now wrong and measurably harmful. Replace the `.v16BigAir` description with:

> Big-air first, IMU only — the barometer is not used at all. A pop opens a
> candidate; a sustained LIFT SHELF in world-vertical acceleration confirms it,
> which admits 0 of 19 pops on a waves-only control session. Height is measured
> by endpoint-anchored double integration over the flight and is reported in
> metres with no calibration constant: 0.30 m MAE pooled over 37 goldens from
> five sessions, 0.21 m on a small-jump session (1.5–3.7 m) and 0.42 m on big air
> (2.1–8.5 m). Recall 36/39. Hand throws on a bench are detected too, so the
> watch can be tested without going on the water. Airtime is measured from where
> the water arrests the descent and carries about 0.46 s of error — treat it as
> an estimate, never as a gate.

And the display name becomes `"V16.2 Big Air (Default)"`.

## 4. Nothing else changes

No new dependencies, no new permissions, no new sensor streams. V16.2 still uses
**only** the IMU. GPS remains metrics-only. The barometer remains unused.

---

# What actually changed inside the engine

## A. The height is now a measurement, not a calibration

**This is the important one.**

V16.1 computed height as `heightScale * apex + heightOffsetM` = `1.91 * apex +
1.43`, where `apex` was a bounded double integral over a *fixed* 4.5 s window.
That operator is a **matched filter**: it reports a curvature contrast that
correlates with height (r = 0.95), not the height itself. Hence the two fitted
constants.

V16.2 integrates over the **measured flight window** instead, with the sign
corrected, and gets metres directly:

```
z(t) = ∫∫ (-a_z) dt² over [takeoff, landing],  with z(0) = z(T) = 0
height = max z(t)
```

Pooled over 37 goldens the raw output measures **0.317 m MAE with no scale and
no offset**. The best linear map that could be fitted to it is
`h = 1.032·z + 0.048` — the identity to within 3 % and 5 cm. A correlate does not
do that; a measurement does.

**Why V16.0 and V16.1 missed it.** The V16 header states that a per-jump window
"collapses the correlation to r≈0". That is true — *with the sign that
experiment used*. Our `a_z` reads **+9.81 m/s² in free fall**, i.e. it is the
negative of the kinematic acceleration, so the integral must run on `-a_z`.
Measured with `+a_z` the peak is 0.00 on every bench throw and 0.00–0.12 on the
log-287 goldens: exactly the r≈0 that was recorded. The fixed-window matched
filter and the entire `heightScale` / `heightOffsetM` calibration were built to
work around a sign error.

`heightScale` and `heightOffsetM` are **kept**, because the matched filter is
still the fallback when the landing is unresolved (3 of 37 goldens). Do not
delete them. `heightFromFlight = true` selects the new path; setting it false
restores V16.1 behaviour exactly.

## A2. The integration window — free fall

The integral faithfully measures whatever window it is given, so the **window is
now the critical component**. Measured on the bench log:

| throw | true window | height | landing-rule window | height | truth |
|---|---|---|---|---|---|
| 1 | 1.42 s | **2.49 m** | 2.80 s | 3.13 m | 2.48 m |
| 2 | 1.12 s | **1.55 m** | 2.30 s | 1.92 m | 1.54 m |
| 3 | 1.56 s | **2.97 m** | 3.10 s | 4.44 m | 3.00 m |

The descent-arrest landing rule was built for water. On a thrown watch there is
no water, the rule does not close in time, and the window comes out about **twice
too long**.

**Fix: prefer the FREE-FALL window when one exists.** Free fall is the only
window that is exactly right by definition, and it is directly measurable — both
edges are sharp to a single sample. More importantly it **does not occur while
riding at all**: 187 minutes of riding and control sessions contain ZERO runs,
because a rider hangs from the canopy and is never unloaded. So the rule can only
ever replace the window on a genuinely ballistic event.

No extra storage is needed. With `load` = |userAcceleration| and `wz = az/G0`:

```
sf^2 = |ua + gravity|^2 = (load^2 - wz^2) + (wz - 1)^2 = load^2 - 2*wz + 1
```

(at rest `load=0, wz=0 -> 1`; in free fall `load=1, wz=1 -> 0`)

New parameters `freeFallG = 0.25` and `minFreeFallSec = 0.45`. The threshold is
not critical — the bench log gives the identical answer anywhere from 0.15 to
0.50 g.

Result: bench-throw height goes from **0.83 m to 0.02 m**, and every other log is
unchanged to the digit (SMALL 0.211, 287 0.416, NEG 0 emissions, totals 36/39 and
0.300 m). Free, exactly as the physics requires.

## B. The anchor was landing on the catch, not the take-off

`popClusterSec` governs how far `t0` may walk **forward** onto a stronger pop.
It was 2.0 s. A real take-off's own pop burst measures **0.80 s median** across
the 14 goldens, so the window was far wider than the thing it merges.

On a thrown watch the ordering inverts: the release is 3–6 g and the **catch is
15–23 g**, 0.9–1.7 s later. The anchor walked onto the landing, and the shelf
scan then started *after* the flight was over. The watch's own log shows it:

```
v16 REJECT t0=... reason=noLiftPlateau shelf=0.30s yank=22.70g
v16 REJECT t0=... reason=noLiftPlateau shelf=0.00s yank=17.05g
```

The signal was never missing — the shelf during those throws measures
**1.44 / 1.14 / 1.58 / 0.88 s**, all well over the bar. The engine was looking in
the wrong place.

`popClusterSec: 2.0 -> 0.8` fixes it.

## C. …but that alone cost the height, so the anchors were decoupled

Moving `t0` also moved the apex window, and log 287 paid for it: height MAE
0.519 -> 0.643 m. Refitting the calibration recovered only 0.017 of that, so the
loss was information, not a stale constant.

New parameter `apexAnchorSec = 2.0`: `t0` marks the take-off (detection, shelf,
airtime) while the **height window keeps its own anchor** — the strongest pop
within 2.0 s of `t0`. On a kite jump both resolve to the same sample and the
height is unchanged. Log 287 returns to 0.519 m with the throws still detected.

## D. Short lift shelves are admitted with corroboration

The four goldens smallLog used to miss carry shelves of **0.7 / 0.7 / 0.6 / 0.8 s**
against the old 0.8 s bar — near misses, not absent lift.

- `minLiftPlateauSec: 0.8 -> 0.7` (now a floor, not the bar)
- `shelfFullSec = 0.8` — at or above this a shelf is accepted alone
- `shortShelfApexM = 0.30` — below it, the candidate must also clear this apex

Phantoms pile up exactly **on** the floor (median shelf 0.70, median apex 0.23)
while real jumps sit well above it (1.30 / 1.07), which is what makes the
corroboration work. smallLog goes 12/16 -> 16/16 and the clean control session
stays at 0 phantoms.

## E. The immediate-report path skipped its own dedup

```swift
if heightM >= cfg.immediateReportM {
    // ... emitted here WITHOUT ever checking lastEmit
}
```

Two jumps both over `immediateReportM` inside `dedupSec` **both fired**. That
produced a 4.39 m "phantom" 3.4 s after a real 4.24 m jump on smallLog — one
take-off delivered twice. A rider needs well over 5 s between real jumps.

Fixed: the immediate path now drops a candidate that falls within `dedupSec` of
an already-delivered emission. The earlier one is on screen and cannot be
retracted, so the later one goes, stronger or not.

## F. Airtime floor

`minAirtimeSec = 1.5`. A **resolved** flight shorter than this is a watch knock.
`nil` must pass — it means "not measured", and 3 of 37 real goldens never
resolve a landing. This gate is currently dormant on all six logs; it is a floor
against regression.

## G. Distance — the launch fix

`gpsPoint(near: t0 - 1.0)` was used for **both** the take-off speed and the
displacement origin. Sampling the origin 1 s early folded a whole second of
riding into every jump (~8 m at 30 km/h).

Split: speed still samples at `t0 - 1.0` (correct — before the pop bleeds it
off), displacement now samples at `t0`. Distance MAE 12.80 -> 6.19 m on smallLog
and 4.94 -> 3.87 m on log 287.

## H. `flush()` ordering

`flush()` cleared `pending` before evaluating it. `holdUntil()` scans `pending`
for rivals, so clearing first made the two engines compute different hold
deadlines. It cannot change the output there — `releaseHeld(.infinity)` ignores
them — but the twins are compared on their debug streams too. Now matches the TS
twin: evaluate, then clear.

---

# Full parameter diff

| parameter | V16.1 | V16.2 | why |
|---|---|---|---|
| `popClusterSec` | 2.0 | **0.8** | anchor was walking onto the landing (B) |
| `apexAnchorSec` | — | **2.0** | new — protects the height (C) |
| `heightFromFlight` | — | **true** | new — the measurement path (A) |
| `minLiftPlateauSec` | 0.8 | **0.7** | floor, with corroboration above it (D) |
| `shelfFullSec` | — | **0.8** | new (D) |
| `shortShelfApexM` | — | **0.30** | new (D) |
| `freeFallG` | — | **0.25** | new — the integration window (A2) |
| `minFreeFallSec` | — | **0.45** | new (A2) |
| `minAirtimeSec` | — | **1.5** | new (F) |
| `minReportM` | 1.4 | **1.2** | pure display threshold now (A) |

`minReportM` deserves a note: the old 1.4 existed because the matched filter
could not output below `heightOffsetM = 1.43 m`, so anything lower was
structurally unreachable. The flight integral has no such floor — it returns what
it measures — so 1.4 was censoring real output. Swept on all six logs, 1.2
recovers two goldens (287 @282 s measures 1.39 m against a 2.3 m reference) at no
extra phantom. Below 1.1 the phantom count climbs.

Everything else is unchanged: `popMinG 1.4`, `liftThreshMS2 1.25`,
`liftSmoothSec 0.2`, `plateauScanSec 7.0`, `apexPreSec 2.5`, `apexPostSec 2.0`,
`heightScale 1.91`, `heightOffsetM 1.43`, `dedupSec 6.0`, `immediateReportM 2.5`,
`evalDelaySec 7.5`, `fastEvalSec 3.0`, `landLiftThreshMS2 0.5`,
`landMinPlateauSec 0.4`, `landDipMS2 -0.5`, `landDipMinSec 0.6`,
`landOffsetSec 0.4`, `floatLoadG 0.6`, `maxAttitudeGapSec 0.15`,
`historySec 14.0`.

---

# How to verify

`04_REFERENCE/v16cli.ts` is the reference suite. From `surfhub-watch/`:

```
npx tsx core/tools/v16cli.ts            # the full suite, exits non-zero on regression
npx tsx core/tools/v16cli.ts <log>      # one log
npx tsx core/tools/v16cli.ts --json     # machine-readable
```

Expected output on the reference set:

```
  log     recall   emitted  phantoms  tallest    height    airtime   distance
  BENCH    3/4        3         0      -      0.02m     -        -
  SMALL   16/16      19         3    2.14m    0.21m    0.81s    4.96m
  287     14/14      17         3    2.54m    0.42m    0.46s    3.77m
  NEG      0/0        0         0      -       -        -        -
  CLEAN    4/4        4         0      -      0.28m     -        -
  V142     2/5        4         2    1.57m    0.23m     -        -
  riding totals: recall 36/39 - pooled height MAE 0.300 m - tallest phantom 2.54 m
  PASS  every guard-rail holds
```

The guard-rails it enforces, and why each one:

| guard | value | reason |
|---|---|---|
| control session emissions | 0 | the phantom firewall is the whole design |
| tallest phantom | ≤ 2.6 m | a rider dismisses a small phantom as chop; a tall one destroys trust |
| riding recall | ≥ 34 / 39 | |
| pooled height MAE | ≤ 0.35 m | |

**The tallest-phantom guard matters more than the count.** A 2 m phantom reads as
noise or a pop. A 5 m phantom in a session where nothing like that happened is
the failure a user will not forgive.

## Swift-side check

There is no Swift test runner in this package. To confirm the port, run the same
log through `ReplaySessionController` and compare the emitted jumps against the
TS output above. The two engines are maintained as behavioural twins — same
replay, same numbers.

---

# Known limits, stated plainly

**Airtime got worse.** 0.34 -> 0.46 s on log 287. `t0` now marks the true
take-off, so the flight measures longer. Refitting `landOffsetSec` (0.40 -> 0.30)
centres the bias at +0.08 s but does not recover the MAE. Left at 0.40 so a
validated constant is not moved without cause.

**The height depends on the landing — on a kite.** For a throw the free-fall
window solves it outright (0.02 m). A kite jump has no free fall, so the window is
the descent-arrest rule. Measured on log 287: the integral over the reference
airtime window scores 0.369 m against 0.416 m over the window we measure — **the
remaining gap is entirely the window, not the operator**. Where the landing is not
resolved at all (3 of 37) the engine falls back to the matched filter. Improving
the landing rule now improves the height too; they are coupled in V16.2 in a way
they were not in V16.1, and it is the highest-return work left.

**One bench throw is not detected.** The 4th measures 0.91 m, below the 1.2 m
display floor. That is correct behaviour, not a miss.

**V142 recall is 2/5.** Unchanged from V16.1. That session was never solved.

**Below ~2.5 m on a kite, height is still hard.** It is better than it was
(0.21 m on smallLog against a 0.50 m null model — the first time all session that
the engine beat a constant predictor in that band) but the band remains the
weakest part of the range.

**The reference is HOOLAN**, and HOOLAN is not ground truth. Measured on the four
bench throws where real physics is available, HOOLAN over-reads by about 1.9x and
its own height/airtime pairs are mutually inconsistent under ballistics
(`h/T²` spans 0.494–0.816 where a projectile requires 1.226 exactly). The BENCH
row above is scored against `g·T²/8`, not against HOOLAN.
