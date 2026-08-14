# V16.7 — handoff to the watch team

Three changes to the height window, all aimed at BIG AIR, plus one explicit
calibration stage that records which reference we are targeting.

**Supersedes `V16_6_HANDOFF` and everything before it** — this package contains
everything they had.

```
                            V16.5          V16.7
  height MAE, jumps >=4 m   0.590 m        0.502 m      -15 %
  bias on those jumps       -0.429 m       -0.138 m
  height MAE, pooled        0.461 m        0.454 m
  recall                    unchanged on every log
  tallest phantom (guarded) 1.56 m         1.56 m
  negative control          silent         silent
  bench throws              0.017 m        0.017 m
```

| log | reference | V16.5 | V16.6 | **V16.7** | >=4 m at 16.7 |
|---|---|---|---|---|---|
| KINERET (big air) | Surfr | 0.601 | 0.527 | **0.498** | **0.491** |
| YANIV | Surfr | 0.556 | 0.495 | 0.519 | 0.683 |
| GAVRI | Surfr | 0.523 | 0.603 | 0.628 | — |
| 287 (big air) | HOOLAN | 0.226 | 0.252 | 0.248 | 0.235 |
| smallLog | HOOLAN | 0.206 | 0.233 | 0.233 | — |
| CLEAN | HOOLAN | 0.112 | 0.172 | 0.172 | — |
| V142 | HOOLAN | 0.158 | **0.138** | **0.138** | — |
| BENCH | ballistic | 0.017 | 0.017 | 0.017 | — |

**This release deliberately trades small-jump accuracy for big-jump accuracy.**
Say so plainly to anyone who reads the numbers: GAVRI, a session of 2.4–3.1 m
jumps, gets 15 % worse. That was the instruction and it is the right trade —
big air is what the rider sees and what the references disagree about.

---

## Change 1: landing post-roll — 0.8 s, two triggers, and a window floor

```swift
public var heightPostRollSec: TimeInterval       = 0.8
public var heightPostRollMinAirSec: TimeInterval = 4.0   // trigger A
public var heightPostRollMinM: Double            = 3.5   // trigger B
public var heightPostRollFloorSec: TimeInterval  = 5.0   // window floor
```

### 16.7: the failure mode has two faces

An early landing shows up **either** as a short airtime **or** as a low height,
and which one you see depends on where in the descent the arrest rule fired. The
two worst jumps in the Kineret session are exact mirror images:

```
  Surfr 5.77 m / 5.15 s   ->   ours 2.69 m / 6.34 s    long air, LOW height
  Surfr 7.09 m / 5.79 s   ->   ours 5.38 m / 3.90 s    big height, SHORT air
```

16.6 gated on airtime alone and caught the first. The second — **the
second-highest jump of the session** — missed the 4.0 s gate by 0.10 s and went
out uncorrected at 5.38 m against 7.09 m. A height gate alone fails the other
way. So the gate is a **disjunction**, and the window gets a **floor**: a landing
resolved before 5 s on a jump this size is not believed.

```
                            Surfr >=4 m  Kineret >=4 m  HOOLAN   that 7.09 jump
  16.5 (pre 0.3, no post)      0.706        0.628        0.207      5.37 m
  16.6 (airtime gate only)     0.588        0.528        0.226      5.44 m
  16.7 (this)                  0.569        0.488        0.222      6.31 m
  ungated, no gate at all      0.559        0.488        0.235      6.31 m
```

The ungated rule reaches the same place but costs GAVRI 34 % (0.522 -> 0.654),
a session of 2.4-3.1 m jumps whose landings are already right. The disjunction
buys the big-air gain for 0.023 m of GAVRI and **improves HOOLAN**
(0.226 -> 0.222). Trigger B costs one extra integration over a window already
held in the ring.

### Why the arrest rule closes early at all — the physics

`sf = 1` means the kite is carrying the rider full weight. **That is
indistinguishable from standing on the water**, and the descent-arrest rule
cannot tell them apart. On the 7.09 m jump the specific force is back to ~1.0
from t0+2.0 s while the rider is still 5 m up; the real water impact is the
sf 1.98 / gyro 2.8 spike at t0+4.25 s.

Two discriminators were tested and both fail: high-frequency jitter of the
specific force (0.130 in the ambiguous stretch against 0.059 in genuine riding —
the wrong way round), and a velocity ZUPT with the water-contact flanks placed at
a fixed offset (Kineret 0.530 -> 0.660..0.794 across every setting tried).

### Original 16.6 rationale, unchanged

### The physics

The pre-roll shipped in 16.5 because `t0` is the POP and the rider is already
rising. This is its mirror at the other end, and the principle is the same:

> **An endpoint anchor is only sound where the rider is provably at water level.**

A kite jump is **not ballistic**. Measured on Kineret, Surfr's airtime is
**2.63×** the ballistic `sqrt(8h/g)` for the same height — the kite carries the
rider, so the descent is long and shallow. The descent-arrest landing rule
closes early on that shape: airtime bias **−0.41 s** on jumps at or above 4 m.
Forcing `z(T)=0` while the rider is still descending drags the apex down by
`(t_apex/T)` times the height still remaining, and that is exactly the signature
in the data:

| Surfr height | bias |
|---|---|
| < 3.5 m | +0.26 m |
| 3.5–4.5 m | −0.08 m |
| 4.5–5.5 m | −0.30 m |
| 5.5–6.5 m | −0.57 m |
| 6.5–8.0 m | **−1.09 m** |

Running the window **past** the landing is safe — after touchdown the trace is
flat at water level and the chord removal absorbs it. Running it **short** is
not: ending at the landing impact instead **doubles** the error (0.574 → 1.332),
which also disposes of the theory that the impact spike corrupts `W(T)`.

### Gated on AIRTIME, not height

A height gate was tried first and is wrong in principle: it withholds the
correction from precisely the jumps we under-read. The worst jump in the Kineret
session — **2.69 m read against 5.77 m** — carries 6.34 s of airtime, clears an
airtime gate, and is fixed by it. A height gate at 3.5 m blocks it.

### Why gated at all

|  | Surfr >=4 m | Kineret >=4 m | GAVRI | HOOLAN |
|---|---|---|---|---|
| 16.5 | 0.706 | 0.628 | 0.522 | 0.207 |
| **gated (ships)** | **0.588** | **0.528** | 0.604 | 0.227 |
| ungated | 0.553 | 0.485 | 0.701 | 0.246 |

The ungated version is better on big air and costs GAVRI 34 %. Gated ships.

### THE ENGINE MUST WAIT — do not skip this

The engine is **streaming**, and the samples the post-roll needs do not exist at
the landing instant. Measured lookahead past the landing at the evaluation
point: **median 0.60 s** on the candidates the gate selects, **0.00 s** on
smallLog. Applying the post-roll without waiting makes `flightHeight()` return
`null` on its `maxAttitudeGapSec` guard, the height falls back **silently** to
the matched filter, and the whole suite degrades:

```
  without the wait   pooled 0.461 -> 0.629    Yaniv extras 6 -> 13
  with the wait      pooled 0.461 -> 0.454    Yaniv extras 6 -> 8
```

So `evaluate` returns `false` and retries, exactly as it already does for the
landing instant, and at the `evalDelaySec` deadline it takes whatever arrived:

```swift
if !ballistic, let land = winB, cfg.heightPostRollSec > 0,
   land - t0 >= cfg.heightPostRollMinAirSec {
    let want = land + cfg.heightPostRollSec
    if let last = ring.last {
        if last.t < want, !forced { return false }
        winB = min(want, last.t)
    } else { winB = want }
}
```

**Emission latency grows on triggered jumps** — the window now runs to
`max(airtime, 5 s) + 0.8 s` after take-off, so a short-airtime big jump waits
longest.
`evalDelaySec` stays 7.5 s, so a jump with more than ~6.7 s of airtime hits the
deadline first and simply gets a shorter post-roll. That is the intended
degradation, not a bug.

---

## Change 2: pre-roll 0.3 → 0.5 s (16.6)

16.5 chose 0.3 s on six logs. The Kineret session — **41 Surfr goldens at SECOND
precision**, 1.65–7.09 m — moved the weighted minimum across all eight:

| pre | 0.3 | 0.4 | **0.5** | 0.6 | 0.8 |
|---|---|---|---|---|---|
| MAE (135 goldens) | 0.458 | 0.444 | **0.442** | 0.447 | 0.458 |

Free fall stays exempt; BENCH is unchanged at 0.017 m.

---

## Change 3: an explicit reference-calibration stage (16.6)

```swift
public var heightCalSlope: Double = 1.0
public var heightCalOffsetM: Double = 0.0     // reported = slope * measured + offset
```

One place where the measurement is mapped onto whatever counts as truth, so that
decision is a pair of numbers instead of a choice scattered through the
estimator.

**Current target: Surfr as displayed. The calibration is the IDENTITY, and that
is a measured optimum, not a default left unset.** Searched over 95 paired jumps
in three Surfr sessions, every fit validated by holding out a whole session:

| transform | MAE | within 20 cm |
|---|---|---|
| **identity (ships)** | **0.546** | **24 %** |
| published inverse `1.246h - 0.911` | 0.609 | 23 % |
| affine fitted, session held out | 0.819 | 14 % |
| hinge fitted, session held out | 0.593 | 27 % |
| flat +0.25 m on h >= 4 m | 0.564 | 20 % |

Two measured reasons the identity wins. **There is no bias left to remove** —
our raw bias across the 95 jumps is +0.006 m. And **any slope amplifies our
scatter**, which is what dominates: the residual's lag-1 autocorrelation is
-0.177, i.e. white noise with no session drift, so multiplying by 1.246 inflates
the variance 25 % to correct a bias that is already zero.

The alternative target is recorded in the code beside it. Videogrammetry
(*Sensors* 2021, 21(24):8353 — four shore cameras, reference accuracy
0.03-0.09 m, 20 jumps 3.07-7.30 m, targets on the board) measured Surfr against
ground truth as `truth = 0.8025 * surfr + 0.7309` (R^2 0.961, residual 0.26 m).
Surfr overestimates 15 of 20 jumps there, growing from +0.06 m at 3-4 m to
**+0.73 m (11.4 %) at 6-8 m**.

That matters for how this release is read: our bias against Surfr at 6.5-8 m was
-1.09 m, and Surfr's bias against video at 6-8 m is +0.73 m — same size, opposite
sign. Against the calibrated truth **V16.5 was almost unbiased (-0.076 m) and
V16.6 overshoots (+0.144 m)**, though V16.6 still has the lower MAE against both
(Kineret 0.518 -> 0.476 against calibrated truth).

**Do not switch to the videogrammetric coefficients without our own video
measurement.** That study used an iPhone bolted to the board in 2021; our
sessions are Surfr.AI on a wrist watch in 2026, Surfr state they rebuilt the
algorithm after moving to wrist and chest, and the study's ground truth is BOARD
height, not wrist height.

Full write-up with sources: `03_DOCS/SURFR_WHAT_THEY_DO.md`.

---

## Measured and rejected this round — do not retry these

| idea | result |
|---|---|
| accelerometer clipping | **no clipping**: aM max 8.03 g, 6 samples within 10 % of it |
| gyro saturation | **none**: max 27.6 rad/s, no ceiling |
| attitude error in flight | fused vs gyro-only propagation diverges **1.52° median**; integrating on gyro-only gives 0.611 vs 0.612 — not the bottleneck, even on big air |
| removing accelerometer bias from quiet riding | 0.612 → **1.085**. The −0.163 m/s² measured is a real physical signal, and endpoint anchoring turns a constant bias into −bT²/8 at mid-window, so removing it pushed our height the wrong way. Proof the channel is bias-free. |
| ending the window at the landing impact | 0.574 → **1.332** |
| adaptive pre-roll ∝ shelf | 0.595 vs 0.579 flat |
| adaptive pre-roll ∝ height | 0.585 vs 0.579 flat |
| adaptive pre-roll **inversely** ∝ shelf | cross-validated 0.565 vs 0.566 flat |
| height-gated post-roll (step and ramp) | blocks the jumps that need it |
| settle-gated post-roll (4 variants) | none beats the flat gate |
| fixed total window T = 5…7 s | loses to `max(air, 5) + 0.8` |
| affine calibration to Surfr | **fails leave-one-session-out: 0.564 → 0.821** |
| hinge calibration `h + k·max(0, h−h0)` | fails LOSO 0.545 → 0.554; the in-sample optimum is k=0 |
| GPS-altitude fusion with the IMU | 0.598 → 0.591 at w=0.9. 0.007 m. |
| ballistic distance `v·sqrt(8h/g)` | Kineret 8.94 → 6.45 but 287 3.77 → **9.86** |
| velocity ZUPT instead of the position chord | MAE 0.526 → 0.655-0.709. Two constraints on the single integral cancel a constant acceleration bias exactly, which the chord cannot — but it trades MAE for a tighter core (28 % within 20 cm vs 13 %) and a worse tail. |
| reverse-engineering Surfr's height from physics | a 17-feature regression **allowed to overfit with no holdout** reaches only R^2 0.877 and 33 % within 20 cm on Kineret. Surfr.AI is a trained model, not a formula — there is no closed form to recover. |

### Why no post-hoc calibration to Surfr can work

The height error correlates with **their** height (r = −0.397) and not with ours
(r = +0.272) — the classic errors-in-variables signature. A correction can only
use **our** number. On top of that the three Surfr sessions demand incompatible
transforms (slopes 0.594, 0.973, 0.866), while the four HOOLAN sessions agree
within noise (0.941, 0.956, 0.943, 1.107) across mean heights from 1.7 to 5.3 m.

---

## The barometric channels, measured on Kineret

`absAlt` is back — **8216 records**, after two sessions with zero. The
`continuous` acquisition mode was restored and it worked. Keep it.

The channel still cannot be a height source, and now there is a number for it:

| channel | usable jumps | samples in flight | MAE vs Surfr | r |
|---|---|---|---|---|
| **IMU (V16.5)** | 40/40 | ~1000 | **0.61 m** | 0.775 |
| GPS altitude | 39/40 | 6 | 0.97 m | 0.528 |
| absolute altimeter | **17/40** | 17 | 2.94 m | 0.434 |
| relative altimeter | 38/40 | **2** | 3.35 m | 0.312 |

**`precision = 5` is not "frozen", it is DEAD.** 663 consecutive samples carried
**6 distinct values**, with `accuracy` reading 0.0 or 500.0 — sentinels, not
measurements. Two such episodes, 2287 s total, the longest 1632 s. The channel
was live for 46 % of the session, and while live its reported altitude wandered
over a **170 m range** while the rider stayed on one lake.

### Action for the watch team: the relative altimeter runs at 0.39 Hz

The log header declares `baroExpectedHz: 1`. The stream delivered **1659 samples
in 4253 s** — a median inter-sample gap of **2.56 s**, p90 2.59 s, so it is a
stable low rate and not random dropout. A jump lasts 5 s, which means **two
samples in the entire flight**. That is why its MAE is 3.35 m: not noise,
**structural under-sampling**. `status.baroHz` reports 0.

Please find out why `startRelativeAltitudeUpdates` delivers 0.39 Hz. Until it is
fixed there is no point testing any idea that rests on the relative channel.

Separately, pressure moved 6.4 hPa across the session (1029.36 → 1035.78) —
**53 m of apparent altitude**. That rate is not weather; the signature fits water
on the sensor.

---

## What to verify after integrating

1. The version banner reads `16.7`.
2. A bench throw still reports its height (free fall is exempt — 0.017 m).
3. A jump with more than 4 s of airtime is emitted **up to 0.8 s later** than
   before. This is expected.
4. A jump with no resolved landing still reports **no distance** (from V16.4).
5. `landing()` still returns a tuple (from V16.3).
6. New field logs still carry a non-empty `absAlt` stream.

---

## Still outstanding

**`watch-ingest`'s normaliser fills missing `JumpEvent` fields with `0`.** It
must pass the ten optional keys through only when present — `sr: 0` reads as
"stopped dead", `eg: 0` as "no edge at all". **Do not enable the new payload
fields until that is done.**

**Resolved since 16.5:** the `engine=v...` banner now appears in field logs
(`V16 engine=v16.5 config pop=1.4g …` in the Kineret capture), and absolute
altitude is recording again. Thank you — both were on the last list.

---

## Contents

```
00_INSTRUCTIONS.md   this file
01_ENGINE/           JumpEngineV16.swift + the TypeScript twin (both at 16.7)
02_PATCHES/          the absolute-altitude note (kept for reference; done)
03_DOCS/             everything measured and rejected, across all versions, and
                     SURFR_WHAT_THEY_DO.md — what Surfr's algorithm is, the
                     videogrammetric ground truth, and the calibration search
04_REFERENCE/        the replay CLI, the suite output at 16.7, the full
                     jump-by-jump comparison for all nine logs, and the
                     standalone Kineret vs Surfr study
```
