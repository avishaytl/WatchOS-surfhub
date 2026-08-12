//
//  JumpEngineV16.swift
//  SurfHubWatch
//
//  V16.1 — big-air-first jump engine. Swift twin of core/jumpEngineV16.ts; the
//  two must stay behaviourally identical (same replay, same numbers).
//
//  V16 abandons the barometer as a height source and reconstructs the vertical
//  channel from the IMU alone. Every decision below is backed by a measurement
//  on log 287 (14 Surfr goldens, 2.1–8.5 m) and a negative-control session
//  (693 s of pops and waves containing ZERO real jumps):
//
//   1. TRIGGER — a pop >= popMinG. Big-air takeoffs are NOT violent: the
//      goldens measured 1.4–4.7 g, so V15's 3.0 g floor discarded half of them.
//
//   2. CONFIRM — the LIFT PLATEAU. During a kite jump the canopy pulls the
//      rider up for a full second or more and world-vertical acceleration
//      stays positive in a sustained shelf. A wave or chop bump is an impulse
//      that is over within 0.6 s. Measured: real jumps 0.9–2.8 s of shelf,
//      control session max 0.6 s across 19 pops. At the 0.9 s threshold this
//      one test keeps 14/14 real jumps and admits 0/19 control pops — the
//      phantom firewall, no GPS needed.
//
//   3. HEIGHT — bounded double integration of world-vertical acceleration over
//      a FIXED window around the pop, with z(0)=z(T)=0. The apex is then a
//      LINEAR FUNCTIONAL of the acceleration with support T, and two jumps
//      compare only if the SAME functional is applied — i.e. the same T. With
//      a per-jump window (even the TRUE airtime) each jump gets a different
//      operator and the correlation collapses to r~0; with the fixed window
//      it is r=0.95. This is a matched filter, not a
//      trajectory reconstruction, and its output is mapped to metres by a
//      linear calibration. Validated: MAE 0.52 m over all 14 goldens spanning
//      2.1–8.5 m (LOO 0.57 m on the 12-jump subset it was fitted on); adding
//      the two largest goldens did not move the slope.
//
//   4. AIRTIME — LOW CONFIDENCE, and the second reference makes that stronger,
//      not weaker. Leave-one-out against each reference:
//
//                                 287 (HOOLAN)   GAVRI (Surfr)
//        constant (median)           1.000 s        0.412 s
//        OUR measured airtime        0.464 s        1.001 s  <- loses on GAVRI
//        ballistic from our height   0.275 s        0.483 s
//
//      The two sessions pick OPPOSITE best predictors, so there is no
//      cross-validated improvement available — the optimal shrink toward the
//      constant is a=0.80 on one and a=0.05 on the other. Do not ship a blend;
//      that is the trap V15 fell into, where a 0.75-weight shrink toward a
//      3.4 s prior looked like accuracy and was a constant.
//
//      The references are not equivalent, which explains the split: HOOLAN's
//      airtime is r=0.952 with HOOLAN's own HEIGHT — very nearly derived from
//      it. Surfr's is r=0.540, i.e. it carries real independent information,
//      and ours correlates r=0.062 with it — none at all. Our spread on GAVRI
//      is 1.15 s sd against their 0.53 s, so on small and mid jumps this rule
//      contributes variance rather than signal.
//
//      What that does NOT license: rewriting the landing rule. Every
//      alternative was measured on both references and all are worse — impact
//      peak, first |sf| crossing, gyro settle and impact-then-settle all fire
//      1.4-3.6 s EARLY, because a kite landing is soft and has no touchdown
//      spike. A 2-D sweep of landDipMS2 x landDipMinSec finds no better joint
//      operating point (the GAVRI-favouring corner costs 0.292 -> 0.331 m
//      pooled height). Never gate on `airtimeSec`.
//
//   5. DISTANCE — derived, so it INHERITS the airtime error: haversine between
//      the GPS fix before the pop and the one at the estimated landing. With
//      the true airtime it measures 2.78 m MAE; with V16's own airtime, 6.27 m
//      (0.54 s x ~8 m/s). takeoffSpeedMS by contrast is read straight from GPS
//      before the pop and is accurate to 0.64 m/s.
//
//  NOT used, and why (measured, not assumed):
//   • absoluteAltitude — passes a health gate on only 7/21 goldens and, even
//     when it passes, produced −6.4 m and −2.1 m errors (a negative apex for a
//     real jump = water over the port). Nothing available predicts when it is
//     trustworthy, so fusing it injects metre-scale error into a 0.57 m
//     estimator.
//   • relativeAltitude / raw pressure — alive (71 % distinct, max 5 s freeze)
//     but useless per jump: 67 of the 68 inter-sample steps above 3 m fall
//     OUTSIDE any jump. Noise exceeds signal in the same band, so no filter or
//     drift reset recovers it (measured r = 0.19–0.31).
//
//  SCOPE: V16 is tuned for big air, but the small-jump gap is closed. On the
//  16-golden smallLog session (1.5–3.7 m) recall is 16/16 with 4 phantoms, none
//  above 2.48 m, after the shelf floor moved to 0.7 s with apex corroboration on
//  the short shelves. Do NOT fall back to V15 there: measured on that session,
//  V15's own landing detection is WORSE (raw airtime MAE 0.92 s vs 0.71 s here,
//  and 1.40 s vs 0.34 s on log 287) — its apparent airtime advantage is a 0.75-
//  weight shrink toward a 3.4 s prior, i.e. a constant, not a measurement.
//  Below ~2.5 m the HEIGHT remains a population estimate, not a measurement.
//
//
//  ── V16.4 ────────────────────────────────────────────────────────────────
//  1. FLIGHT CORROBORATION. The short-shelf gate judged a candidate on the
//     FIXED 4.5 s matched-filter window and ran BEFORE the landing was known,
//     so a long flight overflowed it: apex read 0.00-0.19 while the same
//     integral over the FLIGHT window returned metres. It now defers and asks
//     the flight window. CLEAN 3/4 -> 4/4, V142 2/5 -> 4/5, Yaniv 20/24 ->
//     23/24, guarded recall 35/39 -> 38/39, pooled height 0.292 -> 0.282 m,
//     with the control still silent and the tallest phantom still 1.56 m.
//  2. minLiftPlateauSec 0.7 -> 0.6. Identical on six of seven logs; recovers
//     one real jump on Yaniv. Below 0.6 recall is FLAT all the way to 0.3
//     while 287 gains a phantom, so the gate is not what blocks the rest.
//  3. NO FLIGHT WINDOW, NO DISTANCE. An unresolved landing left tEnd at
//     apexPostSec, so the reported span covered 2 s of a 4-5 s flight.
//     smallLog distance 4.96 -> 4.50 m, its correlation 0.456 -> 0.585.
//  4. `confidence` pinned to strongShelfSec (1.05 s) instead of derived from
//     minLiftPlateauSec//  1.5. Equal at a 0.70 s gate, but they answer
//     different questions, and lowering the gate would otherwise relabel the
//     very band the phantom filter treats as suspect.
//  Rejected after measurement: interpolating the GPS distance endpoints (287
//  improves, smallLog worsens, pooled a wash), path length instead of the
//  chord, a global airtime offset, deep unloading as a second detection path,
//  and reduced lift smoothing (it breaks 287 and smallLog).
//
//  ── V16.1 ───────────────────────────────────────────────────────────────
//  Changes since V16.0, each measured before being kept:
//    1. heightOffsetM 1.50 -> 1.43 — refitted on all 23 goldens across three
//       sessions instead of big air alone. Better in BOTH regimes.
//    2. minReportM 1.5 -> 1.4 — the engine's floor output IS 1.43 m, so a
//       1.5 m report floor censored the whole band it can produce.
//    3. LANDING REWRITTEN — landing is now the END of the sustained descent
//       (the water arresting it), not a dip confirmed by sustained "float".
//       The float confirmation never arrived (the arm keeps working the bar)
//       and returned nil on 2 of 19 goldens. Airtime 14/14 at 0.34 s LOO.
//    4. boxSmooth NaN fix — a single empty 0.1 s bin used to poison every
//       later bin, so the lift shelf could never be found again. Latent at
//       200 Hz, LIVE on the watch where a 0.1 s bin holds only 5 samples.
//    5. LATENCY 17.0 -> 7.5 s for jumps >= immediateReportM. The result now
//       lands 0.9-3.9 s after the rider does, instead of 8-12 s after.
//    6. floatLoadG documentation corrected: it measures SETTLED motion, not
//       free fall — |userAcceleration| reads ~1.0 g in free fall, not ~0.
//  Rejected after measurement and recorded so they are not retried: an
//  impulse (area) lift gate, and a GPS takeoff-speed gate (detection must
//  never depend on GPS).
//
//  SAMPLE RATE: the calibration was fitted on 200 Hz logs. MotionSampler runs
//  at 50 Hz; a trapezoidal double integral is insensitive to that, but the
//  calibration should be re-checked if the rate changes.
//
//  INPUT DOMAIN: `loadG` is |userAcceleration| in g (gravity removed, ~0 at
//  rest) — the same quantity MotionSampler already publishes. `accel` is the
//  device-frame userAcceleration in g and `quat` the attitude quaternion;
//  both are required for height. Attitude gaps are tolerated in the wide
//  shelf/landing scan (a gap breaks any lift run through it) but NOT inside the
//  apex window, where the integral cannot bridge a hole.
//

import Foundation

// MARK: - Configuration

public struct V16Config {
    /// Takeoff pop floor (g). Goldens measured 1.4–4.7 g.
    public var popMinG = 1.4
    /// Two pops closer than this are one takeoff; the stronger anchors t0.
    // 0.8, not 2.0. The window governs how far t0 may WALK FORWARD onto a
    // stronger pop, and a take-off's own pop burst measures 0.80 s median across
    // the 14 goldens — 2.0 s was far wider than the thing it merges. On a thrown
    // watch the ordering inverts: the release is 3-6 g and the CATCH is 15-23 g,
    // 0.9-1.7 s later, so the anchor walked onto the landing and the shelf scan
    // then started after the flight was over (the watch's own log: shelf=0.00-0.30 s
    // on a 17 g yank). At 0.8 the anchor stays on the release and all four bench
    // throws are found; the height is protected separately by apexAnchorSec.
    public var popClusterSec: TimeInterval = 0.8

    /// World-vertical acceleration above this counts as lift (m/s²).
    /// A 2-D sweep over threshold x duration on four logs showed duration is
    /// worth ~10x the threshold: dropping az 2.00 -> 1.00 at a fixed 0.8 s
    /// costs almost nothing, while dropping the duration 0.8 -> 0.5 at a fixed
    /// 1.25 opens 12 control false positives. Physics: a wave is a strong SHORT
    /// impulse, so only the sustained shelf separates it from a kite lift.
    public var liftThreshMS2 = 1.25
    /// Half-width of the box smoother applied to the lift signal (s).
    public var liftSmoothSec: TimeInterval = 0.2
    /// The apex window centres on the strongest pop within this much of t0.
    /// 0 pins it to t0 itself. See the DECOUPLED ANCHOR note in evaluate().
    public var apexAnchorSec: TimeInterval = 2.0
    /// V16.2: measure the height by endpoint-anchored integration over the
    /// flight instead of the calibrated matched filter. The filter stays as the
    /// fallback whenever the landing is unresolved.
    public var heightFromFlight = true
    /// |specific force| below this counts as FREE FALL (g). 1.0 = at rest.
    /// Free fall is the ONLY exactly-correct integration window and it is
    /// directly measurable — both edges are sharp to one sample. Threshold-
    /// insensitive: the bench log gives the identical answer anywhere from 0.15
    /// to 0.50 g. It never fires while riding (0 runs in 187 minutes across
    /// every riding and control log) because a rider hangs from the canopy and
    /// is never unloaded, so it can only replace the window on a truly
    /// ballistic event.
    public var freeFallG = 0.25
    /// Free fall must last this long to redefine the integration window.
    public var minFreeFallSec: TimeInterval = 0.45
    /// Multiplier applied to the height of a FREE-FALL (ballistic) event only.
    ///
    /// 1.0 reports the PEAK above the release point — what g*T^2/8 means and what
    /// the integral measures: bench 2.50 / 1.55 / 2.97 / 0.91 m against a
    /// ballistic truth of 2.48 / 1.54 / 3.00 / 0.91 m.
    ///
    /// 2.0 reports the TOTAL VERTICAL PATH (up + down), i.e. g*T^2/4. A different
    /// quantity, not a correction — 1.42 s of measured free fall IS 2.47 m of
    /// peak, and 5 m would require 2.02 s. Offered because the reference app
    /// reports roughly this: doubling matches HOOLAN's 6.0 / 2.4 / 5.1 / 1.6 m to
    /// 0.69 m MAE with no fitted parameter.
    ///
    /// CAUTION: a kite jump reports the APEX and matches HOOLAN at 0.42 m, so 2.0
    /// makes the app use two different definitions of "height" depending on the
    /// event. HOOLAN are themselves inconsistent this way (h/T^2 measures 0.21 on
    /// kite jumps and 0.618 on throws). Default 1.0 keeps one definition.
    public var throwHeightScale = 1.0
    /// The phantom firewall: required continuous lift shelf (s).
    /// 1.25 / 0.8 dominates the previous 1.5 / 0.9 — recall 17/23 -> 19/23 with
    /// the same single true phantom and still ZERO control false positives.
    // 0.7 is the FLOOR, not the bar. The four goldens smallLog used to miss
    // carry shelves of 0.7/0.7/0.6/0.8 s; the old 0.8 rejected all four.
    // Shelves in [0.7, shelfFullSec) must clear shortShelfApexM to be admitted.
    public var minLiftPlateauSec: TimeInterval = 0.6
    /// A shelf at or above this is accepted on its own, with no corroboration.
    public var shelfFullSec: TimeInterval = 0.8
    /// A shelf between minLiftPlateauSec and shelfFullSec needs apex >= this.
    public var shortShelfApexM = 0.30
    /// How far past the pop the shelf is searched for (s).
    public var plateauScanSec: TimeInterval = 7.0

    /// Fixed apex window before/after the pop (s). Do NOT tune without
    /// re-fitting heightScale/heightOffsetM — the calibration is tied to it.
    ///
    /// "apex" is a NAME, not a trajectory apex. Measured on all 14 log-287
    /// goldens, the argmax of the bounded double integral falls at t0-1.15 s
    /// to t0+0.01 s — at or BEFORE the pop, on every jump, big or small. The
    /// operator reports a curvature contrast over a fixed support that happens
    /// to correlate with height (r=0.95), not the height of the flight.
    ///
    /// So the intuition that a bigger jump needs a longer window is wrong
    /// twice over: the window never contained the physical apex, and
    /// lengthening it is measurably worse. Swept on the engine with the
    /// calibration refitted per window, MAE over 19 goldens:
    ///   [-2.5,+2.0] 0.427 m  <- shipped
    ///   [-2.5,+2.5] 0.895 m
    ///   [-2.5,+3.0] 0.984 m
    ///   [-2.5,+3.5] 1.461 m
    ///
    /// NOTE the calibration is fitted over 2.1-8.5 m. Beyond that it is pure
    /// extrapolation of a correlate; a 20 m+ jump cannot be trusted without a
    /// raw log to calibrate against.
    public var apexPreSec: TimeInterval = 2.5
    public var apexPostSec: TimeInterval = 2.0
    /// height = heightScale * apex + heightOffsetM
    /// Fitted on all 23 goldens across three sessions (2.1-8.5 m big air plus
    /// 1.26-2.48 m small jumps), not on big air alone: the combined fit is
    /// better in BOTH regimes (big-air MAE 0.53 -> 0.52 m, small-jump 0.34 ->
    /// 0.29 m, overall 0.45 -> 0.43 m, LOO 0.47 m over all 23).
    public var heightScale = 1.91
    public var heightOffsetM = 1.43

    /// Jumps below this are not reported (m).
    /// 1.4, not 1.5: with heightOffsetM = 1.43 the engine's floor output is
    /// 1.43 m, so a 1.5 m report floor censored the entire saturated
    /// small-jump band. Over the 23 goldens, 1.5 -> 1.4 recalls one more real
    /// jump (18/23 -> 19/23), lowers MAE 0.44 -> 0.43 m and still emits
    /// NOTHING on the pops-and-waves control. Lower does nothing: 1.43 m is
    /// the smallest height the calibration can produce.
    // 1.2. The old 1.4 existed because the MATCHED FILTER could not output below
    // heightOffsetM = 1.43 m, so anything lower was structurally unreachable. The
    // V16.2 flight integral has no such floor — it returns what it measures — so
    // this is now a pure DISPLAY threshold. Swept on all six logs: 1.2 recovers
    // two real goldens the 1.4 floor censored (287 @282 s measures 1.39 m against
    // a 2.3 m reference) at no extra phantom. Below 1.1 the phantoms climb.
    public var minReportM = 1.2
    /// Emissions closer than this are the same jump; the higher wins.
    /// Window in which a later, stronger candidate may still supersede an
    /// earlier one.
    ///
    /// This is NOT about the several pops of a single takeoff — popClusterSec
    /// already merges those, and a takeoff's pop burst measures 0.80 s median
    /// across the 14 goldens. This window is about a weak candidate that clears
    /// the whole lift gate on its own shortly BEFORE the real jump.
    ///
    /// 6.0 s, because the observed precursor gaps cluster at 2.5-3.0 s and
    /// 5.0-5.5 s, and a rider physically cannot land, regain speed and launch
    /// again inside that span — anything there is the same event or noise. A
    /// shorter window was tried and the 5 s pairs leaked onto the watch: at
    /// 3.0 s log 287 reported 20 jumps where 14 are real, the extras being a
    /// 1.59 m entry 5.0 s ahead of a 3.63 m jump and a 1.51 m entry 5.1 s
    /// ahead of a 3.78 m one. Both read as nonsense to a rider.
    ///
    /// 6.0 matches 7.0 on every measure (18 emissions, 14/14 goldens, MAE
    /// 0.43 m, control FP 0) and costs 0.5 s on the slowest small jump versus
    /// 3.0. Big air is unaffected — it skips the hold entirely.
    public var dedupSec: TimeInterval = 6.0

    /// A jump at or above this height is delivered the moment it is judged,
    /// skipping the dedup hold (m).
    ///
    /// The hold exists for one reason: a weak precursor pop can be confirmed
    /// before the real takeoff, and only the stronger of the pair may reach
    /// the rider. Over every MERGE the reference logs produce, the precursor
    /// that lost measured 1.43-2.09 m while the winner measured 3.47-7.65 m —
    /// the populations do not overlap. Above ~2.5 m nothing can supersede the
    /// jump, so waiting out dedupSec buys nothing but latency.
    ///
    /// The hold is what put the number on the wrist at t0+14.5 s, some 8-11 s
    /// after the rider was back on the water. Skipping it delivers at t0+7.5 s
    /// — 0.9-3.9 s after every observed landing, with airtime and distance
    /// already resolved, so the emission is complete rather than provisional.
    public var immediateReportM = 2.5
    /// A candidate is judged this long after its pop — covers the shelf scan
    /// and the landing search.
    public var evalDelaySec: TimeInterval = 7.5

    /// The EARLIEST a candidate may be judged (s).
    ///
    /// A small jump is over in a couple of seconds; there is no reason to make
    /// it wait out a budget sized for the longest flight in the session. From
    /// this moment the candidate is judged on every batch and FINALISED as soon
    /// as the answer is knowable — the apex window has closed and the landing
    /// has been found. Otherwise it stays pending and is retried, up to
    /// evalDelaySec. Nothing later can change a verdict reached this way: the
    /// apex window is closed and the shelf gate only ever ACCUMULATES.
    ///
    /// Measured: 14 of the 23 goldens now reach the wrist at the very instant
    /// of landing (0.0 s), against 0.9-3.9 s before and 8-12 s before that.
    public var fastEvalSec: TimeInterval = 3.0

    // Landing / airtime (low confidence — see file header).
    public var landLiftThreshMS2 = 0.5
    public var landMinPlateauSec: TimeInterval = 0.4
    /// World-vertical acceleration below this counts as DESCENT (m/s^2).
    public var landDipMS2 = -0.5
    /// How long the descent must be sustained to count (s).
    public var landDipMinSec: TimeInterval = 0.6
    /// Added to the arrest instant to reach the reported landing (s).
    /// The descent-end bin is where world-vertical acceleration climbs back
    /// above landDipMS2, which precedes full water contact — the rule runs
    /// early by a consistent margin on every reference jump. Fitted as the
    /// MEDIAN residual (the MAE-optimal constant) over the 14 HOOLAN reference
    /// airtimes for log 287, validated leave-one-out: refitted on 13 and scored
    /// on the held-out 14th gives 0.34 s LOO MAE, against 0.50 s raw and 0.75 s
    /// for a constant predictor. One parameter on 14 points.
    public var landOffsetSec: TimeInterval = 0.4
    /// A RESOLVED flight shorter than this is a knock, not a jump. A nil
    /// landing (never resolved) is exempt — it means "not measured".
    public var minAirtimeSec: TimeInterval = 1.5

    /// SECOND-CHANCE landing, used ONLY when the descent-arrest rule returns nil.
    /// Then the specific force settles back to ~1 g and stays there — the rider
    /// is tracking the water again.
    ///
    /// Why it is a fallback and never the primary rule: measured head to head on
    /// both references, descent-arrest wins on airtime (GAVRI 0.93 s / 287
    /// 0.46 s) against settle (1.14 s / 1.08 s). Every impact-based alternative
    /// is far worse and fires 1.4-3.6 s EARLY, because a kite landing is soft —
    /// there is no touchdown spike to find.
    ///
    /// What it is worth: an unresolved landing costs more than a missing
    /// airtime, because it also denies the HEIGHT its flight window and drops it
    /// to the matched-filter fallback. On the 5 GAVRI jumps that never resolved,
    /// height error was 0.77 m and becomes 0.20 m once this window exists —
    /// 0.468 -> 0.401 m over the session. Airtime pays 0.93 -> 1.00 s for it.
    public var landSettleFallback = true
    /// Distance from 1 g that still counts as settled (g).
    public var landSettleBandG = 0.30
    /// How long it must stay inside that band (s).
    public var landSettleMinSec: TimeInterval = 0.4
    /// The fallback is searched over [t0 + from, t0 + to] (s). It starts after
    /// the pop so the take-off's own quiet moment is not mistaken for a landing.
    public var landSettleFromSec: TimeInterval = 1.0
    public var landSettleToSec: TimeInterval = 9.0

    /// PHANTOM FILTER — reject a jump whose FLIGHT SIGNATURE IS INCOMPLETE.
    ///
    /// Two independent weak signs of the same thing, and only their conjunction
    /// fires: the descent-arrest landing never resolved (no clean end to a
    /// sustained descent) AND the lift shelf is short (no sustained canopy
    /// pull). Either alone is common in real jumps; together they say the
    /// take-off was never followed by a kite flight.
    ///
    /// It reads the ARREST rule specifically, not "do we have a landing" —
    /// landSettleFallback usually supplies a measurement window for these very
    /// jumps and that window is still used for the height. "Can we measure it"
    /// and "was it a jump" are separate questions.
    ///
    /// Measured across all six reference logs (78 real jumps, 22 emissions with
    /// no reference counterpart): removes 8, costs ZERO real jumps.
    ///     287      3 phantoms -> 0    (including the suite's tallest, 2.54 m)
    ///     smallLog tallest 2.14 m -> 1.56 m, recall still 16/16
    ///     GAVRI    15 unmatched -> 12
    ///     BENCH / CLEAN / NEG  untouched — a thrown watch is CAUGHT, a 15-23 g
    ///                          deceleration the arrest rule always resolves,
    ///                          so the throws never reach this test.
    ///
    /// The second clause exists to spare ONE real jump: a 2.50 m smallLog
    /// golden at exactly the same 1.10 s shelf as two 1.57/1.59 m phantoms.
    /// Height separates them by 0.9 m; a single shelf threshold cannot express
    /// that and has to sell the golden to buy the phantoms. The zero-cost
    /// region is broad (shelf 1.15-1.25 x height 1.6-2.4 all score 8/0), so
    /// these are not knife-edge constants — but the height bound IS fitted to
    /// one point and should be re-checked when a new session lands.
    public var phantomFilter = true
    /// Shelf below this rejects on its own (given an unresolved arrest).
    public var phantomShelfSec: TimeInterval = 1.05
    /// Shelf at or above which a jump is reported at high confidence (s).
    /// Absolute on purpose — see the note at the `confidence` assignment.
    public var strongShelfSec: TimeInterval = 1.05
    /// How far BEFORE t0 the height integral starts (s). Height window only —
    /// detection, airtime and distance still use t0. See the note at the
    /// pre-roll in evaluate().
    public var heightPreRollSec: TimeInterval = 0.3
    /// Let the FLIGHT window corroborate a short shelf when the fixed apex
    /// window found nothing. See the note at `needsCorroboration`.
    public var flightCorroboration = true
    /// Flight height a short-shelf candidate must reach to survive (m).
    /// Set to minReportM: anything clearing the reporting floor on the flight
    /// window has produced a real vertical excursion, and the phantom filter and
    /// the control session keep the rest out. Swept 1.2-3.0 m on all seven logs
    /// — the negative control stays silent and the tallest phantom stays 1.56 m
    /// at every value, while recall keeps climbing as it drops.
    public var shortShelfFlightM = 1.2
    /// A longer shelf still rejects, but only for a small jump.
    public var phantomShelfWideSec: TimeInterval = 1.20
    public var phantomWideHeightM = 2.0
    /// |a| at or below this counts as SETTLED motion (g).
    /// NOT free fall, despite what this field was originally called. The
    /// stream is |userAcceleration|, which reads ~0 g at REST and ~1.0 g in
    /// true free fall — so a low value means "not being thrown around", not
    /// "airborne". That is still the right test for confirming a landing (the
    /// rider has settled and is tracking the water again), and it is
    /// meaningful in flight too: a kite carries the rider at near-constant
    /// velocity, so a_true stays small. It must NOT be reused as a free-fall
    /// or airborne detector.
    public var floatLoadG = 0.6

    /// Largest tolerated hole between two attitude-carrying samples inside the
    /// apex window (s). Scattered jitter is integrated straight through — the
    /// trapezoid rule handles uneven spacing — but a hole longer than this
    /// cannot be integrated across and rejects the candidate. 0.15 s = 7 missed
    /// samples at the watch's 50 Hz.
    public var maxAttitudeGapSec: TimeInterval = 0.15
    /// Ring horizon (s). Must exceed apexPreSec + evalDelaySec.
    public var historySec: TimeInterval = 14.0

    public init() {}
}

// MARK: - Output

public struct V16Jump {
    /// Calibrated height (m).
    public let heightM: Double
    /// Raw matched-filter apex before calibration (m) — diagnostics only.
    public let apexRawM: Double
    /// LOW CONFIDENCE (see header). nil when the landing was never resolved.
    public let airtimeSec: Double?
    public let takeoffT: TimeInterval
    /// Measured lift-shelf length (s) — the confirmation statistic.
    public let liftPlateauSec: Double
    public let yankG: Double
    public let peakG: Double
    public let floatFraction: Double
    public let maxGyroRadS: Double
    public let takeoffSpeedMS: Double?
    public let distanceM: Double?
    /// 0.75 with a strong shelf, 0.55 at the threshold.
    public let confidence: Double
}

public protocol JumpEngineV16Delegate: AnyObject {
    func jumpDetected(_ jump: V16Jump)
}

// MARK: - Engine

public final class JumpEngineV16 {
    /// Engine version. Bump whenever a default or a rule changes, so a replay
    /// can be attributed to the exact engine that produced it.
    public static let version = "16.5"


    public weak var delegate: JumpEngineV16Delegate?
    /// Diagnostics sink. Keep it cheap — it is called on the sampling queue.
    public var onDebug: (TimeInterval, String) -> Void = { _, _ in }

    private let cfg: V16Config
    private let g0 = 9.80665

    private struct Sample {
        let t: TimeInterval
        let load: Double
        /// World-vertical acceleration (m/s²); .nan when attitude was absent.
        let az: Double
        let gyro: Double
    }
    private struct GpsPt {
        let t: TimeInterval
        let lat: Double
        let lng: Double
        let spd: Double
    }
    private struct Candidate {
        var t0: TimeInterval
        var yankG: Double
    }

    private var ring: [Sample] = []
    private var ringHead = 0            // index of the first live element
    private var gpsHistory: [GpsPt] = []
    private var pending: [Candidate] = []
    private var lastImuT: TimeInterval = -.infinity
    private var lastGpsT: TimeInterval = -.infinity

    /// A confirmed jump is HELD before delivery: one takeoff raises several
    /// pops (a weak precursor, then the real load) and only the strongest may
    /// reach the consumer. Emitting immediately and "superseding" afterwards
    /// would deliver both.
    private var held: (jump: V16Jump, until: TimeInterval)?
    /// The last jump actually delivered, so a weaker straggler inside dedupSec
    /// can be dropped — delivery is irreversible, unlike a hold.
    private var lastEmit: (t0: TimeInterval, heightM: Double)?

    public init(_ cfg: V16Config = V16Config()) {
        self.cfg = cfg
        ring.reserveCapacity(4096)
        gpsHistory.reserveCapacity(256)
    }

    // MARK: Inputs

    /// - Parameters:
    ///   - loadG: |userAcceleration| in g (gravity removed).
    ///   - accel: device-frame userAcceleration in g — required for height.
    ///   - quat:  attitude quaternion (w, x, y, z) — required for height.
    public func addIMU(t: TimeInterval,
                       loadG: Double,
                       gyroRadS: Double = 0,
                       accel: (x: Double, y: Double, z: Double)? = nil,
                       quat: (w: Double, x: Double, y: Double, z: Double)? = nil) {
        guard t.isFinite, loadG.isFinite, t > lastImuT else { return }
        lastImuT = t

        let load = abs(loadG)
        var az = Double.nan
        if let accel, let quat {
            az = g0 * Self.worldZ(quat, accel.x, accel.y, accel.z)
        }
        ring.append(Sample(t: t, load: load, az: az, gyro: gyroRadS.isFinite ? gyroRadS : 0))
        trimRing(before: t - cfg.historySec)

        // Pop clustering: the strongest sample inside popClusterSec anchors t0.
        if load >= cfg.popMinG {
            if var last = pending.last, t - last.t0 < cfg.popClusterSec {
                if load > last.yankG {
                    last.t0 = t
                    last.yankG = load
                    pending[pending.count - 1] = last
                }
            } else {
                pending.append(Candidate(t0: t, yankG: load))
            }
        }

        // Judge candidates whose evaluation window has fully arrived. A pop may
        // have moved t0 forward while clustering, so re-check before removing.
        // Judge the oldest candidates from fastEvalSec onward. evaluate()
        // reports whether it could finalise; if not the candidate stays pending
        // and is retried, until evalDelaySec makes the verdict forced.
        while let first = pending.first, t - first.t0 >= cfg.fastEvalSec {
            let forced = t - first.t0 >= cfg.evalDelaySec
            if !evaluate(first, now: t, forced: forced) && !forced { break }
            pending.removeFirst()
        }

        releaseHeld(now: t)
    }

    public func addGPS(t: TimeInterval, lat: Double, lng: Double, speedMS: Double) {
        guard t.isFinite, t > lastGpsT else { return }
        lastGpsT = t
        gpsHistory.append(GpsPt(t: t, lat: lat, lng: lng, spd: max(0, speedMS)))
        while let f = gpsHistory.first, f.t < t - 120 { gpsHistory.removeFirst() }
    }

    /// Session end: judge everything still pending and release the held jump.
    public func flush(now: TimeInterval) {
        // `pending` stays populated across the loop, exactly as in the TS twin:
        // holdUntil() scans it for rivals, so clearing it first would make the
        // two engines compute different hold deadlines. The deadlines cannot
        // change the OUTPUT here — releaseHeld(.infinity) below ignores them —
        // but the twins are compared on their debug streams too.
        for c in pending { evaluate(c, now: now) }
        pending.removeAll(keepingCapacity: true)
        releaseHeld(now: .infinity)
    }

    // MARK: Ring maintenance

    /// Amortised O(1) eviction: advance a head index and compact only when the
    /// dead prefix grows large, so a 50 Hz feed never memmoves per sample.
    private func trimRing(before cutoff: TimeInterval) {
        while ringHead < ring.count, ring[ringHead].t < cutoff { ringHead += 1 }
        if ringHead > 2048 {
            ring.removeFirst(ringHead)
            ringHead = 0
        }
    }

    // MARK: Evaluation

    /// Judge a candidate. Returns false when the answer is not knowable yet
    /// and the caller should retry later; `forced` makes the verdict final.
    @discardableResult
    private func evaluate(_ c: Candidate, now: TimeInterval, forced: Bool = true) -> Bool {
        let t0 = c.t0

        // 1. Lift shelf — the phantom firewall.
        guard let bins = liftBins(from: t0 - cfg.apexPreSec, to: t0 + cfg.plateauScanSec) else {
            onDebug(now, "REJECT t0=\(fmt(t0)) reason=noAttitude")
            return true
        }
        let shelf = Self.longestRun(bins.az, bins.t, from: t0, above: cfg.liftThreshMS2)
        guard shelf >= cfg.minLiftPlateauSec else {
            // the shelf only ever ACCUMULATES, so it may still qualify later
            if !forced { return false }
            onDebug(now, "REJECT t0=\(fmt(t0)) reason=noLiftPlateau shelf=\(fmt(shelf))s yank=\(fmt(c.yankG))g")
            return true
        }

        // 2. Height from the fixed-support matched filter.
        // DECOUPLED ANCHOR. t0 marks the TAKE-OFF — that is what airtime and the
        // shelf scan need, and popClusterSec keeps it there. The apex window wants
        // something different: the calibration was fitted with the window centred
        // on the STRONGEST pop of the take-off, and re-centring it costs log 287
        // dearly (0.519 -> 0.643 m, and a refit recovers only 0.017 of that, so
        // the loss is information, not a stale constant). So the height keeps its
        // own anchor. For a kite jump it resolves to the same sample as before and
        // the height is unchanged: 287 measures 0.519 m either way.
        let apexT0 = apexAnchor(t0)
        guard let apex = apex(from: apexT0 - cfg.apexPreSec, span: cfg.apexPreSec + cfg.apexPostSec) else {
            if !forced { return false }
            onDebug(now, "REJECT t0=\(fmt(t0)) reason=apexWindowIncomplete")
            return true
        }
        // A SHORT shelf (minLiftPlateauSec..shelfFullSec) is admitted only with
        // corroboration. Opening the floor to 0.7 recovers all four missed
        // goldens but adds 15 low phantoms, and those pile up exactly ON the
        // floor (median shelf 0.70, median apex 0.23) while real jumps sit well
        // above it (1.30 / 1.07). Requiring apex >= shortShelfApexM on the short
        // ones holds smallLog at 16/16 with 4 phantoms and keeps the clean
        // control session at 0.
        let needsCorroboration = shelf < cfg.shelfFullSec && apex < cfg.shortShelfApexM
        if needsCorroboration {
            if !forced { return false }   // the shelf accumulates; it may still grow
            // SECOND CHANCE, from the flight window. The test above reads the
            // FIXED [-apexPreSec, +apexPostSec] matched filter, 4.5 s wide. A
            // long flight overflows it: on Yaniv the jumps Surfr caught and we
            // did not have reference airtimes of 4.3-4.8 s, and their apex over
            // the fixed window reads 0.00-0.19 while the same integral over the
            // FLIGHT window returns metres. Since V16.2 the flight window is the
            // better measurement anyway — so when the fixed window says nothing,
            // ask the flight window before discarding the candidate. Deferred
            // rather than decided here because the landing is not yet resolved.
            //
            // Measured on all seven logs: CLEAN 3/4 -> 4/4, V142 2/5 -> 4/5,
            // Yaniv 20/24 -> 23/24, guarded recall 35/39 -> 38/39, pooled height
            // 0.292 -> 0.282 m. The negative control stays at zero and the
            // tallest phantom stays 1.56 m; 287 and smallLog do not move.
            if !cfg.flightCorroboration {
                onDebug(now, "REJECT t0=\(fmt(t0)) reason=shortShelfNoApex shelf=\(fmt(shelf))s apex=\(fmt(apex))")
                return true
            }
        }
        // 3. Airtime — resolved BEFORE the height, because the height now wants
        //    the flight window (see below).
        let land0 = landing(bins, t0: t0, forced: forced)
        let landingT = land0.t
        // An unresolved landing is the one thing worth waiting for: it is what
        // makes the emission complete (airtime and distance).
        if landingT == nil && !forced { return false }
        // Do not finalise before the landing instant itself. The descent-end
        // bin is found landOffsetSec BEFORE the landing we report, and the
        // flight statistics and landing GPS fix below are gathered over
        // [t0, landingT]. Emitting earlier truncates that window and puts the
        // number on the wrist before the rider is down.
        if let lt = landingT, now < lt, !forced { return false }
        // A RESOLVED flight shorter than this is a watch knock. nil must pass —
        // 3 of the 35 real jumps across the reference logs never resolve one.
        if let lt = landingT, lt - t0 < cfg.minAirtimeSec {
            onDebug(now, "REJECT t0=\(fmt(t0)) reason=airtimeTooShort air=\(fmt(lt - t0))s")
            return true
        }

        // 3b. HEIGHT.
        //
        // V16.2 replaces the calibrated matched filter with a direct measurement.
        // Over the FLIGHT window, endpoint-anchored double integration of the TRUE
        // vertical acceleration returns the apex in METRES, with no scale and no
        // offset. Pooled over 37 goldens from five sessions it measures 0.317 m
        // MAE raw, and the best linear map that could be fitted to it is
        // h = 1.032*z + 0.048 — the identity to within 3 % and 5 cm. That is the
        // signature of a measurement rather than a correlate.
        //
        // Why V16.0/V16.1 never found it: the historical experiment integrated
        // `az` and concluded a per-jump window "collapses the correlation to r~0".
        // It does — with THAT SIGN. Our az reads +9.81 m/s^2 in free fall, i.e. it
        // is the negative of the kinematic acceleration, so the integral must run
        // on -az. With +az the peak measures 0.00 on every bench throw and
        // 0.00-0.12 on the log-287 goldens: exactly the r~0 that was recorded. The
        // fixed-window matched filter and the whole heightScale/heightOffsetM
        // calibration were built to work around a sign.
        //
        // The matched filter stays as the FALLBACK: the integral needs a resolved
        // landing to bound its window, and 3 of the 37 goldens never resolve one.
        // Prefer the FREE-FALL window when one exists. The descent-arrest landing
        // rule was built for water; on a thrown watch it never closes in time and
        // the window comes out about twice too long (bench: 2.80 s measured
        // against a true 1.42 s flight), which the integral then faithfully
        // integrates. Free fall bounds the same event exactly: 2.50 / 1.55 /
        // 2.97 m against a ballistic truth of 2.48 / 1.54 / 3.00 m.
        var winA = t0
        var winB = landingT
        var ballistic = false
        if let lt = landingT, let ff = freeFallWindow(from: t0, to: lt) {
            winA = ff.0; winB = ff.1; ballistic = true
        }

        // TAKE-OFF PRE-ROLL. t0 is the POP — the strongest sample of the
        // take-off burst — and the rider is already rising by then. Starting the
        // integral there truncates the first part of the ascent, and the
        // signature is a NEGATIVE height bias that both references show
        // independently: -0.118 m against Surfr on Gavri's 15 second-precision
        // rows, -0.210 m against HOOLAN on 287 + smallLog.
        //
        // Sweeping the window start from 0 to -0.9 s traces a clean U on each
        // reference separately:
        //
        //     shift    GAVRI (Surfr)     HOOLAN          pooled
        //      0.0     0.216  -0.118     0.330  -0.210   0.291
        //     -0.2     0.192  +0.052     0.251  -0.114   0.231
        //     -0.3     0.204  +0.106     0.218  -0.072   0.213
        //     -0.5     0.250  +0.201     0.205  -0.010   0.220
        //
        // The full suite bottoms out at -0.5 (0.188 m), but the guarded suite is
        // entirely HOOLAN-lineage and Surfr is the only independent reference —
        // and at -0.5 Surfr DEGRADES below baseline (0.216 -> 0.250). 0.3 s is
        // the only value that improves both families, so that is what ships.
        //
        // HEIGHT WINDOW ONLY. Detection, airtime and distance still use t0, the
        // same decoupled-anchor pattern as apexAnchorSec. Free fall is exempt:
        // it bounds a thrown watch exactly.
        //
        // Feeding the raw rather than the pre-rolled height to the short-shelf
        // gate was tried and is WORSE — it costs V142 a real jump (4/5 -> 3/5).
        //
        // Known cost, one jump: on smallLog two candidates 2.4 s apart sit inside
        // dedupSec and the pre-roll flips which is "stronger" by 2 cm. The wrong
        // one wins and its distance goes 19 -> 36 m against an 18.2 m golden,
        // moving that log's distance MAE 4.50 -> 5.82 m. A dedup coin-flip
        // amplified by one outlier: log 287's distance is unchanged at 3.77 m.
        if !ballistic, winB != nil { winA = t0 - cfg.heightPreRollSec }
        var flightH: Double? = (cfg.heightFromFlight && winB != nil)
            ? flightHeight(t0: winA, landingT: winB!) : nil
        // A ballistic event may be reported as peak-above-release (1.0) or as
        // Deferred corroboration (see needsCorroboration). The fixed window found
        // no apex; the flight window is the only remaining evidence and must
        // clear shortShelfFlightM on its own.
        if needsCorroboration {
            if flightH == nil || flightH! < cfg.shortShelfFlightM {
                onDebug(now, "REJECT t0=\(fmt(t0)) reason=shortShelfNoApex shelf=\(fmt(shelf))s apex=\(fmt(apex)) flight=\(flightH == nil ? "none" : fmt(flightH!))")
                return true
            }
        }

        // total vertical path (2.0). See throwHeightScale.
        if let f = flightH, ballistic, cfg.throwHeightScale != 1 {
            flightH = f * cfg.throwHeightScale
        }
        let heightM = flightH ?? (cfg.heightScale * apex + cfg.heightOffsetM)
        guard heightM >= cfg.minReportM else {
            // FINAL even when not forced: both windows have closed, so no later
            // sample can raise this height.
            onDebug(now, "REJECT t0=\(fmt(t0)) reason=belowMinReport h=\(fmt(heightM))m src=\(flightH != nil ? "flight" : "matched")")
            return true
        }

        // 4. Flight statistics.
        let tEnd = landingT ?? (t0 + cfg.apexPostSec)
        var peakG = 0.0, maxGyro = 0.0, floatN = 0, n = 0
        for i in ringHead..<ring.count {
            let s = ring[i]
            if s.t < t0 { continue }
            if s.t > tEnd { break }
            n += 1
            peakG = max(peakG, s.load)
            maxGyro = max(maxGyro, s.gyro)
            if s.load <= cfg.floatLoadG { floatN += 1 }
        }
        // Two different questions, two different fixes. SPEED wants the entry
        // velocity a moment before the pop starts bleeding it off, so it samples
        // at t0-1.0. DISPLACEMENT must start where the rider actually left the
        // water: sampling it 1 s early folded a whole second of riding into every
        // jump (~8 m at 30 km/h). Measured on smallLog that alone was +12.8 m of
        // bias; splitting them takes distance MAE 12.80 -> 6.40 m there and leaves
        // log 287 unchanged at 4.94 -> 5.00 m while re-centring bias +3.73 -> -2.14 m.
        // ── 4b. PHANTOM FILTER (see phantomFilter). Placed here because it
        // needs both the shelf and the finished height, and BEFORE the dedup
        // hold so a rejected candidate never displaces a real jump in `pending`.
        if cfg.phantomFilter && !land0.fromArrest {
            let short = plateau < cfg.phantomShelfSec
            let shortAndSmall = plateau < cfg.phantomShelfWideSec
                && heightM < cfg.phantomWideHeightM
            if short || shortAndSmall {
                onDebug(now, "REJECT t0=\(f2(t0)) reason=incompleteFlight shelf=\(f2(plateau))s h=\(f2(heightM))m noArrest")
                return true
            }
        }

        let launch = gpsPoint(near: t0 - 1.0)
        let launchPos = gpsPoint(near: t0)
        let land = gpsPoint(near: tEnd)
        var distanceM: Double?
        if let launchPos, let land, (launchPos.lat != 0 || launchPos.lng != 0), (land.lat != 0 || land.lng != 0) {
            distanceM = Self.haversineM(launchPos.lat, launchPos.lng, land.lat, land.lng)
        } else if let launch, let landingT {
            distanceM = launch.spd * (landingT - t0)
        }
        // NO FLIGHT WINDOW, NO DISTANCE. An unresolved landing makes tEnd fall
        // back to apexPostSec, so the span above covers 2 s of a flight that
        // lasted four or five. That is not a short measurement, it is the wrong
        // one: on smallLog the single such jump reported 19.5 m against a 30.4 m
        // golden and carried the session's second-largest error. Suppressing it
        // takes distance MAE 4.96 -> 4.50 m and its correlation with the
        // reference 0.456 -> 0.585, and leaves log 287 (no unresolved landing)
        // untouched. "Not measured" beats "measured wrong".
        //
        // Rejected alongside it: interpolating the GPS endpoints between the
        // fixes bracketing take-off and landing. Fixes arrive at 1.00 Hz, so
        // snapping to the nearest carries up to 4 m of pure timing error at each
        // end, and the correction is arithmetic rather than a filter — but
        // measured it splits: log 287 improves (3.77 -> 3.64 m, r 0.885 ->
        // 0.918) while smallLog worsens on both counts (4.96 -> 5.12 m, r 0.456
        // -> 0.380). Pooled it is a wash. The real distance error is not the
        // endpoints: distance is airtime x speed in disguise and inherits the
        // airtime's failures — smallLog's three outliers are all landing
        // failures, and across the other 11 jumps interpolation moves the error
        // by 0.01 m.
        if landingT == nil { distanceM = nil }

        let jump = V16Jump(
            heightM: round2(heightM),
            apexRawM: round2(apex),
            airtimeSec: landingT.map { round2($0 - t0) },
            takeoffT: t0,
            liftPlateauSec: round2(shelf),
            yankG: round2(c.yankG),
            peakG: round2(peakG),
            floatFraction: n > 0 ? round2(Double(floatN) / Double(n)) : 0,
            maxGyroRadS: round2(maxGyro),
            takeoffSpeedMS: launch.map { round2($0.spd) },
            distanceM: distanceM.map(round2),
            // Pinned to an ABSOLUTE shelf, not minLiftPlateauSec * 1.5. The two
            // were the same number while the gate sat at 0.70 s, but they answer
            // different questions: the gate asks "is this a jump", this asks "is
            // the evidence strong". Deriving it from the gate meant that lowering
            // the gate to 0.60 also relabelled 0.90-1.05 s shelves as high
            // confidence — the very band the phantom filter treats as suspect.
            confidence: shelf >= cfg.strongShelfSec ? 0.75 : 0.55
        )

        // 5. Dedup: one takeoff raises several pops — hold, keep the strongest.
        // A jump too big for any precursor to beat skips the wait entirely.
        if heightM >= cfg.immediateReportM {
            // The immediate path used to skip the lastEmit check entirely, so two
            // jumps both over immediateReportM inside dedupSec BOTH fired. That
            // produced the 4.39 m "phantom" 3.4 s after the real 4.24 m jump at
            // 859 s on smallLog — one take-off delivered twice. The earlier one is
            // already on screen and cannot be retracted, so the later one is the
            // one to drop, stronger or not; a rider needs well over 5 s between
            // real jumps.
            if let le = lastEmit, t0 - le.t0 < cfg.dedupSec {
                onDebug(now, "DROP t0=\(fmt(t0)) h=\(fmt(heightM))m duplicate of delivered \(fmt(le.heightM))m at \(fmt(le.t0))")
                return true
            }
            if let h = held, t0 - h.jump.takeoffT < cfg.dedupSec {
                onDebug(now, "MERGE t0=\(fmt(h.jump.takeoffT)) into \(fmt(t0)) (\(fmt(h.jump.heightM))m < \(fmt(heightM))m)")
                held = nil
            }
            lastEmit = (t0, heightM)
            delegate?.jumpDetected(jump)
            onDebug(now, "JUMP t0=\(fmt(t0)) h=\(fmt(heightM))m IMMEDIATE shelf=\(fmt(shelf))s")
            return true
        }
        // A straggler behind an already-delivered jump cannot be retracted, so
        // it is dropped only when it is the weaker of the pair — the case that
        // actually occurs.
        if let le = lastEmit, t0 - le.t0 < cfg.dedupSec, heightM <= le.heightM {
            onDebug(now, "DROP t0=\(fmt(t0)) h=\(fmt(heightM))m behind delivered \(fmt(le.heightM))m")
            return true
        }
        if let h = held, t0 - h.jump.takeoffT < cfg.dedupSec {
            if heightM <= h.jump.heightM {
                onDebug(now, "MERGE t0=\(fmt(t0)) into \(fmt(h.jump.takeoffT)) (\(fmt(heightM))m <= \(fmt(h.jump.heightM))m)")
                held = (h.jump, holdUntil(t0))
                return true
            }
            onDebug(now, "MERGE t0=\(fmt(h.jump.takeoffT)) into \(fmt(t0)) (\(fmt(h.jump.heightM))m < \(fmt(heightM))m)")
            held = nil
        }
        releaseHeld(now: .infinity)   // anything older than the dedup span is final
        held = (jump, holdUntil(t0))
        return true
    }

    /// A rival pop up to dedupSec after `t0` is itself judged evalDelaySec after
    /// ITS pop, so the hold must span both delays or it expires before the rival
    /// is even evaluated.
    /// When a held jump can finally be delivered.
    ///
    /// Only a pop that is BOTH inside the dedup window AND not yet judged can
    /// still supersede it. Because `dedupSec < evalDelaySec`, every such pop
    /// has ALREADY arrived and is sitting in `pending` by the time the jump is
    /// held — a pop is detected the instant it happens, long before it is
    /// judged. So "can anything still beat this?" is answerable immediately,
    /// and when the answer is no the jump is final RIGHT NOW.
    ///
    /// The previous rule waited `dedupSec + evalDelaySec` unconditionally, for
    /// a rival that in most cases never existed: measured over the reference
    /// logs, 6 of 10 held jumps had no rival pop at all and waited 7 s for
    /// nothing. Those now deliver at t0 + evalDelaySec, like the fast path.
    private func holdUntil(_ t0: TimeInterval) -> TimeInterval {
        var until = t0 + cfg.evalDelaySec          // the moment it was judged
        for c in pending where c.t0 > t0 && c.t0 <= t0 + cfg.dedupSec {
            let judged = c.t0 + cfg.evalDelaySec
            if judged > until { until = judged }
        }
        return until
    }

    /// Deliver a held jump once no later pop can still supersede it.
    private func releaseHeld(now: TimeInterval) {
        guard let h = held, now >= h.until else { return }
        held = nil
        lastEmit = (h.jump.takeoffT, h.jump.heightM)
        delegate?.jumpDetected(h.jump)
        onDebug(now, "JUMP t0=\(fmt(h.jump.takeoffT)) h=\(fmt(h.jump.heightM))m "
            + "shelf=\(fmt(h.jump.liftPlateauSec))s "
            + "air=\(h.jump.airtimeSec.map(fmt) ?? "n/a")s yank=\(fmt(h.jump.yankG))g")
    }

    // MARK: Signal helpers

    private struct Bins {
        let t: [TimeInterval]
        let az: [Double]
    }

    /// 0.1 s bins of world-vertical acceleration, smoothed.
    /// Returns nil when any bin lacks attitude — height would be meaningless.
    private func liftBins(from: TimeInterval, to: TimeInterval) -> Bins? {
        let step = 0.1
        let nBins = Int(((to - from) / step).rounded())
        guard nBins >= 10 else { return nil }

        var azRaw = [Double](repeating: 0, count: nBins)
        var attCnt = [Int](repeating: 0, count: nBins)
        for i in ringHead..<ring.count {
            let s = ring[i]
            if s.t < from { continue }
            if s.t >= to { break }
            let k = Int((s.t - from) / step)
            guard k >= 0, k < nBins else { continue }
            if s.az.isFinite { azRaw[k] += s.az; attCnt[k] += 1 }
        }
        // A bin with no attitude sample becomes NaN, which breaks any lift run
        // passing through it (a shelf cannot be verified across a gap) without
        // discarding the whole evaluation. The apex window is protected
        // separately and far more strictly: apex() refuses if ANY of its
        // samples lacks attitude, because an integral cannot bridge a hole.
        //   (An earlier version compared the total attitude SAMPLE count to the
        //   BIN count — at 200 Hz that is 2100 vs 105, so the guard passed even
        //   when most samples had no attitude; and requiring every bin outright
        //   let one dropped 0.1 s of CMDeviceMotion silently kill a real jump.)
        var t = [TimeInterval](repeating: 0, count: nBins)
        for k in 0..<nBins {
            t[k] = from + Double(k) * step
            azRaw[k] = attCnt[k] > 0 ? azRaw[k] / Double(attCnt[k]) : Double.nan
        }
        let w = max(0, Int((cfg.liftSmoothSec / step).rounded()))
        return Bins(t: t, az: Self.boxSmooth(azRaw, halfWidth: w))
    }

    /// Landing: lift shelf opens and closes, then the first dip, confirmed by
    /// sustained float after it. LOW CONFIDENCE — see the file header.
    /// Landing = the moment the DESCENT IS ARRESTED.
    ///
    /// A kite flight is a sustained signed excursion: the canopy lifts, then
    /// the rider comes down. Water contact brakes that descent — and it is the
    /// descent that stops, not the motion. The arm keeps working the bar, so
    /// acceleration stays noisy after touchdown; an earlier version demanded
    /// sustained "float" after the dip and returned nil on 2 of 19 goldens
    /// because that quiet state never arrived.
    ///
    /// Measured on world-vertical acceleration, NOT on integrated velocity: a
    /// single integral of a_z carries an unbounded bias b*t that swamps the
    /// descent (over the reference jumps the integrated velocity never even
    /// goes negative). Acceleration needs no integration, so there is no bias.
    ///
    ///   phase 1 — the lift shelf opens above landLiftThreshMS2 and closes
    ///   phase 2 — the first descent run below landDipMS2 lasting
    ///             landDipMinSec; the landing is the END of that run
    ///
    /// Validated on the engine (not an offline copy — one such copy misaligned
    /// its bins by 46 ms and was 1.1 s off on a jump) against all 14 HOOLAN
    /// reference airtimes for log 287: 14/14 resolved, 0.34 s leave-one-out
    /// MAE with landOffsetSec refitted out-of-sample, versus 0.75 s for a
    /// constant predictor. The old settle-based rule resolved only 17/19.
    /// airtimeSec still carries LOW CONFIDENCE: one session, one rider.
    private func landing(_ bins: Bins, t0: TimeInterval, forced: Bool)
        -> (t: TimeInterval?, fromArrest: Bool) {
        if let arrest = arrestLanding(bins, t0: t0) { return (arrest, true) }
        // ONLY at the deadline. `landing()` runs on every sample while the flight
        // is still in the air, and early on the arrest rule has not seen its
        // descent yet — a settle window offered then would pre-empt the better
        // answer and finalise on a partial flight (log 287: 0.30 -> 0.76 m).
        guard forced, cfg.landSettleFallback else { return (nil, false) }
        // May only ADD a window, never remove a jump: a settle landing shorter
        // than minAirtimeSec is discarded rather than used, because a
        // resolved-but-short flight is REJECTED downstream and these jumps are
        // currently kept with airtime reported as "not measured".
        guard let settle = settleLanding(t0: t0), settle - t0 >= cfg.minAirtimeSec else {
            return (nil, false)
        }
        return (settle, false)
    }

    /// The specific force returns to ~1 g and STAYS there: the rider is back on
    /// the water and tracking it. Fallback only — see `landSettleFallback`.
    ///
    /// Runs on specific force, not on |userAcceleration|: sf is 1 at rest and 0
    /// in free fall regardless of attitude, so "back to 1 g" is a
    /// frame-independent statement about being supported again. Reports the
    /// START of the settled run, which is where support resumes.
    private func settleLanding(t0: TimeInterval) -> TimeInterval? {
        let need = cfg.landSettleMinSec
        let from = t0 + cfg.landSettleFromSec, to = t0 + cfg.landSettleToSec
        var run = 0.0
        var prevT = Double.nan
        var i = ringHead
        while i < ring.count {
            let s = ring[i]
            i += 1
            if s.t < from { continue }
            if s.t > to { break }
            let sf = Self.specificForce(s)
            let dt = prevT.isFinite ? s.t - prevT : 0
            prevT = s.t
            if sf.isFinite, abs(sf - 1) < cfg.landSettleBandG {
                run += dt
                if run >= need { return s.t - need }
            } else {
                run = 0
            }
        }
        return nil
    }

    /// The primary rule — see the contract above.
    private func arrestLanding(_ bins: Bins, t0: TimeInterval) -> TimeInterval? {
        var i0 = 0
        while i0 < bins.t.count, bins.t[i0] < t0 { i0 += 1 }

        var plateauEnd = -1
        var run = 0
        var i = i0
        while i < bins.t.count {
            if bins.az[i] > cfg.landLiftThreshMS2 {
                run += 1
            } else {
                if Double(run) * 0.1 >= cfg.landMinPlateauSec { plateauEnd = i; break }
                run = 0
            }
            i += 1
        }
        guard plateauEnd >= 0 else { return nil }

        // Phase 2 — the descent, ending where the water arrests it.
        var dip = 0
        var j = plateauEnd
        while j < bins.t.count {
            if bins.az[j] < cfg.landDipMS2 {          // NaN gap is not a descent
                dip += 1
            } else {
                if Double(dip) * 0.1 >= cfg.landDipMinSec { return bins.t[j] + cfg.landOffsetSec }
                dip = 0
            }
            j += 1
        }
        return nil
    }

    /// Bounded double integration over [from, from+span] with z(0)=z(T)=0.
    ///
    ///   a_meas = a_true + b          (b = constant bias: attitude error,
    ///                                 sensor offset, gravity residual)
    ///   W(t)   = II a_meas          = z_true(t) + v0*t + 0.5*b*t^2
    ///   z(t)   = W(t) - (t/T)*W(T)  forces z(0)=z(T)=0
    ///          = z_true(t) - (t/T)*z_true(T) + 0.5*b*t*(t-T)
    ///
    /// The unknown initial vertical velocity v0 cancels EXACTLY (it is linear
    /// in t). The bias term becomes 0.5*b*t*(t-T): zero at both ends, extremum
    /// -b*T^2/8 at midpoint. A bias that would otherwise diverge quadratically
    /// is BOUNDED by b*T^2/8 — with T=4.5 s that is 2.5*b, so 0.1 m/s^2 of bias
    /// costs 0.25 m. No bias estimation is needed.
    /// Where the apex window should centre: the strongest load sample in
    /// [t0, t0 + apexAnchorSec]. Returns t0 when nothing beats it, so
    /// apexAnchorSec = 0 is an exact no-op.
    /// V16.2 height: endpoint-anchored double integration of the TRUE vertical
    /// acceleration (-az) over the flight, returning the apex in metres.
    ///
    /// z(t) = the double integral of -az with z(0) = z(T) = 0 enforced by removing
    /// the linear trend. The anchoring is what makes it usable: the rider starts
    /// and ends at the water, so any constant velocity or acceleration bias is
    /// absorbed by the chord and only the CURVATURE — the actual arc — survives.
    /// Unlike apex(), the support is the MEASURED flight, so the result is metres
    /// and needs no calibration. nil when attitude does not cover the window.
    /// The specific force a sample actually felt, in g: 1.0 at rest, 0.0 in free
    /// fall. No extra state is needed — with `load` = |userAcceleration| and
    /// wz = az/G0 the world-vertical component,
    ///
    ///     sf^2 = |ua + gravity|^2 = (load^2 - wz^2) + (wz - 1)^2 = load^2 - 2*wz + 1
    ///
    /// (at rest load=0, wz=0 -> 1; in free fall load=1, wz=1 -> 0).
    private static func specificForce(_ s: Sample) -> Double {
        guard s.az.isFinite else { return .nan }
        let v = s.load * s.load - 2 * (s.az / G0) + 1
        return v > 0 ? v.squareRoot() : 0
    }

    /// The longest sustained FREE FALL inside [from, to], or nil.
    private func freeFallWindow(from: TimeInterval, to: TimeInterval) -> (TimeInterval, TimeInterval)? {
        var bestA = 0.0, bestB = -1.0, a = -1.0, prevT = Double.nan
        func close(_ endT: Double) {
            if a >= 0, endT - a > bestB - bestA { bestA = a; bestB = endT }
            a = -1
        }
        for i in ringHead..<ring.count {
            let s = ring[i]
            if s.t < from { continue }
            if s.t > to { break }
            if prevT.isFinite, s.t - prevT > cfg.maxAttitudeGapSec { close(prevT) }
            let sf = Self.specificForce(s)
            if sf.isFinite && sf < cfg.freeFallG { if a < 0 { a = s.t } } else { close(prevT) }
            prevT = s.t
        }
        close(prevT)
        return bestB - bestA >= cfg.minFreeFallSec ? (bestA, bestB) : nil
    }

    private func flightHeight(t0: TimeInterval, landingT: TimeInterval) -> Double? {
        var ts: [TimeInterval] = [], az: [Double] = []
        for i in ringHead..<ring.count {
            let s = ring[i]
            if s.t < t0 { continue }
            if s.t > landingT { break }
            guard s.az.isFinite else { continue }
            if let last = ts.last, s.t - last > cfg.maxAttitudeGapSec { return nil }
            ts.append(s.t); az.append(s.az)
        }
        let n = ts.count
        guard n >= 20, ts[0] - t0 <= cfg.maxAttitudeGapSec,
              landingT - ts[n - 1] <= cfg.maxAttitudeGapSec else { return nil }
        var rel = [Double](repeating: 0, count: n), z = [Double](repeating: 0, count: n)
        var v = 0.0
        for i in 1..<n {
            let dt = ts[i] - ts[i - 1]
            let vPrev = v
            v += (-az[i] + -az[i - 1]) / 2 * dt
            z[i] = z[i - 1] + (vPrev + v) / 2 * dt
            rel[i] = ts[i] - ts[0]
        }
        let T = rel[n - 1]
        guard T > 0 else { return nil }
        let zT = z[n - 1]
        var peak = -Double.infinity
        for i in 0..<n {
            let c = z[i] - (rel[i] / T) * zT
            if c > peak { peak = c }
        }
        return peak.isFinite ? peak : nil
    }

    private func apexAnchor(_ t0: TimeInterval) -> TimeInterval {
        guard cfg.apexAnchorSec > 0 else { return t0 }
        var bestT = t0, bestLoad = -1.0
        for i in ringHead..<ring.count {
            let s = ring[i]
            if s.t < t0 { continue }
            if s.t > t0 + cfg.apexAnchorSec { break }
            if s.load > bestLoad { bestLoad = s.load; bestT = s.t }
        }
        return bestT
    }

    private func apex(from: TimeInterval, span: TimeInterval) -> Double? {
        let to = from + span
        // Collect the attitude-carrying samples in the window. Scattered
        // dropouts are integrated through with their real spacing; only a hole
        // longer than maxAttitudeGapSec is unbridgeable.
        var ts: [TimeInterval] = []
        var azs: [Double] = []
        ts.reserveCapacity(1024)
        azs.reserveCapacity(1024)
        for i in ringHead..<ring.count {
            let s = ring[i]
            if s.t < from { continue }
            if s.t > to { break }
            guard s.az.isFinite else { continue }
            if let lastT = ts.last, s.t - lastT > cfg.maxAttitudeGapSec { return nil }
            ts.append(s.t)
            azs.append(s.az)
        }
        let n = ts.count
        guard n >= 20 else { return nil }
        // the window must also be covered at its edges, not just in the middle
        guard ts[0] - from <= cfg.maxAttitudeGapSec else { return nil }
        guard to - ts[n - 1] <= cfg.maxAttitudeGapSec else { return nil }

        // TRAPEZOID quadrature. The previous rule advanced velocity with the
        // RIGHT-hand sample over the whole interval (v += az[i]*dt) — a
        // rectangle rule that, across a dropout, integrates only the post-gap
        // value over the entire hole. Measured: on a 0.1 s hole the height
        // error falls 32 -> 19 cm; on clean 200 Hz data the two rules differ by
        // 2 cm, so the calibration is unaffected. Linear interpolation across a
        // gap is algebraically identical to this — no resampling needed.
        var W = [Double](repeating: 0, count: n)
        var Ts = [Double](repeating: 0, count: n)
        var v = 0.0, z = 0.0
        let t0 = ts[0]
        for i in 0..<n {
            let dt = i == 0 ? 0 : ts[i] - ts[i - 1]
            let a = i == 0 ? azs[i] : (azs[i - 1] + azs[i]) / 2
            let vPrev = v
            v += a * dt
            z += (vPrev + v) / 2 * dt
            W[i] = z
            Ts[i] = ts[i] - t0
        }
        let tf = Ts[n - 1]
        guard tf > 0 else { return nil }
        let wt = W[n - 1]
        var apex = -Double.infinity
        for i in 0..<n {
            let q = W[i] - (Ts[i] / tf) * wt
            if q > apex { apex = q }
        }
        return apex.isFinite ? apex : nil
    }

    private func gpsPoint(near t: TimeInterval) -> GpsPt? {
        var best: GpsPt?
        var bd = 3.0
        for g in gpsHistory {
            let d = abs(g.t - t)
            if d < bd { bd = d; best = g }
        }
        return best
    }

    // MARK: Static maths

    /// World-Z component of a device-frame vector rotated by the attitude quaternion.
    private static func worldZ(_ q: (w: Double, x: Double, y: Double, z: Double),
                               _ vx: Double, _ vy: Double, _ vz: Double) -> Double {
        2 * (q.x * q.z - q.w * q.y) * vx
            + 2 * (q.y * q.z + q.w * q.x) * vy
            + (1 - 2 * (q.x * q.x + q.y * q.y)) * vz
    }

    /// Box smoother over +-halfWidth bins.
    ///
    /// A NaN bin (no attitude) must stay NaN so it breaks any lift run passing
    /// through it — but only LOCALLY. The running sum is therefore kept over
    /// finite values only, with NaNs counted separately: adding NaN into the
    /// sum makes it NaN permanently (NaN - NaN = NaN), so a single empty 0.1 s
    /// bin used to poison every later bin and the shelf could never be found
    /// again. Latent on the 200 Hz research logs, where no jump window contains
    /// an empty bin; live on the watch, where 0.1 s at 50 Hz is 5 samples.
    private static func boxSmooth(_ src: [Double], halfWidth: Int) -> [Double] {
        let n = src.count
        guard halfWidth > 0, n > 0 else { return src }
        var out = [Double](repeating: 0, count: n)
        var sum = 0.0
        var nans = 0
        func add(_ v: Double) { if v.isFinite { sum += v } else { nans += 1 } }
        func rem(_ v: Double) { if v.isFinite { sum -= v } else { nans -= 1 } }
        for i in 0...min(n - 1, halfWidth) { add(src[i]) }
        for i in 0..<n {
            let lo = i - halfWidth, hi = i + halfWidth
            let width = min(n - 1, hi) - max(0, lo) + 1
            out[i] = nans > 0 ? Double.nan : sum / Double(width)
            if hi + 1 < n { add(src[hi + 1]) }
            if lo >= 0 { rem(src[lo]) }
        }
        return out
    }

    /// Longest continuous run above `thresh` from `from` onward, in seconds.
    /// Counted in whole BINS and scaled once: accumulating 0.1 ten times gives
    /// 0.9999999999999999, which silently failed a `>= 1.0` shelf gate.
    private static func longestRun(_ az: [Double], _ t: [TimeInterval],
                                   from: TimeInterval, above thresh: Double) -> Double {
        var best = 0, run = 0
        for i in 0..<az.count {
            if t[i] < from { continue }
            // NaN (an attitude gap) fails the comparison and resets the run —
            // a shelf is never credited across a hole.
            if az[i] > thresh {
                run += 1
                if run > best { best = run }
            } else {
                run = 0
            }
        }
        return Double(best) * 0.1
    }

    private static func haversineM(_ lat1: Double, _ lng1: Double,
                                   _ lat2: Double, _ lng2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let h = pow(sin(dLat / 2), 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * pow(sin(dLng / 2), 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }

    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}
