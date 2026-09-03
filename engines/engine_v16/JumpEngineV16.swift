//
//  JumpEngineV16.swift
//  SPOTEQ Watch App
//
//  V16.8 — big-air-first jump engine. Swift twin of core/jumpEngineV16.ts; the
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
//      control session max 0.6 s across 19 pops. At the shipped 1.25 m/s² /
//      0.8 s operating point this one test keeps 19/23 real jumps and admits
//      0/19 control pops — the phantom firewall, no GPS needed.
//
//   3. HEIGHT — endpoint-anchored double integration of the TRUE vertical
//      acceleration (-az) over the MEASURED FLIGHT, with z(0)=z(T)=0. The
//      result is metres directly: no scale, no offset. Pooled over 37 goldens
//      from five sessions it measures 0.300 m MAE, and the best linear map
//      that could be fitted to the raw output is h = 1.032*z + 0.048 — the
//      identity to within 3 % and 5 cm, which is the signature of a
//      measurement rather than a correlate. See §3b of evaluate() for why
//      V16.0/V16.1 could not find this (a sign) and how the window is chosen.
//
//      The V16.1 MATCHED FILTER — the same integral over a FIXED window,
//      mapped to metres by heightScale/heightOffsetM — is KEPT as the
//      fallback for the 3 of 37 goldens whose landing never resolves, since
//      the flight integral needs a bounded window. Set heightFromFlight=false
//      to restore V16.1 behaviour exactly.
//
//   4. AIRTIME — measured from where the water ARRESTS the descent (see
//      `landing`). 14/14 of the log-287 references resolved, 0.46 s MAE
//      (V16.1 measured 0.34 s; t0 now marks the TRUE take-off, so the flight
//      measures longer — an accepted regression, see the V16.2 notes). Still
//      LOW CONFIDENCE — one session, one rider — so never gate on `airtimeSec`.
//      It is nil when the descent was never arrested; that is a statement of
//      "not measured", NOT a short flight. See the note on the sentinel in
//      JumpDetectorV16.makeJump.
//
//   5. DISTANCE — derived, so it INHERITS the airtime error: haversine between
//      the GPS fix AT the pop and the one at the estimated landing. Measured
//      3.87 m MAE on log 287 and 6.19 m on smallLog after V16.2 stopped
//      sampling the displacement origin 1 s early (12.80 m before).
//      takeoffSpeedMS by contrast is still read at t0−1.0 s — deliberately,
//      because that is the entry speed before the pop bleeds it off — and so
//      carries its own −1.3 mph bias.
//
//  NOT used, and why (measured, not assumed):
//   • absoluteAltitude — passes a health gate on only 7/21 goldens and, even
//     when it passes, produced −6.4 m and −2.1 m errors (a negative apex for a
//     real jump = water over the port). Nothing available predicts when it is
//     trustworthy, so fusing it injects metre-scale error into a 0.43 m
//     estimator.
//   • relativeAltitude / raw pressure — alive (71 % distinct, max 5 s freeze)
//     but useless per jump: 67 of the 68 inter-sample steps above 3 m fall
//     OUTSIDE any jump. Noise exceeds signal in the same band, so no filter or
//     drift reset recovers it (measured r = 0.19–0.31).
//
//  SCOPE: V16 is tuned for big air, and V16.2 closes the small-jump gap. On
//  the 16-golden smallLog session (1.5–3.7 m) recall is 16/16 and height MAE
//  0.21 m — the first operating point that beats a constant predictor (0.50 m)
//  in that band. Below ~2.5 m the height is still the weakest part of the
//  range, but it is no longer a population estimate.
//
//  DO NOT hand the low band back to V15. It was tried and measured twice.
//  16.1: swapping V15 in below 2.5 m makes the small-jump MAE WORSE, 0.36 ->
//  0.47 m, because V15's barometric paths never fire there and everything
//  falls through to its ballistic estimate, a near-constant by construction.
//  16.2: V15's RAW landing is also worse than ours (airtime MAE 0.92 s vs
//  0.71 s on smallLog, 1.40 s vs 0.34 s on log 287) — its apparent airtime
//  advantage is a 0.75-weight shrink toward a 3.4 s prior, i.e. a constant,
//  not a measurement.
//
//
//  ── V16.8 ───────────────────────────────────────────────────────────────
//  Raises the reporting floor to 1.5 m and guards impossible airtime outliers.
//  Reported airtime above 4.0 times the ballistic time for the final height is
//  clipped to 3.2 times that time; GPS distance is then recomputed at the
//  clipped endpoint. Height and all detection windows remain untouched.
//
//  ── V16.7 ───────────────────────────────────────────────────────────────
//  The height window starts 0.5 s before the pop. On big-air candidates it also
//  extends 0.8 s beyond max(resolved airtime, 5 s), triggered by airtime >= 4 s
//  OR a first-pass height >= 3.5 m. The streaming engine waits for that window
//  unless the 7.5 s evaluation deadline forces a shorter tail. A single,
//  explicit identity reference calibration maps the measured height to Surfr
//  as displayed. Recall is unchanged; pooled height MAE is 0.454 m over the
//  complete reference set and 0.502 m for jumps at or above 4 m.
//
//  ── V16.5 ───────────────────────────────────────────────────────────────
//  The resolved-flight height window starts 0.3 s before the pop. The pop is
//  already inside the ascent, so starting at t0 truncated real lift and left a
//  negative bias against both independent reference families. Detection,
//  airtime, distance and free-fall windows remain anchored exactly as before.
//  Guarded recall stays 38/39 while pooled height MAE improves 0.282 -> 0.199 m.
//
//  ── V16.4 ───────────────────────────────────────────────────────────────
//  Four measured changes on top of V16.3, with no new sensors or API changes:
//    1. A short shelf that the fixed matched-filter window cannot corroborate
//       is deferred until the measured flight window can be checked.
//    2. minLiftPlateauSec moves 0.70 -> 0.60 s.
//    3. An unresolved landing reports no distance instead of a truncated chord.
//    4. Confidence uses the absolute 1.05 s strong-shelf threshold.
//  Guarded recall improves 35/39 -> 38/39 and pooled height MAE 0.292 ->
//  0.282 m; the negative control remains silent and the tallest phantom stays
//  1.56 m. Set flightCorroboration=false and minLiftPlateauSec=0.7 for V16.3.
//
//  ── V16.3 ───────────────────────────────────────────────────────────────
//  Two changes on top of V16.2, both measured over six logs holding 78
//  confirmed jumps. NEITHER COSTS A SINGLE REAL JUMP: recall is 35/39 before
//  and after. No new sensors, no new state, no API change.
//    1. SETTLE FALLBACK — when the descent-arrest rule never resolves, look for
//       the specific force returning to ~1 g and STAYING there. An unresolved
//       landing costs more than a missing airtime: it also denies the height
//       its flight window. Pooled height MAE 0.300 -> 0.292 m, GAVRI 0.468 ->
//       0.401 m. It runs ONLY when `forced` — offered mid-flight it pre-empts
//       the better answer and finalises on a partial flight (287: 0.30 -> 0.76 m).
//       Airtime pays 0.93 -> 1.00 s on GAVRI for it.
//    2. PHANTOM FILTER — reject when the ARREST rule was unresolved AND the
//       lift shelf is short. Tallest phantom across the suite 2.54 -> 1.56 m;
//       log 287's three phantoms go to zero. Every impact-based landing rule
//       was measured as an alternative and all fire 1.4-3.6 s EARLY: a kite
//       landing is soft and has NO touchdown spike (see the config comments).
//  Set landSettleFallback=false and phantomFilter=false for exact V16.2.
//
//  ── V16.2 ───────────────────────────────────────────────────────────────
//  Measured on six reference logs. Recall 31/39 -> 36/39, phantoms 9 -> 8,
//  TALLEST phantom 3.73 -> 2.54 m, pooled height MAE 0.575 -> 0.300 m, and
//  hand throws on a bench detected for the first time (0/4 -> 3/4, height MAE
//  0.02 m) so the watch can be tested without going on the water. The control
//  session still emits ZERO. Airtime regressed 0.34 -> 0.46 s; accepted.
//    1. HEIGHT IS NOW A MEASUREMENT — flight-window integration of -az, no
//       calibration constants (§3b of evaluate, `flightHeight`). The V16.1
//       matched filter and its heightScale/heightOffsetM stay as the fallback
//       for an unresolved landing; heightFromFlight=false restores V16.1.
//    2. FREE-FALL WINDOW — a ballistic event is bounded exactly by its free
//       fall, which never occurs while riding (0 runs in 187 minutes). Bench
//       height 0.83 -> 0.02 m, every kite log unchanged to the digit.
//    3. popClusterSec 2.0 -> 0.8 — t0 was walking forward onto the LANDING
//       (on a throw the catch is 15-23 g against a 3-6 g release), so the
//       shelf scan started after the flight was over.
//    4. apexAnchorSec 2.0 (new) — decouples the height window from t0 so 3.
//       does not cost log 287 its height (0.519 -> 0.643 m without it).
//    5. minLiftPlateauSec 0.8 -> 0.7 as a FLOOR, with apex corroboration
//       below shelfFullSec. smallLog 12/16 -> 16/16, control still 0.
//    6. The immediate-report path now honours dedup — two jumps both over
//       immediateReportM inside dedupSec used to BOTH fire (one take-off
//       delivered twice, seen as a 4.39 m "phantom" 3.4 s after a real one).
//    7. Distance samples its ORIGIN at t0, not t0-1.0 s, which folded a whole
//       second of riding (~8 m) into every jump. MAE 12.80 -> 6.19 m.
//    8. minReportM 1.4 -> 1.2 — now a pure DISPLAY threshold, since the
//       flight integral has no 1.43 m structural floor.
//    9. minAirtimeSec 1.5 (new) — a dormant floor against regression.
//  Rejected after measurement: see 03_DOCS/REJECTED.md in the handoff.
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

/// Product-supported minimum heights for counting and displaying jumps.
/// Detection still collects the complete candidate so the measured height is
/// accurate; this value is the final acceptance floor applied to that result.
public enum V16MinimumJumpHeight {
    public static let defaultMeters = 1.5
    public static let optionsMeters = [1.5, 2.0, 3.0, 4.0]

    public static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMeters }
        return optionsMeters.min { lhs, rhs in
            abs(lhs - value) < abs(rhs - value)
        } ?? defaultMeters
    }
}

public struct V16Config {
    /// Takeoff pop floor (g). Goldens measured 1.4–4.7 g.
    public var popMinG = 1.4
    /// Two pops closer than this are one takeoff; the stronger anchors t0.
    ///
    /// 0.8, not 2.0. The window governs how far t0 may WALK FORWARD onto a
    /// stronger pop, and a take-off's own pop burst measures 0.80 s median
    /// across the 14 goldens — 2.0 s was far wider than the thing it merges.
    /// On a thrown watch the ordering inverts: the release is 3-6 g and the
    /// CATCH is 15-23 g, 0.9-1.7 s later, so the anchor walked onto the landing
    /// and the shelf scan then started after the flight was over (the watch's
    /// own log: shelf=0.00-0.30 s on a 17 g yank). At 0.8 the anchor stays on
    /// the release and all four bench throws are found; the height is protected
    /// separately by apexAnchorSec.
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
    /// fallback whenever the landing is unresolved. false = V16.1 behaviour.
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
    ///
    /// V16.4: 0.6 is the floor. Lowering it further recovered nothing in the
    /// seven-log suite and introduced a phantom on log 287.
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

    /// User-selected final acceptance floor (m). The engine continues to
    /// measure lower candidates for diagnostics, but it counts and displays
    /// only results at or above this height. The product default is 1.5 m.
    public var minReportM = V16MinimumJumpHeight.defaultMeters
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
    /// The LATEST a candidate may be judged (s) — long enough to cover the
    /// shelf scan and the landing search in the worst case. Measured on the
    /// reference logs: longest shelf 2.8 s, latest landing 6.6 s, widest gap a
    /// MERGE had to bridge 6.4 s.
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
    /// Dormant on all six reference logs; a floor against regression.
    public var minAirtimeSec: TimeInterval = 1.5

    /// V16.3 SETTLE FALLBACK — a second-chance landing for when the
    /// descent-arrest rule never resolves one.
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

    /// V16.3 PHANTOM FILTER — reject a jump whose FLIGHT SIGNATURE IS INCOMPLETE.
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
    /// Absolute on purpose: confidence must not drift when the detection floor
    /// changes.
    public var strongShelfSec: TimeInterval = 1.05
    /// How far before t0 the resolved-flight HEIGHT integral starts (s).
    /// Detection, airtime and distance remain anchored to t0, and a measured
    /// free-fall window is exempt because its physical boundaries are exact.
    public var heightPreRollSec: TimeInterval = 0.5
    /// Tail added after the resolved landing for selected big-air windows.
    public var heightPostRollSec: TimeInterval = 0.8
    /// Trigger A: resolved airtime at or above this value gets the post-roll.
    public var heightPostRollMinAirSec: TimeInterval = 4.0
    /// Trigger B: first-pass height at or above this value gets the post-roll.
    public var heightPostRollMinM: Double = 3.5
    /// Minimum flight span used before adding the post-roll on a triggered jump.
    public var heightPostRollFloorSec: TimeInterval = 5.0
    /// Reported airtime is clipped when it exceeds this multiple of the
    /// ballistic time sqrt(8h/g). This is an outlier guard, not a general cap.
    public var airtimeGuardRatio: Double = 4.0
    /// Multiple of ballistic time to which an outlier is clipped. It stays
    /// below the trigger so the corrected value lands inside the physical band.
    public var airtimeGuardClipRatio: Double = 3.2
    /// Reference calibration: reported = slope * measured + offset.
    /// Identity is the measured optimum for matching Surfr as displayed.
    public var heightCalSlope: Double = 1.0
    public var heightCalOffsetM: Double = 0.0
    /// Let the measured flight window corroborate a short shelf when the fixed
    /// matched-filter window found no apex evidence.
    public var flightCorroboration = true
    /// Minimum measured flight height for deferred corroboration (m). V16.8
    /// keeps this detection threshold at 1.2 m; the 1.5 m report floor is
    /// applied later, after the candidate has been fully measured.
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
    /// Which operator produced `heightM`. The operators are NOT interchangeable and
    /// a session log that does not say which one ran cannot be re-analysed:
    ///   "flight"   — V16.2 integral over the measured flight, in metres.
    ///   "freefall" — the same integral over a measured FREE-FALL window, i.e.
    ///                a ballistic event (a thrown watch), not a kite jump.
    ///   "matched"  — the V16.1 fixed-window matched filter with
    ///                heightScale/heightOffsetM applied. The fallback, taken
    ///                when the landing never resolved.
    /// V16.7 applies heightCalSlope/heightCalOffsetM to every source after its
    /// operator has produced a measured or fallback height.
    public enum HeightSource: String {
        case flight, freefall, matched
    }
    public let heightSource: HeightSource
    /// Reported height (m), after the shared V16.7 reference calibration.
    /// `.matched` remains a calibrated correlate; the other sources are direct
    /// measurements before that final mapping.
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

    // MARK: Flight-path anchors — what the phone needs to DRAW the jump
    //
    // The phone has the take-off fix and a scalar distance, so it cannot know
    // which WAY the jump went and draws a straight chord from the GPS track's
    // bearing. Measured against the mid-flight fixes on log 287 that chord is
    // 8.09 m out; adding the landing and apex positions takes it to 4.55 m for
    // ~16 bytes. The full 64-point reconstructed arc costs 48x the bytes and is
    // no better (5.10 m) — it carries the integration's high-frequency noise,
    // while a quadratic through these three anchors does not.
    //
    // ⚠️ ALL nil when the landing is unresolved: there is no flight window, so
    // there is no apex and no landing fix. The phone renders nothing rather
    // than a guess — do NOT substitute defaults.
    public let landLat: Double?
    public let landLng: Double?
    public let apexLat: Double?
    public let apexLng: Double?
    /// Apex time as a fraction of the flight, 0...1 — the VERTICAL shape.
    /// Measured 0.33-0.61 across the 14 log-287 goldens (median 0.40), so it is
    /// a real per-jump quantity; without it the phone assumes 0.42 for every
    /// jump.
    public let riseFraction: Double?

    // MARK: Rider diagnostics
    //
    // Each was measured on the 14 log-287 goldens and kept only because its
    // spread is real. A metric whose spread is noise is a fake feature.

    /// Peak load around touchdown (g). Measured 0.5-1.9 g (median 1.1).
    ///
    /// ⚠️ The window may be TRUNCATED. It runs to landingT + 0.7 s, but a jump
    /// over immediateReportM is finalised the moment `now` reaches the landing,
    /// so the tail usually has not been sampled yet. Widening the emission
    /// guard to wait for it would add ~0.7 s of latency to every big jump —
    /// an algorithm change, which this payload work is explicitly not. Read it
    /// as "peak load at touchdown", not as a fixed-support statistic.
    public let landingImpactG: Double?
    /// Gyro integral over the flight, in revolutions. Measured 0.59-1.79
    /// (median 1.18). This is the WRIST's rotation — an arm movement counts —
    /// so the UI must call it a rotation index, never a spin count.
    public let rotationRevs: Double?
    /// Mean load over the 1.5 s BEFORE the pop (g): how hard the rider was
    /// carving into the send. Measured 0.41-1.14 g (median 0.72). Independent
    /// of the landing, so it survives an unresolved one.
    public let edgeLoadG: Double?
}

public protocol JumpEngineV16Delegate: AnyObject {
    func jumpDetected(_ jump: V16Jump)
}

// MARK: - Engine

public final class JumpEngineV16 {
    /// Engine version. Bump whenever a default or a rule changes, so a replay
    /// can be attributed to the exact engine that produced it.
    public static let version = "16.8"


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
            // DIAGNOSTICS ONLY — no verdict depends on this branch.
            //
            // A log with no attitude at all makes every bin NaN, so the shelf
            // measures exactly 0.00 s and the rejection is indistinguishable
            // from real chop. That is how a whole session of `noLiftPlateau
            // shelf=0.00s` reads as "the gate is working" when in fact the
            // engine never had a vertical channel to look at. `noAttitude`
            // above only fires when the window itself is too short.
            //
            // NOTE for whoever syncs the TS twin: this reason text is Swift-only
            // for now. The verdict, and therefore every emitted jump, is
            // identical — the twin prints noLiftPlateau for this same case.
            if bins.finiteCount == 0 {
                onDebug(now, "REJECT t0=\(fmt(t0)) reason=noAttitudeInWindow yank=\(fmt(c.yankG))g")
                return true
            }
            onDebug(now, "REJECT t0=\(fmt(t0)) reason=noLiftPlateau shelf=\(fmt(shelf))s yank=\(fmt(c.yankG))g")
            return true
        }

        // 2. The matched-filter apex — the V16.2 height FALLBACK, and still the
        //    corroborating evidence for a short shelf.
        //
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
            // The fixed 4.5 s window can miss long flights. V16.4 defers this
            // verdict until the measured flight window is available below.
            if !cfg.flightCorroboration {
                onDebug(now, "REJECT t0=\(fmt(t0)) reason=shortShelfNoApex shelf=\(fmt(shelf))s apex=\(fmt(apex))")
                return true
            }
        }

        // 3. Airtime (low confidence) — resolved BEFORE the height, because the
        //    height now wants the flight window (see 3b).
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
        // 3 of the 37 real jumps across the reference logs never resolve one.
        if let lt = landingT, lt - t0 < cfg.minAirtimeSec {
            onDebug(now, "REJECT t0=\(fmt(t0)) reason=airtimeTooShort air=\(fmt(lt - t0))s")
            return true
        }

        // 3b. HEIGHT.
        //
        // V16.2 replaces the calibrated matched filter with a direct measurement.
        // Over the FLIGHT window, endpoint-anchored double integration of the TRUE
        // vertical acceleration returns the apex in METRES, before V16.7's
        // shared reference-calibration stage. Pooled over 37 goldens from five
        // sessions it measures 0.317 m
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
        // t0 is the strongest POP sample, after the rider has already begun to
        // rise. Include the measured 0.5 s lead-in in the height integral only.
        // A free-fall throw keeps its exact measured boundaries; all detection,
        // airtime and GPS-distance anchors continue to use the original t0.
        if !ballistic, winB != nil {
            winA = t0 - cfg.heightPreRollSec
        }
        // The descent-arrest rule can close while a big-air rider is still
        // descending. This presents as either long airtime with a low height or
        // a tall first pass with short airtime, so the post-roll has two
        // independent triggers. Since this is a streaming engine, do not ask
        // flightHeight() for samples that have not arrived: defer until the
        // requested tail is resident, or use the available tail when forced at
        // the evaluation deadline. A measured free-fall window is exact and is
        // never widened.
        if !ballistic, let resolvedLanding = winB, cfg.heightPostRollSec > 0 {
            let airtime = resolvedLanding - t0
            let firstPass = cfg.heightFromFlight
                ? flightHeight(t0: winA, landingT: resolvedLanding)
                : nil
            let shouldPostRoll = airtime >= cfg.heightPostRollMinAirSec
                || (firstPass?.heightM ?? -.infinity) >= cfg.heightPostRollMinM
            if shouldPostRoll {
                let requestedEnd = t0
                    + max(airtime, cfg.heightPostRollFloorSec)
                    + cfg.heightPostRollSec
                if let last = ring.last {
                    if last.t < requestedEnd, !forced { return false }
                    winB = min(requestedEnd, last.t)
                } else {
                    winB = requestedEnd
                }
            }
        }
        let flight = (cfg.heightFromFlight && winB != nil)
            ? flightHeight(t0: winA, landingT: winB!) : nil
        var flightH: Double? = flight?.heightM
        // Deferred corroboration: when the fixed window found no usable apex,
        // the measured flight must independently clear the reporting floor.
        if needsCorroboration,
           flightH == nil || flightH! < cfg.shortShelfFlightM {
            let flightText = flightH.map(fmt) ?? "none"
            onDebug(now, "REJECT t0=\(fmt(t0)) reason=shortShelfNoApex shelf=\(fmt(shelf))s apex=\(fmt(apex)) flight=\(flightText)")
            return true
        }
        // A ballistic event may be reported as peak-above-release (1.0) or as
        // total vertical path (2.0). See throwHeightScale.
        if let f = flightH, ballistic, cfg.throwHeightScale != 1 {
            flightH = f * cfg.throwHeightScale
        }
        // One explicit reference-calibration stage. The shipped identity is a
        // measured optimum for Surfr-as-displayed, not an unset default. The
        // alternative videogrammetric mapping (0.8025 / +0.7309) remains a
        // documented research target and must not ship without our own video.
        let measuredHeightM = flightH ?? (cfg.heightScale * apex + cfg.heightOffsetM)
        let heightM = cfg.heightCalSlope * measuredHeightM + cfg.heightCalOffsetM
        guard heightM >= cfg.minReportM else {
            // FINAL even when not forced: both windows have closed, so no later
            // sample can raise this height.
            onDebug(now, "REJECT t0=\(fmt(t0)) reason=belowMinReport h=\(fmt(heightM))m "
                + "src=\(flightH != nil ? "flight" : "matched")")
            return true
        }

        // 4. Flight statistics.
        let tEnd = landingT ?? (t0 + cfg.apexPostSec)
        var peakG = 0.0, maxGyro = 0.0, floatN = 0, n = 0
        // The rotation index rides along on this same walk: |omega| integrated
        // over the flight, rectangle rule at the sample spacing. Only published
        // when a landing bounded the window.
        var gyroRadians = 0.0
        var prevT: TimeInterval?
        for i in ringHead..<ring.count {
            let s = ring[i]
            if s.t < t0 { continue }
            if s.t > tEnd { break }
            n += 1
            peakG = max(peakG, s.load)
            maxGyro = max(maxGyro, s.gyro)
            if s.load <= cfg.floatLoadG { floatN += 1 }
            if let p = prevT, s.t - p <= cfg.maxAttitudeGapSec { gyroRadians += s.gyro * (s.t - p) }
            prevT = s.t
        }
        // 4b. PHANTOM FILTER (see cfg.phantomFilter). Here because it needs both
        // the shelf and the FINISHED height, and it must run BEFORE the dedup
        // hold so a rejected candidate never displaces a real jump sitting in
        // `pending`. It reads the ARREST rule, not landingT — the settle
        // fallback may well have supplied the window this height was measured
        // over, and that is a separate question from whether it was a jump.
        if cfg.phantomFilter && !land0.fromArrest {
            let short = shelf < cfg.phantomShelfSec
            let shortAndSmall = shelf < cfg.phantomShelfWideSec && heightM < cfg.phantomWideHeightM
            if short || shortAndSmall {
                onDebug(now, "REJECT t0=\(fmt(t0)) reason=incompleteFlight "
                    + "shelf=\(fmt(shelf))s h=\(fmt(heightM))m noArrest")
                return true
            }
        }

        // Two different questions, two different fixes. SPEED wants the entry
        // velocity a moment before the pop starts bleeding it off, so it samples
        // at t0-1.0. DISPLACEMENT must start where the rider actually left the
        // water: sampling it 1 s early folded a whole second of riding into every
        // jump (~8 m at 30 km/h). Measured on smallLog that alone was +12.8 m of
        // bias; splitting them takes distance MAE 12.80 -> 6.19 m there and
        // 4.94 -> 3.87 m on log 287.
        let launch = gpsPoint(near: t0 - 1.0)
        let launchPos = gpsPoint(near: t0)
        let land = gpsPoint(near: tEnd)
        var distanceM: Double?
        if let launchPos, let land, (launchPos.lat != 0 || launchPos.lng != 0), (land.lat != 0 || land.lng != 0) {
            distanceM = Self.haversineM(launchPos.lat, launchPos.lng, land.lat, land.lng)
        } else if let launch, let landingT {
            distanceM = launch.spd * (landingT - t0)
        }
        // An unresolved landing leaves tEnd at apexPostSec, which is not a
        // measured flight window. Reporting that truncated chord as distance
        // is worse than reporting the measurement as unavailable.
        if landingT == nil { distanceM = nil }

        // ── AIRTIME OUTLIER GUARD (16.8). A kite carries the rider, so airtime
        // normally exceeds the ballistic time sqrt(8h/g), but the measured
        // reference population stays inside a bounded ratio. Values beyond the
        // 4.0 trigger are landing-resolution outliers, not longer jumps.
        //
        // This changes only reported airtime and its derived GPS distance. The
        // final height, detection decision, and integration window stay exactly
        // as measured above.
        var airtimeSec = landingT.map { $0 - t0 }
        if var airtime = airtimeSec, cfg.airtimeGuardRatio > 0, heightM > 0 {
            let ballistic = (8 * heightM / g0).squareRoot()
            if airtime > cfg.airtimeGuardRatio * ballistic {
                let clipped = cfg.airtimeGuardClipRatio * ballistic
                onDebug(now, "AIRTIME GUARD t0=\(fmt(t0)) h=\(fmt(heightM))m "
                    + "air=\(fmt(airtime))s ratio=\(fmt(airtime / ballistic)) "
                    + "-> \(fmt(clipped))s")
                airtime = clipped
                airtimeSec = clipped
                if distanceM != nil,
                   let launchPos,
                   let clippedLanding = gpsPoint(near: t0 + airtime),
                   clippedLanding.lat != 0 || clippedLanding.lng != 0 {
                    distanceM = Self.haversineM(
                        launchPos.lat,
                        launchPos.lng,
                        clippedLanding.lat,
                        clippedLanding.lng
                    )
                }
            }
        }

        // The drawing anchors and the post-flight diagnostics. Everything that
        // needs a bounded flight is nil without one; edgeLoadG is measured
        // entirely BEFORE the pop, so it survives an unresolved landing.
        let apexFix = flight.flatMap { gpsPoint(near: $0.apexT) }
        var riseFraction: Double?
        if let apexT = flight?.apexT, let lt = landingT, lt > t0 {
            riseFraction = min(max((apexT - t0) / (lt - t0), 0), 1)
        }
        let landingImpactG = landingT.flatMap { peakLoad(from: $0 - 0.3, to: $0 + 0.7) }
        let rotationRevs = landingT == nil ? nil : gyroRadians / (2 * Double.pi)
        let edgeLoadG = meanLoad(from: t0 - 1.5, to: t0)

        let jump = V16Jump(
            heightSource: flightH == nil ? .matched : (ballistic ? .freefall : .flight),
            heightM: round2(heightM),
            apexRawM: round2(apex),
            airtimeSec: airtimeSec.map(round2),
            takeoffT: t0,
            liftPlateauSec: round2(shelf),
            yankG: round2(c.yankG),
            peakG: round2(peakG),
            floatFraction: n > 0 ? round2(Double(floatN) / Double(n)) : 0,
            maxGyroRadS: round2(maxGyro),
            takeoffSpeedMS: launch.map { round2($0.spd) },
            distanceM: distanceM.map(round2),
            confidence: shelf >= cfg.strongShelfSec ? 0.75 : 0.55,
            landLat: landingT == nil ? nil : land?.lat,
            landLng: landingT == nil ? nil : land?.lng,
            apexLat: apexFix?.lat,
            apexLng: apexFix?.lng,
            riseFraction: riseFraction.map(round2),
            landingImpactG: landingImpactG.map(round2),
            rotationRevs: rotationRevs.map(round2),
            edgeLoadG: edgeLoadG.map(round2)
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
                onDebug(now, "DROP t0=\(fmt(t0)) h=\(fmt(heightM))m duplicate of delivered "
                    + "\(fmt(le.heightM))m at \(fmt(le.t0))")
                return true
            }
            if let h = held, t0 - h.jump.takeoffT < cfg.dedupSec {
                onDebug(now, "MERGE t0=\(fmt(h.jump.takeoffT)) into \(fmt(t0)) (\(fmt(h.jump.heightM))m < \(fmt(heightM))m)")
                held = nil
            }
            lastEmit = (t0, heightM)
            delegate?.jumpDetected(jump)
            onDebug(now, "JUMP t0=\(fmt(t0)) h=\(fmt(heightM))m IMMEDIATE shelf=\(fmt(shelf))s "
                + "air=\(jump.airtimeSec.map(fmt) ?? "n/a")s src=\(jump.heightSource.rawValue)")
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
            + "air=\(h.jump.airtimeSec.map(fmt) ?? "n/a")s yank=\(fmt(h.jump.yankG))g "
            + "src=\(h.jump.heightSource.rawValue)")
    }

    // MARK: Signal helpers

    private struct Bins {
        let t: [TimeInterval]
        let az: [Double]
        /// Bins that actually carried an attitude sample. Diagnostics only —
        /// zero means the window had no vertical channel at all, which is a
        /// very different thing from a window with no lift in it.
        let finiteCount: Int
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
        var finiteCount = 0
        for k in 0..<nBins {
            t[k] = from + Double(k) * step
            if attCnt[k] > 0 {
                azRaw[k] /= Double(attCnt[k])
                finiteCount += 1
            } else {
                azRaw[k] = Double.nan
            }
        }
        let w = max(0, Int((cfg.liftSmoothSec / step).rounded()))
        return Bins(t: t, az: Self.boxSmooth(azRaw, halfWidth: w), finiteCount: finiteCount)
    }

    /// Landing = the moment the DESCENT IS ARRESTED. LOW CONFIDENCE — see the
    /// file header.
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
    ///
    /// V16.3 wraps this: `landing()` below tries the arrest rule first and falls
    /// back to `settleLanding()` at the deadline. `fromArrest` carries which one
    /// answered, which is what the phantom filter reads.
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
        // currently kept with airtime reported as "not measured". Turning that
        // into a rejection would trade height accuracy for recall.
        guard let settle = settleLanding(t0: t0), settle - t0 >= cfg.minAirtimeSec else {
            return (nil, false)
        }
        return (settle, false)
    }

    /// The specific force returns to ~1 g and STAYS there: the rider is back on
    /// the water and tracking it. Fallback only — see `landSettleFallback`.
    ///
    /// Runs on specific force, NOT on |userAcceleration|: sf is 1 at rest and 0
    /// in free fall regardless of attitude, so "back to 1 g" is a
    /// frame-independent statement about being supported again. |ua| reads
    /// ~1.0 g in free fall and would say the opposite.
    ///
    /// Reports the START of the settled run, which is where support resumes;
    /// the end would be an arbitrary landSettleMinSec later.
    ///
    /// `prevT` advances on every sample including rejected ones, so a reset run
    /// re-accumulates with the real sample spacing instead of assuming a fixed
    /// rate. The watch runs at 50 Hz and the reference logs at 200 Hz — that is
    /// the only reason the same constants hold on both.
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
            let sf = specificForce(s)
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

    /// The primary rule — the contract above describes this function.
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

    /// The specific force a sample actually felt, in g: 1.0 at rest, 0.0 in free
    /// fall. No extra state is needed — with `load` = |userAcceleration| and
    /// wz = az/g0 the world-vertical component,
    ///
    ///     sf^2 = |ua + gravity|^2 = (load^2 - wz^2) + (wz - 1)^2 = load^2 - 2*wz + 1
    ///
    /// (at rest load=0, wz=0 -> 1; in free fall load=1, wz=1 -> 0).
    ///
    /// NOTE: an INSTANCE method, unlike the handoff's copy — `g0` is an instance
    /// property here, so the shipped `private static func` referencing `G0` does
    /// not compile against this file.
    private func specificForce(_ s: Sample) -> Double {
        guard s.az.isFinite else { return .nan }
        let v = s.load * s.load - 2 * (s.az / g0) + 1
        return v > 0 ? v.squareRoot() : 0
    }

    /// The longest sustained FREE FALL inside [from, to], or nil.
    ///
    /// This is the only integration window that is exactly right by definition,
    /// and both its edges are sharp to a single sample. It cannot fire on a kite
    /// jump — a rider hangs from the canopy and is never unloaded, measured as
    /// ZERO runs across 187 minutes of riding and control logs — so it can only
    /// ever replace the window on a genuinely ballistic event such as a throw.
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
            let sf = specificForce(s)
            if sf.isFinite && sf < cfg.freeFallG { if a < 0 { a = s.t } } else { close(prevT) }
            prevT = s.t
        }
        close(prevT)
        return bestB - bestA >= cfg.minFreeFallSec ? (bestA, bestB) : nil
    }

    /// V16.2 height: endpoint-anchored double integration of the TRUE vertical
    /// acceleration (-az) over the flight, returning the apex in metres.
    ///
    /// z(t) = the double integral of -az with z(0) = z(T) = 0 enforced by removing
    /// the linear trend. The anchoring is what makes it usable: the rider starts
    /// and ends at the water, so any constant velocity or acceleration bias is
    /// absorbed by the chord and only the CURVATURE — the actual arc — survives.
    /// Unlike apex(), the support is the MEASURED flight, so the result is metres
    /// and needs no calibration. nil when attitude does not cover the window.
    ///
    /// Returns the apex TIME alongside the height. That instant is the only
    /// place the reconstructed trajectory can be sampled from — the payload's
    /// apex position and rise fraction both hang off it — and it is already in
    /// hand at the point the maximum is found, so it costs nothing to report.
    private func flightHeight(t0: TimeInterval,
                              landingT: TimeInterval) -> (heightM: Double, apexT: TimeInterval)? {
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
        var peakI = 0
        for i in 0..<n {
            let c = z[i] - (rel[i] / T) * zT
            if c > peak { peak = c; peakI = i }
        }
        return peak.isFinite ? (peak, ts[peakI]) : nil
    }

    /// Peak |userAcceleration| in [from, to] (g), or nil when the ring holds
    /// nothing there. The window is clipped by whatever has been SAMPLED — see
    /// the truncation note on V16Jump.landingImpactG.
    private func peakLoad(from: TimeInterval, to: TimeInterval) -> Double? {
        var peak: Double?
        for i in ringHead..<ring.count {
            let s = ring[i]
            if s.t < from { continue }
            if s.t > to { break }
            peak = max(peak ?? 0, s.load)
        }
        return peak
    }

    /// Mean |userAcceleration| in [from, to] (g), or nil when the ring holds
    /// nothing there. historySec is 14.0 s, so the 1.5 s of pre-pop carve this
    /// is asked for is always still resident — no buffer change was needed.
    private func meanLoad(from: TimeInterval, to: TimeInterval) -> Double? {
        var sum = 0.0, count = 0
        for i in ringHead..<ring.count {
            let s = ring[i]
            if s.t < from { continue }
            if s.t > to { break }
            sum += s.load
            count += 1
        }
        return count > 0 ? sum / Double(count) : nil
    }

    /// Where the apex window should centre: the strongest load sample in
    /// [t0, t0 + apexAnchorSec]. Returns t0 when nothing beats it, so
    /// apexAnchorSec = 0 is an exact no-op.
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
    ///
    /// V16.2 note: the SAME anchoring argument applies to `flightHeight` below,
    /// which is this integral run over the measured flight instead of a fixed
    /// window — and therefore returns metres rather than a correlate.
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
