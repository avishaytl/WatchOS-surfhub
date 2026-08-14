# What Surfr actually does, and what "truth" means

Everything below is sourced or measured. Nothing is inferred from reputation.

---

## 1. Surfr has no formula. It is a trained model.

From Surfr's own documentation:

> "we spent years developing proprietary AI algorithms that analyze sensor data
> and calculate jump heights with incredible precision"

Surfr.AI is trained on **hundreds of gigabytes** of real-world data: professional
competition sessions (Red Bull, GKA, BAKL) and recreational riders, jumps from
1–2 m to over 20 m, flat water and waves, light to extreme wind, beginners
through double loops and board-offs.

**This settles a question we spent two sessions on.** We tried to reverse-engineer
their height as a function of physical observables and could not — a regression
on 17 physical features (our height, peak vertical velocity, `v²/2g`, airtime,
free-fall duration, lift shelf, specific-force statistics, pop magnitude, and
cross terms), allowed to **overfit in-sample with no holdout at all**, reached
only R² 0.877 on Kineret and 33 % of jumps within ±20 cm. There is no closed
form to recover, because there isn't one.

It also explains the ±20 cm agreement between two watches both running Surfr.
That is **repeatability, not accuracy** — two instances of the same model on the
same wrist see nearly the same motion and make nearly the same error. The shared
error cancels between them. We cannot join that cancellation without their model.

### Their airtime is not ballistic, and their height is not derived from it

Measured on their own 41 Kineret rows:

```
  h = 0.284 * airtime^1.721      R2 0.653
  h ~ airtime, linear            R2 0.586, rms 0.71 m
```

If their height were derived from their airtime, R² would be ~0.99. It is 0.65.
**Height and airtime are two independent outputs.** And `g·t²/8` on their mean
airtime of 5.27 s gives 34 m against the 5.05 m they report — their airtime is
real flight time under kite lift, which is 2.63× the ballistic time for the same
height.

**HOOLAN do the opposite.** There, r(airtime, height) = 0.952 — they derive one
from the other, which means they run IMU double integration much as we do. Our
r = 0.991 agreement with HOOLAN on log 287 may therefore partly reflect a shared
method rather than shared correctness.

---

## 2. The only independent ground truth that exists

**Videogrammetric Verification of Accuracy of Wearable Sensors Used in
Kiteboarding**, *Sensors* 2021, 21(24):8353. Four cameras on the shore of the
Danube at Šamorín; reference accuracy **0.03–0.09 m**; 20 jumps from 3.07 to
7.30 m; spherical targets on the board; jump height defined as the highest
board Z minus the board Z at re-contact with the water. Surfr ran on an
**iPhone SE 2016 attached to the board**.

### Surfr against that truth

| truth | n | Surfr bias | as a fraction |
|---|---|---|---|
| 3–4 m | 7 | +0.06 m | 1.7 % |
| 4–5 m | 2 | +0.15 m | 3.1 % |
| 5–6 m | 5 | +0.19 m | 3.4 % |
| **6–8 m** | 6 | **+0.73 m** | **11.4 %** |

**RMS 0.51 m. Overestimates on 15 of 20 jumps. Worst case +1.42 m on a true
6.28 m jump.** The paper states plainly that all three systems tested overestimate
and that the error grows with height, exceeding 20 % of the true height above 5 m.

Fitting the study's own table:

```
  truth = 0.8025 * surfr + 0.7309      R2 0.961, residual 0.26 m rms
```

The 0.26 m residual is the part of Surfr's error that is **not** a height-dependent
bias. It is their irreducible scatter against truth on that hardware.

---

## 3. What this says about our own numbers

Our bias against Surfr on the biggest Kineret jumps was **−1.09 m at 6.5–8 m**.
Surfr's bias against video at 6–8 m is **+0.73 m**. Same magnitude, opposite
sign. Checking directly:

| | vs Surfr as displayed | vs Surfr calibrated to video |
|---|---|---|
| V16.5 | bias **−0.341** | bias **−0.076** |
| V16.6 | bias −0.122 | bias **+0.144** |

**V16.5 was almost unbiased against videogrammetric truth.** V16.6 has lower MAE
against both (Kineret 0.518 → 0.476 against calibrated truth) but now overshoots
it. In other words: much of what looked like our error was Surfr reading high.

Independent support that our integrator is sound: on thrown-watch logs it returns
0.017 m against `g·T²/8`, a physical ground truth with no reference ambiguity.

---

## 4. Why ±20 cm on 80 % of jumps against Surfr is unreachable

Surfr's own residual against truth, after removing its height-dependent bias, is
**0.26 m rms**. Even with a *perfect* estimator on our side, agreement with
Surfr would be bounded by that alone — roughly 55 % of jumps within ±20 cm, not
80 %. The remaining route would be to reproduce their model **including its
errors**, which needs their training data.

---

## 5. The calibration search, with cross-session validation

Target: minimise disagreement with Surfr as displayed. 95 paired jumps across
Kineret, Yaniv and Gavri. Fits are validated by holding out a whole session.

| transform | MAE | within 20 cm |
|---|---|---|
| **identity (V16.6 as shipped)** | **0.546** | **24 %** |
| published inverse, `1.246h − 0.911` | 0.609 | 23 % |
| affine fitted, session held out | 0.819 | 14 % |
| hinge fitted, session held out | 0.593 | 27 % |
| flat +0.15 m on h ≥ 4 m | 0.556 | 19 % |
| flat +0.25 m on h ≥ 4 m | 0.564 | 20 % |

**The identity wins.** Two reasons, both measured:

1. **There is no bias left to remove.** Our raw bias across the 95 jumps is
   **+0.006 m**. An offset cannot improve a mean that is already right.
2. **Any slope amplifies our scatter.** Our residual is dominated by
   jump-to-jump variance, not bias — the lag-1 autocorrelation of the residual is
   −0.177, i.e. white noise with no session drift. Multiplying by 1.246 inflates
   that variance by 25 % while correcting a near-zero bias.

The fitted hinge is worth noting for the record: its optimum has **k < 0**, i.e.
it wants to *shrink* big jumps. That is regression toward the mean asserting
itself, and it is the opposite of what a big-air calibration should do. It buys
3 points of ±20 cm hit rate at the cost of 0.05 m of MAE and a −0.179 m bias.
Not shipped.

Applying the published Surfr→video transform to the **reference** instead of to
our output does help (0.546 → 0.489, ±20 cm 24 % → 29 %) — but that is a
different question. It measures us against video truth, not against Surfr.

---

## 6. What ships

`heightCalSlope = 1.0`, `heightCalOffsetM = 0.0` — one explicit stage in the
engine, so the target is a pair of numbers rather than a decision scattered
through the estimator. Identity is the **measured optimum for matching Surfr**,
not an unset default.

The videogrammetric coefficients `0.8025 / +0.7309` are recorded in the code
next to it, ready to switch to. Two cautions before anyone does:

- The study measured an **iPhone bolted to the board in 2021**. Our sessions are
  **Surfr.AI on a wrist watch in 2026**, and Surfr state they moved to wrist and
  chest mounting and rebuilt the algorithm. The bias may already be gone.
- The study's ground truth is **board height**, not wrist height.

Switch only against our own video measurement.

---

## 7. Smaller facts worth keeping

- Surfr's default minimum reported jump is **3 m**, adjustable down to 1 m. An
  absent row in their list is not necessarily a missed jump.
- Surfr require **100 Hz** devices; they list ~95 % of 100 Hz Garmin watches as
  compatible.
- Surfr moved from board mounting to wrist and chest specifically because those
  positions are "not exposed to noise from the water".
- The 2021 study notes that below 5 m the residual error "roughly corresponded
  to the height of the waves" (~0.2 m) — a floor set by the definition of "water
  level" in a wave field, which applies to us identically and which our endpoint
  anchoring inherits.

---

## Sources

- [What is Surfr.AI? — Surfr Help Center](https://support.thesurfr.app/en/articles/9853659-what-is-surfr-ai)
- [Videogrammetric Verification of Accuracy of Wearable Sensors Used in Kiteboarding, *Sensors* 2021, 21(24):8353](https://pmc.ncbi.nlm.nih.gov/articles/PMC8706814/)
- [The app is not registering my jumps properly — Surfr Help Center](https://support.thesurfr.app/en/articles/10644491-the-app-is-not-registering-my-jumps-properly)
- [Which devices are compatible with the Surfr App? — Surfr Help Center](https://support.thesurfr.app/en/articles/9859609-which-devices-are-compatible-with-the-surfr-app)
- [Kitesurfing Jumps – Woo 3 vs Surfr App — Kite Mad World](https://kitemadworld.com/kitesurfing-jumps-woo-3-vs-surfr-app/)
