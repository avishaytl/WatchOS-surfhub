# Kitesurf Jump Detection — V9 (full handover)

מסמך מסירה מלא ל‑V9: שינוי הארכיטקטורה (סריקה אופליין על באפר ציקלי), כל הפילטרים,
וכל התובנות מהכיול מול לוגי Surfr אמיתיים. כתוב באנגלית לנוחות מימוש ב‑Swift, עם
תקצירי עברית. **מקור האמת: `core/jumpScanV9.ts` + `core/jumpEngineV8.ts`** (תרגום
Swift: `KitesurfJumpEngineV9.swift` + `KitesurfJumpEngineV8.swift`).

---

## 0. TL;DR

- **V9 is NOT a new height algorithm.** It is the **on-watch DETECTION ARCHITECTURE**:
  the V8 baro-centric engine run **offline** over a **cyclic ring buffer**, scanned
  **backwards** every 5 s. Same physics as V8; different *how it runs*.
- V9 does **both** jump *detection* and *measurement* offline — there is **no
  real-time path and no state machine**.
- Height comes from the **barometer** (a kite's smooth canopy-borne rise is NOT in
  the wrist accelerometer — proven). The IMU only detects/brackets the jump.
- A **robust filter stack** (de-spike, parabola clamp, airtime floor, throws-off,
  confidence floor, capped high-percentile baseline) makes it survive real-world
  noise: garbage baro, hand-movement spikes, small-wave chop.
- Validated on two real Surfr kite logs: **LOG2 top-4 height RMS 0.169 m**; LOG3
  clean (no ≥5 m garbage phantom).

---

## 1. Why the architecture changed (real-time FSM → offline backward scan)

**Old model (V4/V7):** a real-time state machine (idle→riding→airborne→cooldown)
classified each sample as it arrived. **It failed** on a wrist-mounted sensor: a
hand flick, a small wave, or pumping the bar all look like a take-off in the live
accel stream → many false "jumps in place".

**The core problem:** measuring kite jump HEIGHT needs the **barometer**, and a
trustworthy baro height needs a **bi-directional window** — a baseline over ±15 s
*around* the apex, plus samples *after* the apex for the parabolic peak. A causal
real-time detector physically cannot see the future, so it can neither measure the
height nor robustly reject the false positives (which only reveal themselves when
you can see the whole arc + its context).

**V9's answer:** don't classify per-sample. Keep a **cyclic ring buffer** of the
recent samples and run **one periodic batch scan** (every `tickSec` = 5 s) that
re-runs the **full V8 engine** over a bounded look-back window — "scan the buffer
backwards, smartly, every few seconds". Every emitted jump has passed the complete
strict pipeline, so the hand-flick / small-wave / pumping false positives cannot
survive.

```
                 native shell (watchOS / Wear OS)
   CMDeviceMotion + CMAltimeter + CLLocation  ──►  Sample (t,ax..,gv..,baro,spd)
                              │ addSample()  (every sample)
                              ▼
        ┌──────────────────  JumpScannerV9  ──────────────────┐
        │  ring buffer (last `windowSec` = 75 s only)          │
        │                                                      │
        │  Timer every `tickSec` (5 s) → scan(now):            │
        │    1. slice window  [now-75s , now]                  │
        │    2. detectJumpsV8(window)   ← FULL V8 engine        │
        │    3. for each jump: ripeness + edge guards + dedup  │
        │    4. emit the newly-confirmed jumps  → HUD/haptics  │
        │    5. evict samples older than the window            │
        └──────────────────────────────────────────────────────┘
                              │ flush(now)  (once, at session end)
                              ▼
                    final jumps → session summary
```

### 1.1 The four properties that make a backward scan correct

| property | what | why |
|---|---|---|
| **Ripeness (leading-edge guard)** | finalize a jump only `settleSec` (16 s) after its landing | the apex's FUTURE baseline side (±15 s) must be fully in-window; a shorter wait finalizes on a truncated baseline → inflated heights + apex jitter |
| **Trailing-edge guard** | a jump's apex must be ≥ `baselineHalfWinSec` (15 s) from the window's oldest edge | else an aged sub-threshold bump at `winLo` gets a truncated PAST baseline → an inflated phantom |
| **Dedup by apex** | overlapping windows re-find the same jump; emit ONCE, keyed by APEX time (±`dedupTolSec`) | apex is invariant under window truncation (take-off shifts, apex doesn't); keys kept whole-session (O(jumps), tiny) |
| **Bounded memory** | only `windowSec` of samples buffered; evict each tick | a 3-hour session costs the same as 1 minute (verified: peak ~4 k samples) |

**Result:** on clean data V9 reproduces the idealised whole-log V8 result (LOG2:
V8≡V9). On noisy data it tracks it within ±1 marginal jump.

> ⚠️ **Why settle (16 s) ≥ baselineHalfWinSec (15 s) and window (75 s) ≥
> settle + 2·baselineHalfWin + maxArc:** these are not free knobs — they guarantee
> a STABLE interior band where a finalized jump's full ±15 s baseline is present.
> Get them wrong and V9 produces phantoms (we did, once: 29 jumps / a 4.6 m phantom).

---

## 2. The V8 engine (height physics) — what runs inside each scan

הגובה מהברומטר; ה‑IMU רק מזהה/תוחם. הנוסחאות:

1. **Forward-fill + DE-SPIKE** the baro (see §3a).
2. **Baseline** = a **capped high-pressure percentile** over ±15 s (see §3f) — the
   rider's ambient "sea level". `altitude = (baseline − baro) · 8.43` (hPa→m).
3. **Apex** = local-max altitude per jump, refined by a **bounded, concave-only**
   parabola (see §3b).
4. **Airtime** is DERIVED from height (the 0.36 Hz baro can't time a 4 s arc and a
   soft kite landing has no accel spike): `airtime = kiteGlideFactor · 2·√(2h/g)`
   (`kiteGlideFactor ≈ 2.63`, fitted to Surfr). Cross-checked against the IMU
   "calm window" (airborne = quieter wrist) when present.
5. **Distance** = GPS speed at take-off × airtime.
6. **Throws** (a thrown watch, standing) are a separate ballistic time-of-flight
   path — **OFF for real sessions** (see §3d).

---

## 3. The filter stack (all of them)

Each filter is **parameter-light / physically-grounded** (the design goal: robust,
little per-log tuning). Defaults in `DEFAULT_V8_PARAMS`.

| # | filter | default | what it kills | why robust |
|---|---|---|---|---|
| a | **Baro de-spike** (`despikeUpward`) | win 10 s, >1.0 hPa | upward garbage spikes (LOG3 → 1070 hPa) that inflate the baseline → phantoms | one-sided: a kitesurfer only LOWERS pressure, so anything ABOVE the local median is a glitch. No amplitude tuning |
| b | **Parabola clamp** | concave + \|d\|≤0.5 | apex extrapolation explosions (flat 0.5 m bump → 6.7 m) | a real peak is concave (den<0) and its vertex lies BETWEEN samples |
| c | **Measured-airtime floor** | 1.5 s | brief hops / single-sample spikes | the out-of-water bracket width IS the airborne time; works at any baro rate |
| d | **Throws OFF** | `detectThrows:false` | phantom "throws" from strong hand movement in slow moments (LOG3 → 6.7 m) | the ballistic path is a TESTING AID; use `DEFAULT_V8_THROW_PARAMS` for the Hoolan throw log only |
| e | **Confidence floor** | `minConfidence:0.6` | bare baro-bumps with no corroboration | confidence aggregates ALL signals (speed/height/pop/support/airborne/bar-pull) → a real jump clears it with margin |
| f | **Capped high-percentile baseline** | pctile 0.6, cap 0.4 hPa | small-jump UNDER-read (accuracy) + dirty-baro phantom | "sea level = high-pressure mode" (rider on water ~90 %), but ≤ median+0.4 hPa so a wide dirty spread can't inflate it |
| g | **Run-up speed gate** | ≥5 m/s | standing/drifting artefacts | a kite jump launches while planing |
| h | **Height gate** | ≥1.5 m | small swells / chop | matches Surfr's display threshold |

### Deliberately NOT hard gates (lessons learned)
- **Rotation / tumble** — kite tricks (board-offs, spins, handle-passes) rotate
  hard; a gyro reject drops real trick jumps.
- **Airborne calm-window as a HARD gate** — a trick moves the hand so the airborne
  phase isn't quiet; proven to drop the real 3.17 m jump (RMS 0.58→1.70). It feeds
  *confidence* only.
- **`minSupport` & `arcShapeMinCorr`** — implemented but **default 0 (off)**: they
  need a WELL-SAMPLED arc (**≥1 Hz baro**); at today's ~0.34 Hz they drop real
  jumps with an isolated sparse apex (LOG2 913 s, conf 1.00). **Enable when the
  watch records baro ≥1 Hz** (see `NEXT_LOG_RECORDING_SPEC.md`).

---

## 4. The insights (the discovery story — read this to avoid re-learning it)

1. **Height must come from the barometer.** On the biggest LOG2 jump (3.37 m) the
   physics needs a take-off vertical velocity of 8.13 m/s, but the wrist IMU's net
   upward impulse to the apex integrates to **0.02 m/s** (chop swamps it). The
   baro's own rise rate is **8.87 m/s** — the physics. So: HEIGHT from baro, IMU
   only to detect/bracket.

2. **The throw path was the worst noise on a real session.** On LOG3 the ballistic
   throw detector fired on **strong hand movements during slow moments** (spd<3) →
   phantom **6.7 m "throws"**. De-spiking baro never touched them (throws are
   baro-free). Fix: throws OFF for real sessions.

3. **Garbage baro inflates the baseline LOCALLY.** LOG3 had bursts to 1046–1070 hPa
   (frozen 3-sample blocks). Although only ~4 % of update points globally, locally
   (±15 s) a burst is >50 % of the sparse update points → the median baseline is
   pulled up → normal pressure on either side reads as +50 m → phantom jumps. Fix:
   one-sided upward de-spike (§3a) **before** the baseline.

4. **The parabola explodes on near-collinear sparse triples.** A flat 0.5 m bump
   was refined to 6.7 m because the unbounded vertex offset `d = 0.5(y0−y2)/den`
   blows up as `den→0`. Fix: concave-only + \|d\|≤0.5 (§3b).

5. **"Sea level" is the high-pressure MODE, not the median.** The rider is airborne
   a small fraction of any window, which pulls the median DOWN, so the median
   under-reads small jumps. A 0.6 percentile (capped) fixed it: **LOG2 top-4 RMS
   0.579 → 0.169 m**. The cap (§3f) stops a wide dirty-baro spread from turning the
   higher percentile into a phantom.

6. **Unsynced reference logs only calibrate by the BIG jump.** Both Surfr logs ran
   on a *separate, unsynced* watch. LOG2's biggest jump anchors the height scale
   (V8 3.82 vs Surfr 3.77). LOG3's jump TIMES don't align at all (my detections
   2244–2851 s vs Surfr 1078–2477 s) and the jump sets are likely **disjoint** →
   **LOG2 is the calibration anchor; LOG3 is only a phantom-safety check.** Do not
   over-fit to LOG3's rank-matched heights.

7. **At ~0.34 Hz baro, small jumps are near the noise floor.** Surfr's 1.26–2.49 m
   LOG3 jumps show only 0.03–0.13 hPa dips (≈0.3–1.1 m by the conversion). The real
   accuracy unlock — and `minSupport`/`arcShape` activation — needs **≥1 Hz baro**.

---

## 5. Validation (always run this — `core/tools/validate_v9.ts`)

`node --experimental-strip-types core/tools/validate_v9.ts` runs **both goldens**,
**V8 whole-log + V9 watch-scan side-by-side**. Every detection change MUST pass it.

| log | what | result |
|---|---|---|
| **LOG2** `4173200D` (Surfr, top-4 3.77/3.45/3.17/3.14) | clean real kite session, anchor | **top-4 height RMS 0.169 m**; V9 tracks V8 (±1 marginal) |
| **LOG3** `E04B8F70` (Surfr, 9 jumps 1.26–2.49) | small jumps + garbage baro, safety | **0 throws, no ≥5 m phantom** (was 6.7–7.5 m); max ~4 m |
| **Hoolan** `00DC2259` | watch-throw test (`DEFAULT_V8_THROW_PARAMS`) | 6 throws detected, 0 kite pollution |

Unit tests: `jumpEngineV8.test.ts` (7) + `jumpScanV9.test.ts` (5), all green —
includes the de-spike (garbage→no phantom) and the V9 ripeness/dedup/eviction.

---

## 6. Full parameter reference (`DEFAULT_V8_PARAMS` + `DEFAULT_SCAN_CONFIG`)

**Scan (V9, `jumpScanV9.ts`):**

| param | value | role |
|---|---|---|
| `tickSec` | 5 | scan cadence |
| `windowSec` | 75 | look-back window (and memory bound); ≥ settle+2·baseHalf+maxArc |
| `settleSec` | 16 | finalize only this long after landing; ≥ baselineHalfWinSec |
| `dedupTolSec` | 3 | same-jump apex tolerance; ≥ sparse-baro spacing |

**Engine (V8, `jumpEngineV8.ts`) — the noteworthy ones:**

| param | value | role |
|---|---|---|
| `baselinePctile` | 0.6 | sea-level = high-pressure mode |
| `baselineMaxOffsetHpa` | 0.4 | cap baseline at median+this (dirty-baro safety); 0=off |
| `baselineHalfWinSec` | 15 | ± baseline window |
| `minJumpHeightM` | 1.5 | height gate |
| `minMeasuredAirSec` | 1.5 | take-off→landing floor |
| `baroDespikeWinSec` / `baroDespikeHpa` | 10 / 1.0 | upward de-spike |
| `minConfidence` | 0.6 | composite noise floor |
| `jumpRunUpSpeed` | 5.0 | planing gate |
| `kiteGlideFactor` | 2.63 | height→airtime |
| `maxPlausibleHeightM` | 50 | Big-Air cap (world record ~45 m) |
| `minSupport` / `arcShapeMinCorr` | 0 / 0 | **off until ≥1 Hz baro** |
| `detectThrows` | false | throw path (testing aid) |

---

## 7. Swift port — what to do

1. **Files (line-for-line):** `KitesurfJumpEngineV8.swift` (engine + filters) and
   `KitesurfJumpEngineV9.swift` (`JumpScannerV9` — the scan loop wrapping
   `KitesurfJumpEngineV8.detectJumps`). Both are already written and kept in sync
   with the TS; **verify against the TS, don't diverge**.
2. **Wire CoreMotion → `V8Sample`** (CMDeviceMotion + CMAltimeter + CLLocation;
   mapping in `ALGORITHM_V8_HEBREW.md §6`). Keep raw per-stream timestamps.
3. **Drive it:** `addSample(s)` on every sample; a `Timer` every `tickSec` calls
   `scan(now)` → push the returned jumps to the HUD/haptics; `flush(now)` once at
   session end.
4. **Replicate the unit tests** as Swift unit tests.
5. **Record the next log at ≥1 Hz baro** (`NEXT_LOG_RECORDING_SPEC.md`) → then
   enable `minSupport`/`arcShapeMinCorr` and expect ≤0.2 m on small jumps too.

### Documents to hand over (read in order)
`ALGORITHM_V9.md` (this) → `ALGORITHM_V8_HEBREW.md` (physics + sensor mapping) →
`HANDOVER_TO_SWIFT_TEAM.md` (index + per-log results) → `NEXT_LOG_RECORDING_SPEC.md`
(≥1 Hz baro) → `SENSOR_RESEARCH_S9_ULTRA.md` → `TESTING_AND_VALIDATION.md`.

---

## 8. Latency & the Reconstruction Engine (the ≤5 s question)

The product wants the height **within ~5 s of landing**, with future measurements
improving the estimate. The architecture for this is the **Vertical Trajectory
Reconstruction Engine** (`core/trajectoryV9.ts`): a batch MAP / smoothing-spline
on the vertical channel over the jump event, with **ZUPT endpoint anchors** (z=0,
v=0 at take-off & landing — the watch is on the water), baro as the position
anchor, accel as a soft shape/curvature term, and **acceptance by physical
trajectory consistency** (coherent hump, interior apex, returns to 0), not
thresholds. This is the right framework and is implemented.

⚠️ **EMPIRICAL FINDING — ≤5 s accurate is currently blocked by the 0.34 Hz baro.**
We tested it exhaustively on the Surfr golden (LOG2):

| baseline | latency | top-4 RMS |
|---|---|---|
| symmetric ±15 s | ~16 s | **0.17 m** |
| past-only / endpoint anchors (≤5 s) | ≤5 s | **0.5–1.2 m** |

The accurate "sea level" needs **symmetric averaging** (~12 baro samples = ±15 s at
0.34 Hz). Past-only / endpoint baselines are too noisy/biased; the accel cannot
substitute (the vertical RISE is not in the wrist accel). DETECTION also lags (it
needs ~3 baro samples to see the arc). So at 0.34 Hz, a robust jump cannot be both
detected and accurately measured in ≤5 s — **the barometer rate is the wall.**

**What V9 delivers today:** an accurate FINAL (0.17 m) at ~16 s, and a rough
PROVISIONAL (~0.3–0.5 m) at ~8–10 s for the live HUD (provisional→final, same id;
§ jumpScanV9). The FINAL is the canonical session result.

**The real ≤5 s unlock = a faster barometer.** It is a HARDWARE limit (Apple Watch
CMAltimeter delivers a new value only every ~2.6 s, fixed cadence — not a firmware
knob; min gap 2.16 s, never faster). With a baro ≥ a few Hz, the symmetric window
shrinks to ~3 s → the SAME reconstruction engine gives ≤5 s WITH full accuracy, and
the `support`/`arcShape` shape filters activate. This is the #1 ask to the watch /
sensor side.

### 8.1 Pushing the ≤5 s number — what was tried (and the wall)
The fast number is NOT 0.5 m — it is ~0.21 m. The baseline window is ASYMMETRIC
(`baselineFutureWinSec`): a short future side (5 s, ready ≤5 s) gives LOG2 top-4
**RMS 0.211** vs the symmetric 0.169. The provisional uses the short future, the
final the symmetric. Tested but REJECTED: drift-detrend (hurt: 0.21→0.86); a pure
PAST-only baseline (lags the pressure drift → RMS 1.2 + over-detection).

**Sensor fusion CANNOT improve the height — proven 3 ways.** The wrist accel has no
usable vertical-position information: double-integrating it over each jump gives
0–4.85 m, completely UNCORRELATED with the baro height (a 1.9 m jump → 0.0 m, a
1.68 m jump → 4.85 m); the integrated take-off velocity is 0.7–5 m/s vs the 5.5–9 m/s
the physics needs. The watch moves with the arm/kite, not ballistically. So the BARO
is the only height source; accel/gyro/GPS help only TIMING and ROBUSTNESS (rejecting
false jumps), never the height value. ≤5 s height accuracy is baro-rate-bound, full
stop.

## 9. Other open items
- **Baro DRIFT is the dominant residual error — see §10.** No software fix works
  (exhaustively disproven on both goldens); even a baro⊕GPS complementary filter fails
  (consumer GNSS ±3–5 m vertical is too coarse). Read §10 before attempting any
  baseline/drift/filter/GPS-fusion change.
- **Small-jump accuracy at ~0.34 Hz baro** is capped (sub-Nyquist apex). ≥ a few Hz
  baro unlocks both the accuracy and the `support`/`arcShape` filters.
- **V9 vs V8 may differ by ±1 marginal jump** on noisy data (borderline detections
  near the 1.5 m gate). The matched jumps' heights agree; only the marginal count.
- **LOG3 rank-comparison is unreliable** (unsynced, disjoint jump sets). Get a
  **time-synced** reference log for true per-jump validation.
- **Swift port is SYNCED**: `KitesurfJumpEngineV8.swift` (engine + filters),
  `KitesurfJumpEngineV9.swift` (provisional→final `JumpScannerV9`),
  `TrajectoryV9.swift` (reconstruction engine) — line-for-line with the TS. The
  dashboard runs the TS; the watch runs the Swift; they are now equivalent.

---

## 10. Baro DRIFT — the dominant residual error (and why software can't remove it)

The single largest error left in the engine is a slow **barometric pressure drift**
(weather/gust/sensor) that the ±15 s baseline can't track, so the drift is counted as
altitude and **inflates the jump height**. This was traced from the dashboard down into
the core `jumpEngineV8` output — it is a **real algorithm error, not a display artifact**.

**Evidence.**
- LOG2 jump #8: raw baro drops **0.51 hPa over ~12 s** → engine reports **4.06 m** vs
  Surfr golden **3.77 m** (Δ **+0.29**) — this is the single **largest error in the
  whole log** (half the 0.169 RMS budget).
- LOG3 is drift-DOMINATED: engine top jumps **4.13 / 3.63** vs golden **2.49 / 2.16**
  → rank-RMS **1.30**.
- Symptoms of a drift-contaminated jump: apex lands **5–8 s** after take-off (grabs the
  drift low, not the real bump), landing detection **times out** (baro never returns to
  0 → `landingTimeMs` hit a fixed 12.84 s cap), and the rise/fall split falls back to the
  40/60 default.

**The drift ALSO breaks the cross-validation signals.** With the arc window bloated by
the timeout, `airborneConfirmed` (arc-chop < 0.85·run-up-chop) fires for only **2 of 11**
jumps on LOG2, and `measuredAirtime`/return-to-0 likewise. So the confirmations can't be
used as hard filters — they'd drop real jumps.

**Every software fix was tried and measured on BOTH goldens — all failed the same way:**

| Approach | LOG3 (drift-heavy) | LOG2 (mostly clean) |
|---|---|---|
| Cross-validation hard gate (`requireCrossValidation`) | — | drops **5 of 9 REAL** jumps (signals are watch-specific — `barPullMinG`/`chopRatio` don't fire on LOG3) |
| Global baseline de-trend (`baselineDetrendWinSec`, robust line on the on-water envelope) | improves | **hurts** (0.169→0.34+), **drops jumps** (10→5), doesn't even fix #8 |
| Shorter baseline window (±8–12 s) | improves (1.30→0.63) | **hurts** (0.169→0.23), drops jumps |
| Per-jump LOCAL water-line (take-off→landing interpolation) | improves (1.30→0.51) | **collapses** (0.169→1.69; clean heights fall to 1.4–1.5 m) |

**Why they all fail:** LOG3 is drift-dominated (correction helps) but **LOG2 is mostly
clean** — any correction strong enough to remove #8's drift also strips real height from
the clean jumps. The over-read is **entangled** with genuine signal; there is no global
knob that improves both.

**No signal (or combination) separates real from phantom either.** Checked pop, run-up
speed, max speed, confidence, airborne, bar-pull, arc shape, return-to-0 — the REAL-4 and
the other 7 distributions **fully overlap** (e.g. real #2 has pop 0.00 + 14 km/h run-up,
identical to a suspected phantom). At the wrist, under drift, the boundary isn't observable.

**Conclusion (governing).** The engine is already at the sensor's theoretical floor on a
clean log (**LOG2 RMS 0.169 m ≈ ±17 cm**). The residual is **baro sensor noise (drift +
0.34 Hz sub-sampling)** that cannot be removed in software without extra ground truth. The
only real ROI is **hardware: a ≥1 Hz barometer** — it fixes the drift, the apex
sub-sampling, AND revives the `support`/`arcShape`/airborne filters simultaneously (see
`NEXT_LOG_RECORDING_SPEC.md`). Do **not** re-attempt a global drift-correction; it has been
exhaustively disproven on the goldens.

**GPS as the drift-free reference — designed, implemented, and DISPROVEN on synthetic.**
The logs record only scalar **horizontal speed** at 1 Hz (`lat`/`lng`/GPS-altitude/
vertical-velocity are **0 %** in every log — the KSLOG/KLOG wire format doesn't carry
them). A GPS **altitude** is drift-free, so the classic fix is a baro⊕GPS **complementary
filter** — keep the baro's HIGH freq (the jump), take the LOW freq (sea level / drift)
from GPS: `driftCorr = LPF(alt_baro − gps_rel)`, subtract it. This is implemented
(`gpsFusion`, `gpsCrossWinSec`, `gpsTideWinSec`; types `gpsAlt`/`gpsVertVel`), auto-gated
on GPS-altitude presence so baro-only logs are byte-identical.

**It does not work, for two structural reasons (tested by injecting a synthetic drift-free
GPS altitude into LOG2):**
1. **The drift that matters masquerades as "airborne."** A drift big enough to inflate #8
   (≈4 m) pushes the on-water altitude *above* the on-water threshold, so the on-water
   mask (needed to keep real jumps out of the drift estimate) has **no reference in the
   drift region** → #8 stays 4.06 m, unfixed. Dropping the mask instead makes the LPF
   **subtract real jumps** (jump 4 s vs drift 12 s are only ~3× apart in timescale — a
   single low-pass can't separate them).
2. **Consumer GPS altitude noise (±3–5 m) ≫ the ±0.2 m target.** Denoising GPS to 0.2 m
   needs ~5 min of averaging — 25× the 12 s drift — which smears the drift away entirely.
   At ±5 m the filter injects phantoms (10→17 jumps on the synthetic test).

**Conclusion:** consumer GNSS (even Ultra 2 dual-band) is **insufficient** to correct this
fast drift. Only a **cm-level vertical** reference (RTK / carrier-phase GPS) or a
body-mounted high-grade sensor could. The scaffolding is kept, **OFF**, for that day. Do
not enable `gpsFusion` on a consumer-GPS log — it is net-negative (disproven above).

**Params left in place but OFF** (`= 0`/`false` in `DEFAULT_V8_PARAMS`), for the day a
better sensor makes them reliable: `requireCrossValidation`, `baselineDetrendWinSec`,
`gpsFusion` (+ `gpsVertVelMinMs` for the vertical-velocity phantom gate).

**What DID work — a frame-independent drift cross-check (`specForceQuieting`).** A real
kite jump is a SUPPORTED float (`|specific force| ≈ 1.2 g`, and QUIETER than on-water —
`|a|` std drops), whereas a baro-drift artifact has no real float (its "flight" is just
on-water motion, `|a|` std unchanged). The ratio **|a|-std-in-flight ÷ |a|-std-on-water**
separates them: clean jumps **0.55–0.76**, drift-inflated ones **1.1–1.8** — and it flags
the LOG2 #8 over-read (0.55/0.76 clean vs 1.18 for #8). Crucially `|a|` is the specific-
force MAGNITUDE, so it is **rotation-invariant** — unlike the projected airborne-chop it
has no attitude artifact and is **watch-independent** (the trap that killed
`requireCrossValidation`). Grounded in the standard baro⊕inertial vertical-channel fusion
(Sabatini & Genovese, height RMSE 5–68 cm). It is a **cross-check / confidence** signal,
NOT a gate (never drops a plausible jump — per the philosophy above); computed on every
`JumpResultV8`. This is the physically-correct reason kite ≠ ballistic: kite jumps are
kite-SUPPORTED (`|a|≈1.2 g`), not free-fall (`|a|=0 g`) — so airtime alone under-determines
height, and `|a|` measures the support that a pure time-of-flight model is missing.

**Philosophy for any future filter (user-stated):** *prefer a plausible false positive
over a miss.* Never add a hard gate that can drop a real jump — the cross-validation gate
above is the cautionary example (it nuked 5 real LOG3 jumps).
