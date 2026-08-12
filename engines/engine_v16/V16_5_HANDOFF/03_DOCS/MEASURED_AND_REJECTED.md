# What was measured and rejected on the way to V16.3, V16.4 and V16.5

Recorded so nobody spends a week re-deriving a negative. Everything here was run
on real logs against real references before being discarded.

---

## 1. Airtime cannot be improved. This is now proven, not suspected.

The only test that matters for a measurement is whether it beats a CONSTANT.
Leave-one-out against each reference:

| | 287 (HOOLAN) | GAVRI (Surfr) |
|---|---|---|
| constant (median) | 1.000 s | 0.412 s |
| **our measured airtime** | 0.464 s | **1.001 s** — loses |
| ballistic from our own height | 0.275 s | 0.483 s |

The two sessions pick **opposite** best predictors. The optimal shrink toward the
constant is a = 0.80 on one and a = 0.05 on the other, so no blend
cross-validates. Do not ship one: that is precisely the trap V15 fell into, where
a 0.75-weight shrink toward a 3.4 s prior looked like accuracy and was a constant.

**The references are not equivalent, which explains the split.** HOOLAN's airtime
is r = 0.952 with HOOLAN's own HEIGHT — very nearly derived from it, so predicting
airtime from height matches them almost by construction. Surfr's is r = 0.540,
i.e. it carries real independent information, and ours correlates r = 0.062 with
it — none at all. Our spread on GAVRI is 1.15 s sd against their 0.53 s.

**What that does not license:** rewriting the landing rule. A 2-D sweep of
`landDipMS2` × `landDipMinSec` over both references finds no better joint
operating point. The corner that favours GAVRI costs pooled height 0.292 →
0.331 m. `landOffsetSec = 0.4` is confirmed: refitting it per session gains
0.00–0.02 s, and the two sessions want 0.30 and 0.43 — i.e. the residual is
noise, not an offset.

**To move airtime you need ground truth — video timing — not a new algorithm.**

---

## 2. The height formula is right. The window is the entire error budget.

Given the correct window the endpoint-anchored double integral reproduces the
bench throws to **2 cm** and both riding references to within 6 cm. So there is
no point looking for a more complex formula — polynomials, powers and matrices
were all tried and all failed, and now we know why.

**But no better window is available.** Fitting a single global window per session
and cross-validating it:

| window | 287 | GAVRI |
|---|---|---|
| shipped (t0 → landing, per jump) | 0.416 | 0.401 |
| 287's own optimum (−0.5 s, 6.7 s) | 0.209 | **0.548** |
| GAVRI's own optimum (−0.1 s, 5.1 s) | **0.692** | 0.390 |
| best joint (−0.2 s, 6.8 s) | 0.290 | **0.454** |

Every fixed window that helps one session hurts the other by more than it gains.
The per-jump oracle scores 0.05 m but is **not a real floor** — with 858 candidate
windows spanning 0 to roughly the reference height, 3–13 % of them land within
10 cm of any target, so random search would find one.

That the two references demand such different windows is evidence they **measure
different things**, not that our window is wrong.

---

## 3. The big jumps have no measurable headroom

Error by reference height band:

| band | n | height MAE |
|---|---|---|
| > 6 m (287) | 6 | 0.360 m — **4 % relative** |
| 4–6 m (287) | 5 | 0.464 m |
| 2.5–4 m (GAVRI) | 25 | 0.434 m |
| < 2.5 m (GAVRI) | 13 | 0.288 m |

The videogrammetry study (Sensors 2021, 21(24):8353) measured Surfr itself at
0.51 m RMS. In the big-air band we are already below the reference's own noise.

The apparent "we read low on big jumps" slope against Surfr
(`h_surfr = 0.804·h_ours + 0.610`) is the errors-in-variables signature:
r(error, THEIR height) = −0.677 against r(error, OUR height) = +0.181. Applying
that correction makes MAE **worse** — 0.485 against the identity's 0.468.

**We have no reference at all above 8.5 m.**

---

## 4. Discriminators that failed

Scored as AUC between GAVRI's 40 Surfr-confirmed jumps and its extras.

### The physics-motivated unloading features — all failed

Built on the correct principle (a rider on the water is SUPPORTED; airborne under
a canopy the support is only partial) and none of them separates:

| feature | AUC |
|---|---|
| sustained unloading run | 0.428 |
| minimum specific force | 0.448 |
| unloading rate | 0.470 |
| peak vertical velocity | 0.540 |
| time below 0.7 g | 0.550 |

Some point the wrong way. **This is a meaningful result, not just a null:** the
extras carry the weightlessness signature of a real jump. They do not look like
pops or chop — they look like jumps. That is strong evidence a good share of them
ARE jumps Surfr missed. Surfr itself missed one that we caught.

### The barometer — out of the game

AUC 0.524, median 0.00 m in both groups. It cannot do better: at ~0.4 Hz a 4 s
flight contains **1.6 samples**, and the sensor is noisy and unstable in a sea
environment. Consistent with the earlier finding that 67 of 68 inter-sample steps
above 3 m fall outside any jump.

### `confidence` carries nothing of its own

It is defined as `plateau >= minLiftPlateauSec * 1.5`, i.e. a binarised shelf.
A rule on `confidence < 0.7` IS a rule on `shelf < 1.05`. Do not treat them as
two signals.

### What did work

| feature | AUC |
|---|---|
| height | 0.815 |
| lift shelf | 0.782 |
| apexRaw | 0.761 |
| airtime VALUE | 0.552 — nearly useless |

Note the last row. The useful landing signal is **whether the arrest rule
resolved**, not what airtime it produced.

---

## 5. The "no airtime" hypothesis, priced

Before the settle fallback, 7 of 16 GAVRI extras had no airtime against 5 of 40
confirmed jumps. Real enrichment (44 % against 12.5 %) — but as a filter it is
**58 % precision**: it would remove 7 phantoms and 5 real jumps, dropping recall
from 40/41 to 35/41. Rejected on its own; kept as one half of the two-clause rule
where the shelf supplies the second condition.

---

## 6. Still standing from earlier versions — do not retry

- V15 as a small-jump fallback: its airtime is 75 % a constant.
- V10 / V7 engines; V10's gyro landing; V12's architecture.
- Adaptive μ + Kσ threshold; V8's parabolic barometric apex.
- Quadratic / cubic / sqrt / log height forms; the apex/RMS normaliser (not
  causally available at emission time); barometric fusion.
- Pop azimuth — spread is the full circle, −176° to +172°. The GPS course over a
  ~2 s baseline at 8 m accuracy is meaningless, and a wrist is not a board.
- Pop elevation — sign convention unresolved; the measured median points DOWNWARD
  during a take-off, matching the sign trap that cost V16.0/V16.1 their height.
- Shipping the full 64-point arc: 48× the bytes and no better, because it carries
  the integration's high-frequency noise.


---

## 7. Added at V16.4 — the distance investigation

**The reference reports a CHORD, not a path length.** Tested on all three logs
that carry distance goldens; our chord wins every time (3.8 / 5.0 / 8.7 m against
5.3 / 5.9 / 9.2 m for the integrated path). `v x T` is far worse still
(16.9 / 9.7 / 12.2 m), so they are not computing that either.

**GPS endpoint interpolation is right in principle and does not pay.** Fixes
arrive at 1.00 Hz on every log, so snapping take-off and landing to the nearest
one carries up to 4 m of pure timing error at each end — arithmetic, not
filtering. But measured it splits: log 287 improves (3.77 -> 3.64 m, r 0.885 ->
0.918) while smallLog worsens on both counts (4.96 -> 5.12 m, r 0.456 -> 0.380).
Pooled it is a wash, so it is not shipped.

**Distance is airtime x speed in disguise.** Across 11 of smallLog's 14 jumps,
switching the endpoint handling moves the error by **0.01 m**. The entire session
error sits in three outliers, and all three are landing failures:

| t0 | golden | ours | our airtime |
|---|---|---|---|
| 638 s | 30.4 m | 19.5 m | no landing resolved |
| 890 s | 19.9 m | 31.4 m | 5.8 s |
| 1159 s | 21.2 m | 42.0 m | 6.1 s |

Double the airtime error, double the distance error. **Distance therefore carries
the same ceiling as airtime** — see section 1.

## 8. Added at V16.4 — what the references are, measured

**Surfr timestamps the APEX.** Tested on the 15 second-precision Gavri rows: the
lag scatter is 0.523 s against take-off, **0.387 s against the measured apex**, and
0.91-1.08 s against either landing. The MEASURED apex also beats a modelled
0.42 x airtime (0.582 s), so our reconstructed apex time carries real information.
Landing is ruled out directly: r(lag, their airtime) = -0.574, where a landing
stamp would give about +1.

**Surfr FLOORS the minute, it does not round.** Assuming rounding drops 5 pairings
and worsens height MAE to 0.49 m.

**The two references disagree about airtime by nearly a second.** HOOLAN averages
3.56 s on smallLog against Surfr's 4.49 s on Yaniv over overlapping height ranges,
while our own mean is stable across sessions (4.97 / 4.25 / 4.27). Converging to
both at once is not possible.

## 9. Added at V16.4 — pairing method

**Never order by height inside a quantised minute.** It is circular — it uses our
measurement to choose which reference row we are compared against — and it
flattered us by 0.11 m of MAE on Gavri. Use a strictly chronological
order-preserving alignment with skips, driven by time alone.

**Yaniv is reported but not guarded.** Every row of its reference is
minute-quantised, so "unmatched" there does not mean "false positive": its 3.72 m
unmatched emission sits 42 s from golden #11 while another of ours sits 21 s away
and wins the greedy match. Which is the real #11 cannot be decided from the data.
Rails calibrated on second-precision references must not be driven by a reference
that has none.


---

## 10. Added at V16.5 — the V17 proposals, tested

Every testable proposal from the V17 / physics-first specs, measured on the logs.

### Sample rate cannot be the lever

`rawAcc` is empty on all eight logs, so 800 Hz cannot be replayed — but the
DIRECTION is testable by decimating our 200 Hz logs:

| rate | height MAE |
|---|---|
| 200 Hz | 0.330 m |
| 100 Hz | 0.326 m |
| 50 Hz | **0.320 m** |
| 25 Hz | 0.377 m |
| 12.5 Hz | 0.628 m |

Flat from 50 to 200 Hz; the largest per-jump difference between 200 and 100 Hz is
0.026 m. The information saturates far below the current rate, so raising it
cannot improve height. 50 Hz suffices.

### Boundary sensitivity — the analytic prediction is exact

Forcing `z(T) = dzB` instead of 0 moves the apex by `(t_apex/T)*dzB`, so
`S_B = t_apex/T`. Measured over 29 goldens:

```
S_B          median 0.399   range 0.29-0.60
t_apex/T     median 0.399
difference   0.0003
```

**A 1.0 m water-level mismatch moves the reported height by 0.40 m.** Monte-Carlo
(take-off +-0.10 s, landing +-0.10 s, boundary +-0.50 m, bias +-0.05 m/s2) gives
sigma_H = 0.145 m, of which the boundary is the dominant term (0.092 m without
it). Note sigma_H is well below the actual 0.33 m MAE of the time: these
perturbations do not explain our error.

### Attitude is NOT the bottleneck

Correlation of each feature with |height error| over 29 goldens:

| feature | r(abs error) |
|---|---|
| endpoint sensitivity | **0.420** |
| reference height | 0.339 |
| lift shelf | 0.261 |
| gyro peak | 0.083 |
| **attitude travel** | **0.079** |
| rotation energy | −0.176 |
| GPS speed | 0.003 |

Net attitude change over the flight spans 21-122 degrees and predicts nothing.
The claim that attitude error is the main bottleneck is not supported.

### Endpoint ensemble, multi-apex and apex velocity

- Ensemble median: 0.329 m against the single estimate's 0.330 m — **no accuracy
  gain**. But `sigma_endpoint` correlates 0.420 with the error, so it is a usable
  QUALITY signal.
- Median of four apex estimators: 0.328 m. Noise.
- `|v|` at the reported apex is already 0.005 m/s median (max 0.05). The
  velocity-consistency condition holds by construction — the apex is the maximum
  of the chord-removed curve, where the derivative is zero.

### Absolute altitude as a height witness — refuted, with a correction

An earlier pass in this project reported the channel as flat everywhere. That was
wrong: it alternates between a LIVE mode (precision 0.5, ~3 Hz, real excursions)
and a FROZEN mode (precision 5, a constant repeated for tens of seconds), and the
first measurement mixed the two.

Corrected, with a health filter:

| log | live share | goldens with the channel live IN FLIGHT | baro MAE | IMU MAE |
|---|---|---|---|---|
| 287 | 87 % | 2 of 14 | 1.751 m | 0.416 m |
| smallLog | 42 % | 0 of 15 | — | 0.199 m |
| CLEAN | 100 % | 4 of 4 | 0.894 m | 0.140 m |
| V142 | 22 % | 1 of 4 | 0.940 m | 0.240 m |

On log 287 the channel is live for 87 % of the session yet frozen during 12 of
the 14 jumps. The proposed "prefer the barometer when it agrees within 20 %" gate
fires on 2 of 37 goldens and makes the error worse on both (−0.47 -> +0.68 m and
−0.01 -> +0.41 m) — structural, since agreement means nothing to gain and
disagreement means no switch.

Apple's own `accuracy` on the live samples reads 4.7-9.6 m.

### The WOO document could not be read

`thewooway13.pdf` is 6.3 MB of image streams with subset-embedded fonts and no
usable text layer. 116 text streams extract to unmapped glyph codes. Nothing from
it is quoted anywhere in this project, and nothing should be until it can be read.
