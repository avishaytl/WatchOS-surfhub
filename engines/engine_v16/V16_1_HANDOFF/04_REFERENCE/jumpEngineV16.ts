/**
 * jumpEngineV16.ts — TS twin of JumpEngineV16.swift.  ENGINE VERSION 16.1
 *
 * V16 is a BIG-AIR-first engine. It abandons the barometer as a height source
 * and reconstructs the vertical channel from the IMU alone. The design comes
 * from the 28–31.7 research on log 287 (14 Surfr goldens, 2.1–8.5 m) plus a
 * negative-control session (693 s of pops and waves with ZERO real jumps):
 *
 *  1. TRIGGER — a pop ≥ popMinG. Big-air takeoffs are NOT violent: the ten
 *     goldens measured 1.4–4.7 g, so V15's 3.0 g floor threw half of them away.
 *
 *  2. CONFIRM — the LIFT PLATEAU. During a kite jump the canopy pulls the rider
 *     up for a full second or more; world-vertical acceleration stays positive
 *     in a sustained shelf. A wave or chop bump is an impulse that is over in
 *     ≤0.6 s. Measured: real jumps 0.9–2.8 s of shelf, control session max 0.6 s
 *     over 19 pops. At the 0.9 s threshold this single test keeps 14/14 real
 *     jumps and admits 0/19 control pops — the phantom firewall, no GPS needed.
 *
 *  3. HEIGHT — bounded double integration of world-vertical acceleration over a
 *     FIXED window around the pop, with z(0)=z(T)=0. The apex is then a LINEAR
 *     FUNCTIONAL of the acceleration with support T, and two jumps compare only
 *     if the SAME functional is applied — i.e. the same T. With a per-jump
 *     window (even the TRUE airtime) each jump gets a different operator and
 *     the correlation collapses to r≈0; with the fixed window it is r=0.95. This is a matched filter, not a trajectory reconstruction —
 *     its output is mapped to metres by a linear calibration.
 *     Validated: MAE 0.52 m over all 14 goldens spanning 2.1–8.5 m (LOO 0.57 m
 *     on the 12-jump subset it was fitted on); adding the two largest goldens
 *     did not move the slope (1.91 before and after).
 *
 *  4. AIRTIME — reported at LOW confidence only. The landing rule below tracks
 *     lift-shelf → dip → sustained float, but measured MAE is 0.54 s while a
 *     constant predictor scores 0.78 s, so it barely beats a constant. Treat
 *     `airtimeSec` as an estimate, never as a gate.
 *
 *  5. DISTANCE — derived, so it INHERITS the airtime error: haversine between
 *     the GPS fix before the pop and the one at the estimated landing. With the
 *     true airtime it measures 2.78 m MAE; with V16's own airtime, 6.27 m
 *     (0.54 s x ~8 m/s). takeoffSpeedMS, by contrast, is measured directly from
 *     GPS before the pop and is accurate to 0.64 m/s.
 *
 * NOT used, and why (each was measured, not assumed):
 *   • absoluteAltitude — healthy on only 7/21 goldens, and when the health gate
 *     DID pass it still produced −6.4 m and −2.1 m errors (negative apex for a
 *     real jump = water on the port). No available signal predicts when it is
 *     trustworthy, so fusing it would inject metre-scale errors into a 0.57 m
 *     estimator.
 *   • takeoff board speed (GPS) — a real discriminator, deliberately NOT used.
 *     All 19 matched goldens took off at 20.9–37 km/h while one stray emission
 *     sat at 3 km/h, so a 10 km/h gate removes it at zero cost to recall. It is
 *     omitted anyway: DETECTION MUST NOT DEPEND ON GPS. A gate here would break
 *     bench testing (throwing the watch by hand), and would silently lose jumps
 *     whenever the fix is cold, indoors, or dropped for battery. Its whole
 *     measured benefit was ONE sub-1.5 m emission across ~2 h of logging —
 *     far less than a GPS dependency costs. Speed stays an OUTPUT, never a gate.
 *   • relativeAltitude / raw pressure — alive (71 % distinct, max 5 s freeze)
 *     but useless per-jump: 67 of the 68 inter-sample steps above 3 m fall
 *     OUTSIDE any jump. The noise exceeds the signal in the same band, so no
 *     filter or drift reset can recover it (measured r = 0.19–0.31).
 *
 * ── V16.1 ────────────────────────────────────────────────────────────────
 * Changes since V16.0, each measured before being kept:
 *   1. heightOffsetM 1.50 -> 1.43 — refitted on all 23 goldens across three
 *      sessions instead of big air alone. Better in BOTH regimes.
 *   2. minReportM 1.5 -> 1.4 — the engine's floor output IS 1.43 m, so a 1.5 m
 *      report floor censored the whole band it can produce. +1 recall, free.
 *   3. LANDING REWRITTEN — landing is now the END of the sustained descent
 *      (the water arresting it), not a dip confirmed by sustained "float".
 *      The float confirmation never arrived (the arm keeps working the bar)
 *      and returned null on 2 of 19 goldens. Airtime 14/14 at 0.34 s LOO.
 *   4. boxSmooth NaN fix — a single empty 0.1 s bin used to poison every later
 *      bin, so the lift shelf could never be found again. Latent at 200 Hz,
 *      live on the watch where a 0.1 s bin holds only 5 samples.
 *   5. LATENCY 17.0 -> 7.5 s for jumps >= immediateReportM. The result now
 *      lands 0.9-3.9 s after the rider does, instead of 8-12 s after.
 *   6. floatLoadG documentation corrected: it measures SETTLED motion, not
 *      free fall — |userAcceleration| reads ~1.0 g in free fall, not ~0.
 * Rejected after measurement and recorded so they are not retried: an impulse
 * (area) lift gate, and a GPS takeoff-speed gate (detection must not need GPS).
 *
 * SAMPLE RATE: the calibration was fitted on 200 Hz logs. The watch samples at
 * 50 Hz; a trapezoidal double integral is insensitive to that, but if the rate
 * is changed the calibration should be re-checked.
 */

export interface V16Config {
  /** takeoff pop floor (g). Goldens measured 1.4–4.7 g. */
  popMinG: number;
  /** two pops closer than this are the same takeoff; the stronger wins. */
  popClusterSec: number;

  /** world-vertical acceleration above this counts as "lift" (m/s²). */
  liftThreshMS2: number;
  /** half-width of the box smoother applied to the lift signal (s). */
  liftSmoothSec: number;
  /** the phantom firewall: required continuous lift shelf (s). */
  minLiftPlateauSec: number;
  /** how far past the pop the shelf is searched for (s). */
  plateauScanSec: number;

  /* Rejected experiment, recorded so it is not retried blind: gating the
   * firewall on the shelf's AREA (m/s^2*s) instead of on amplitude and duration
   * separately. Offline it looked decisive — over the 23 goldens and the 52 pop
   * clusters of the pops-and-waves control the populations separated with no
   * overlap. On the real engine it was not robust: impulse >= 3.0 gave 20/23
   * with 1 control false positive, 3.2 gave 18/23 with 0, and the surviving
   * margin between the lowest golden and the highest chop event was
   * 0.08 m/s^2*s. Too thin to ship. */

  /** Fixed apex window, before and after the pop (s). Do not tune without
   *  re-fitting heightScale/heightOffsetM — the calibration is tied to it.
   *
   *  "apex" is a NAME, not a trajectory apex. Measured on all 14 log-287
   *  goldens, the argmax of the bounded double integral falls at t0-1.15 s to
   *  t0+0.01 s — at or BEFORE the pop, on every jump, big or small. The
   *  operator reports a curvature contrast over a fixed support that happens to
   *  correlate with height (r=0.95), not the height of the flight.
   *
   *  So the intuition that a bigger jump needs a longer window is wrong twice
   *  over: the window never contained the physical apex to begin with, and
   *  lengthening it is measurably worse. Swept on the engine with the
   *  calibration refitted for each window, MAE over 19 goldens:
   *    [-2.5,+2.0] 0.427 m  <- shipped
   *    [-2.5,+2.5] 0.895 m
   *    [-2.5,+3.0] 0.984 m
   *    [-2.5,+3.5] 1.461 m
   *  A longer support admits more riding than flight.
   *
   *  NOTE the calibration is fitted over 2.1-8.5 m. Beyond that it is pure
   *  extrapolation of a correlate, and a 20 m+ jump cannot be trusted without
   *  a raw log to calibrate against. */
  apexPreSec: number;
  apexPostSec: number;
  /** h = heightScale · apex + heightOffsetM.
   *  Fitted on all 23 goldens across three sessions (2.1-8.5 m big air plus
   *  1.26-2.48 m small jumps), not on big air alone: the combined fit is better
   *  in BOTH regimes (big-air MAE 0.53 -> 0.52 m, small-jump MAE 0.34 -> 0.29 m,
   *  overall 0.45 -> 0.43 m, LOO 0.47 m over all 23). */
  heightScale: number;
  heightOffsetM: number;

  /** Jumps below this are not reported (m).
   *  1.4, not 1.5: with heightOffsetM = 1.43 the engine's floor output is
   *  1.43 m, so a 1.5 m report floor censored the entire saturated small-jump
   *  band. Measured over the 23 goldens, 1.5 -> 1.4 recalls one more real jump
   *  (18/23 -> 19/23), lowers MAE 0.44 -> 0.43 m and still emits NOTHING on the
   *  pops-and-waves control. Lowering it further changes nothing, since 1.43 m
   *  is the smallest height the calibration can produce. */
  minReportM: number;
  /** two emissions closer than this are the same jump; the higher wins. */
  dedupSec: number;
  /** A jump at or above this height is delivered the moment it is judged,
   *  skipping the dedup hold (m).
   *
   *  The hold exists for one reason: a weak precursor pop can be confirmed
   *  before the real takeoff, and only the stronger of the pair may reach the
   *  rider. Over every MERGE the reference logs produce, the precursor that
   *  lost measured 1.43-2.09 m while the winner measured 3.47-7.65 m — the two
   *  populations do not overlap. So above ~2.5 m nothing can supersede the
   *  jump, and waiting out dedupSec buys nothing but latency.
   *
   *  This matters because the hold is what put the number on the wrist at
   *  t0+14.5 s, roughly 8-11 s after the rider was back on the water. Skipping
   *  it delivers at t0+7.5 s — within 5 s of every observed landing, and with
   *  airtime and distance already resolved, so the emission is complete rather
   *  than provisional. */
  immediateReportM: number;
  /** The LATEST a candidate may be judged (s) — long enough to cover the
   *  plateau scan and the landing search in the worst case. */
  evalDelaySec: number;
  /** The EARLIEST a candidate may be judged (s).
   *
   *  A small jump is over in a couple of seconds; there is no reason to make it
   *  wait out a budget sized for the longest flight in the session. From this
   *  moment the candidate is judged on every batch, and it is FINALISED as soon
   *  as the answer is already knowable — the apex window has closed (that is
   *  t0 + apexPostSec) and the landing has been found. If the lift shelf has
   *  not yet accrued, or the descent has not yet been arrested, the candidate
   *  stays pending and is retried, up to evalDelaySec.
   *
   *  Nothing observed later can change a verdict reached this way: the apex
   *  window is closed, and the shelf gate only ever ACCUMULATES. */
  fastEvalSec: number;

  // — landing / airtime (low confidence, see header) —
  /** the lift shelf must open above this and then close, before a landing is
   *  looked for (m/s²). */
  landLiftThreshMS2: number;
  /** how long that shelf must hold (s). */
  landMinPlateauSec: number;
  /** world-vertical acceleration below this counts as DESCENT (m/s²). */
  landDipMS2: number;
  /** How long the descent must be sustained to count (s). */
  landDipMinSec: number;
  /** Added to the arrest instant to reach the reported landing (s).
   *  The descent-end bin is where world-vertical acceleration climbs back above
   *  landDipMS2, which precedes full water contact — the rule runs early by a
   *  consistent margin on every reference jump. Fitted as the MEDIAN residual
   *  (the MAE-optimal constant) over the 14 HOOLAN reference airtimes for
   *  log 287, and validated leave-one-out: the offset is refitted on 13 jumps
   *  and scored on the held-out 14th, giving 0.34 s LOO MAE against 0.50 s raw
   *  and 0.75 s for a constant predictor. One parameter on 14 points. */
  landOffsetSec: number;
  /** |a| at or below this counts as SETTLED motion (g).
   *  NOT free fall, despite what this field was originally called. The stream
   *  is |userAcceleration|, which reads ~0 g at REST and ~1.0 g in true free
   *  fall — so a low value means "not being thrown around", not "airborne".
   *  That is still the right test for confirming a landing (the rider has
   *  settled and is tracking the water again), and it is meaningful in flight
   *  too: a kite carries the rider at near-constant velocity, so a_true stays
   *  small. It must NOT be reused as a free-fall or airborne detector. */
  floatLoadG: number;

  /** Largest tolerated hole between two attitude-carrying samples inside the
   *  apex window (s). Scattered jitter is integrated straight through — the
   *  trapezoid rule handles uneven spacing — but a hole longer than this cannot
   *  be integrated across and rejects the candidate. 0.15 s = 7 missed samples
   *  at the watch's 50 Hz. */
  maxAttitudeGapSec: number;
  /** ring-buffer horizon (s). Must exceed apexPreSec + evalDelaySec. */
  historySec: number;
}

/** Engine version. Bump whenever a default or a rule changes, so a replay
 *  can be attributed to the exact engine that produced it. */
export const V16_VERSION = "16.1";

export const V16_DEFAULTS: V16Config = {
  popMinG: 1.4,
  popClusterSec: 2.0,

  // 2-D sweep over az-threshold x duration on all four logs (research 1):
  // duration is worth ~10x the threshold. Dropping az 2.00 -> 1.00 at a fixed
  // 0.8 s costs almost nothing; dropping the duration 0.8 -> 0.5 at a fixed
  // 1.25 opens 12 control false positives. Physics: a wave is a strong SHORT
  // impulse, so only the sustained shelf separates it from a kite lift.
  // 1.25 / 0.8 dominates the previous 1.5 / 0.9: recall 17/23 -> 19/23 with
  // the same single true phantom and still ZERO control false positives.
  liftThreshMS2: 1.25,
  liftSmoothSec: 0.2,
  minLiftPlateauSec: 0.8,
  plateauScanSec: 7.0,

  apexPreSec: 2.5,
  apexPostSec: 2.0,
  heightScale: 1.91,
  heightOffsetM: 1.43,

  minReportM: 1.4,
  // Latency budget, set by the product requirement: the number must reach the
  // wrist within 5 s of the LANDING, not of the takeoff.
  //
  // dedupSec is the window in which a later, stronger candidate may still
  // supersede an earlier one. It is NOT about the several pops of a single
  // takeoff — popClusterSec already merges those, and a takeoff's pop burst
  // measures 0.80 s median across the 14 goldens. This window is about a weak
  // candidate that clears the whole lift gate on its own shortly BEFORE the
  // real jump.
  //
  // 6.0 s, because the observed precursor gaps cluster at 2.5-3.0 s and
  // 5.0-5.5 s, and a rider physically cannot land, regain speed and launch
  // again inside that span — anything there is the same event or noise. A
  // shorter window was tried and the 5 s pairs leaked straight onto the watch:
  // at 3.0 s log 287 reported 20 jumps where 14 are real, the two extras being
  // a 1.59 m entry 5.0 s ahead of a 3.63 m jump and a 1.51 m entry 5.1 s ahead
  // of a 3.78 m one. Both read as nonsense to a rider.
  //
  // 6.0 matches 7.0 on every measure (18 emissions, 14/14 goldens, MAE 0.43 m,
  // control FP 0) and costs 0.5 s of latency on the slowest small jump versus
  // 3.0. Big air is unaffected either way — it skips the hold entirely.
  dedupSec: 6.0,
  immediateReportM: 2.5,
  evalDelaySec: 7.5,
  fastEvalSec: 3.0,

  landLiftThreshMS2: 0.5,
  landMinPlateauSec: 0.4,
  landDipMS2: -0.5,
  landDipMinSec: 0.6,
  landOffsetSec: 0.4,
  floatLoadG: 0.6,

  maxAttitudeGapSec: 0.15,
  historySec: 14.0,
};

export interface V16Jump {
  /** calibrated height (m). */
  heightM: number;
  /** raw matched-filter apex before calibration (m) — for diagnostics. */
  apexRawM: number;
  /** LOW CONFIDENCE (see header). null when the landing was never resolved. */
  airtimeSec: number | null;
  takeoffT: number;
  /** measured lift-shelf length (s) — the confirmation statistic. */
  liftPlateauSec: number;
  yankG: number;
  peakG: number;
  floatFraction: number;
  maxGyroRadS: number;
  takeoffSpeedMS: number | null;
  distanceM: number | null;
  /** 0.75 with a strong shelf, 0.55 at the threshold. */
  confidence: number;
}

interface Sample { t: number; load: number; az: number; gyro: number }
interface GpsPt { t: number; lat: number; lng: number; spd: number }
interface Candidate { t0: number; yankG: number }

const G0 = 9.80665;

export class JumpEngineV16 {
  onJump: (j: V16Jump) => void = () => {};
  onDebug: (t: number, event: string) => void = () => {};

  private cfg: V16Config;
  private ring: Sample[] = [];
  /** index of the first live ring element. Advancing a head index instead of
   *  shift()-ing keeps eviction O(1) amortised — at 200 Hz with a 14 s ring a
   *  per-sample shift() would memmove ~2800 entries on every callback. */
  private ringHead = 0;
  private gps: GpsPt[] = [];
  private pending: Candidate[] = [];
  private lastImuT = -Infinity;
  private lastGpsT = -Infinity;
  /** A confirmed jump is HELD for dedupSec before delivery: one takeoff raises
   *  several pops (a weak precursor then the real load), and only the strongest
   *  may reach the consumer. Emitting immediately and "superseding" later would
   *  deliver both. */
  private held: { jump: V16Jump; until: number } | null = null;
  /** the last jump actually delivered, so a weaker straggler inside dedupSec
   *  can be dropped — delivery is irreversible, unlike a hold. */
  private lastEmit: { t0: number; heightM: number } | null = null;

  constructor(cfg?: Partial<V16Config>) {
    this.cfg = { ...V16_DEFAULTS, ...(cfg ?? {}) };
  }

  get config(): V16Config { return this.cfg }

  // ── Inputs ────────────────────────────────────────────────────────────────

  /**
   * @param loadG  |userAcceleration| in g (gravity already removed).
   * @param accel  userAcceleration in g, device frame — required for height.
   * @param quat   attitude quaternion [w,x,y,z] — required for height.
   * Attitude gaps are tolerated in the wide shelf/landing scan (a gap simply
   * breaks any lift run through it) but NOT inside the apex window, where the
   * integral cannot bridge a hole and the candidate is rejected.
   */
  addIMU(t: number, loadG: number, gyroRadS = 0,
         accel?: [number, number, number], quat?: [number, number, number, number]): void {
    if (!isFinite(t) || !isFinite(loadG) || t <= this.lastImuT) return;
    this.lastImuT = t;

    const load = Math.abs(loadG);
    const az = (accel && quat) ? G0 * worldZ(quat, accel[0], accel[1], accel[2]) : NaN;
    this.ring.push({ t, load, az, gyro: isFinite(gyroRadS) ? gyroRadS : 0 });
    const horizon = t - this.cfg.historySec;
    while (this.ringHead < this.ring.length && this.ring[this.ringHead]!.t < horizon) this.ringHead++;
    if (this.ringHead > 2048) { this.ring.splice(0, this.ringHead); this.ringHead = 0 }

    // pop clustering: the strongest sample inside popClusterSec anchors t0
    if (load >= this.cfg.popMinG) {
      const last = this.pending[this.pending.length - 1];
      if (last && t - last.t0 < this.cfg.popClusterSec) {
        if (load > last.yankG) { last.t0 = t; last.yankG = load }
      } else {
        this.pending.push({ t0: t, yankG: load });
      }
    }

    // Judge the oldest candidates from fastEvalSec onward. evaluate() reports
    // whether it could finalise; if not, the candidate stays pending and is
    // retried on the next batch, until evalDelaySec makes the verdict forced.
    while (this.pending.length && t - this.pending[0]!.t0 >= this.cfg.fastEvalSec) {
      const c = this.pending[0]!;
      const forced = t - c.t0 >= this.cfg.evalDelaySec;
      if (!this.evaluate(c, t, forced) && !forced) break;
      this.pending.shift();
    }

    this.releaseHeld(t);
  }

  /** A rival pop up to dedupSec after `t0` is itself judged evalDelaySec after
   *  ITS pop, so the hold must span both delays or it expires before the rival
   *  is even evaluated. */
  /**
   * When a held jump can finally be delivered.
   *
   * Only a pop that is BOTH inside the dedup window AND not yet judged can
   * still supersede it. Because `dedupSec < evalDelaySec`, every such pop has
   * ALREADY arrived and is sitting in `pending` by the time the jump is held —
   * a pop is detected the instant it happens, long before it is judged. So the
   * question "can anything still beat this?" is answerable immediately, and
   * when the answer is no the jump is final RIGHT NOW.
   *
   * The previous rule waited `dedupSec + evalDelaySec` unconditionally, for a
   * rival that in most cases never existed: measured over the reference logs,
   * 6 of 10 held jumps had no rival pop at all and waited 7 s for nothing.
   * Those now deliver at t0 + evalDelaySec, the same as the immediate path.
   */
  private holdUntil(t0: number): number {
    let until = t0 + this.cfg.evalDelaySec;      // the moment it was judged
    for (const c of this.pending) {
      if (c.t0 <= t0 || c.t0 > t0 + this.cfg.dedupSec) continue;
      const judged = c.t0 + this.cfg.evalDelaySec;
      if (judged > until) until = judged;
    }
    return until;
  }

  /** deliver a held jump once no later pop can still supersede it. */
  private releaseHeld(now: number): void {
    if (this.held && now >= this.held.until) {
      const j = this.held.jump;
      this.held = null;
      this.lastEmit = { t0: j.takeoffT, heightM: j.heightM };
      this.onJump(j);
      this.onDebug(now, `JUMP t0=${f2(j.takeoffT)} h=${f2(j.heightM)}m shelf=${f2(j.liftPlateauSec)}s air=${j.airtimeSec == null ? 'n/a' : f2(j.airtimeSec)}s yank=${f2(j.yankG)}g`);
    }
  }

  addGPS(t: number, lat: number, lng: number, speedMS: number): void {
    if (!isFinite(t) || t <= this.lastGpsT) return;
    this.lastGpsT = t;
    this.gps.push({ t, lat, lng, spd: Math.max(0, speedMS) });
    while (this.gps.length && this.gps[0]!.t < t - 120) this.gps.shift();
  }

  /** Session end: judge everything still pending and release the held jump. */
  flush(now: number): void {
    for (const c of this.pending) this.evaluate(c, now);
    this.pending = [];
    this.releaseHeld(Infinity);
  }

  // ── Evaluation ────────────────────────────────────────────────────────────

  /** Judge a candidate. Returns false when the answer is not knowable yet and
   *  the caller should retry later; `forced` makes the verdict final. */
  private evaluate(c: Candidate, now: number, forced = true): boolean {
    const { t0, yankG } = c;

    // ── 1. lift shelf (the phantom firewall)
    const bins = this.liftBins(t0 - this.cfg.apexPreSec, t0 + this.cfg.plateauScanSec);
    if (!bins) { this.onDebug(now, `REJECT t0=${f2(t0)} reason=noAttitude`); return true }
    const plateau = longestRun(bins.az, bins.t, t0, this.cfg.liftThreshMS2);
    if (plateau < this.cfg.minLiftPlateauSec) {
      // the shelf only ever ACCUMULATES, so a short one may still qualify later
      if (!forced) return false;
      this.onDebug(now, `REJECT t0=${f2(t0)} reason=noLiftPlateau shelf=${f2(plateau)}s yank=${f2(yankG)}g`);
      return true;
    }

    // ── 2. height from the fixed-support matched filter
    const apex = this.apex(t0 - this.cfg.apexPreSec, this.cfg.apexPreSec + this.cfg.apexPostSec);
    if (apex == null) {
      if (!forced) return false;
      this.onDebug(now, `REJECT t0=${f2(t0)} reason=apexWindowIncomplete`); return true;
    }
    const heightM = this.cfg.heightScale * apex + this.cfg.heightOffsetM;
    if (heightM < this.cfg.minReportM) {
      // FINAL even when not forced: the apex window has closed, so no later
      // sample can raise this height.
      this.onDebug(now, `REJECT t0=${f2(t0)} reason=belowMinReport h=${f2(heightM)}m`);
      return true;
    }

    // ── 3. airtime (low confidence)
    const landingT = this.landing(bins, t0);
    // An unresolved landing is the one thing worth waiting for: it is what makes
    // the emission complete (airtime and distance), and it usually arrives
    // within a second or two of the pop for a small jump.
    if (landingT == null && !forced) return false;
    // Do not finalise before the landing instant itself. The descent-end bin is
    // found landOffsetSec BEFORE the landing we report, and everything below —
    // the flight statistics and the landing GPS fix — is gathered over
    // [t0, landingT]. Emitting at the descent end would compute them over a
    // truncated window and deliver the number before the rider is down.
    if (landingT != null && now < landingT && !forced) return false;

    // ── 4. flight statistics over [t0, landing or apex window end]
    const tEnd = landingT ?? t0 + this.cfg.apexPostSec;
    let peakG = 0, maxGyro = 0, floatN = 0, n = 0;
    for (let i = this.ringHead; i < this.ring.length; i++) {
      const s = this.ring[i]!;
      if (s.t < t0) continue;
      if (s.t > tEnd) break;
      n++;
      if (s.load > peakG) peakG = s.load;
      if (s.gyro > maxGyro) maxGyro = s.gyro;
      if (s.load <= this.cfg.floatLoadG) floatN++;
    }
    const launch = this.gpsNear(t0 - 1.0);
    const land = this.gpsNear(tEnd);
    let distanceM: number | null = null;
    if (launch && land && (launch.lat !== 0 || launch.lng !== 0) && (land.lat !== 0 || land.lng !== 0)) {
      distanceM = haversineM(launch.lat, launch.lng, land.lat, land.lng);
    } else if (launch && landingT != null) {
      distanceM = launch.spd * (landingT - t0);
    }

    const jump: V16Jump = {
      heightM: r2(heightM),
      apexRawM: r2(apex),
      airtimeSec: landingT == null ? null : r2(landingT - t0),
      takeoffT: t0,
      liftPlateauSec: r2(plateau),
      yankG: r2(yankG),
      peakG: r2(peakG),
      floatFraction: n ? r2(floatN / n) : 0,
      maxGyroRadS: r2(maxGyro),
      takeoffSpeedMS: launch ? r2(launch.spd) : null,
      distanceM: distanceM == null ? null : r2(distanceM),
      confidence: plateau >= this.cfg.minLiftPlateauSec * 1.5 ? 0.75 : 0.55,
    };

    // ── 5. dedup: one takeoff raises several pops — hold, keep the strongest.
    // A jump too big for any precursor to beat skips the wait entirely.
    if (heightM >= this.cfg.immediateReportM) {
      if (this.held && t0 - this.held.jump.takeoffT < this.cfg.dedupSec) {
        this.onDebug(now, `MERGE t0=${f2(this.held.jump.takeoffT)} into ${f2(t0)} (${f2(this.held.jump.heightM)}m < ${f2(heightM)}m)`);
        this.held = null;
      }
      this.lastEmit = { t0, heightM };
      this.onJump(jump);
      this.onDebug(now, `JUMP t0=${f2(t0)} h=${f2(heightM)}m IMMEDIATE shelf=${f2(plateau)}s air=${landingT == null ? 'n/a' : f2(landingT - t0)}s`);
      return true;
    }
    // a straggler behind an already-delivered jump cannot be retracted, so it is
    // only dropped when it is the weaker of the pair — the case that actually occurs
    if (this.lastEmit && t0 - this.lastEmit.t0 < this.cfg.dedupSec && heightM <= this.lastEmit.heightM) {
      this.onDebug(now, `DROP t0=${f2(t0)} h=${f2(heightM)}m behind delivered ${f2(this.lastEmit.heightM)}m`);
      return true;
    }
    if (this.held && t0 - this.held.jump.takeoffT < this.cfg.dedupSec) {
      if (heightM <= this.held.jump.heightM) {
        this.onDebug(now, `MERGE t0=${f2(t0)} into ${f2(this.held.jump.takeoffT)} (${f2(heightM)}m <= ${f2(this.held.jump.heightM)}m)`);
        this.held.until = this.holdUntil(t0);
        return true;
      }
      this.onDebug(now, `MERGE t0=${f2(this.held.jump.takeoffT)} into ${f2(t0)} (${f2(this.held.jump.heightM)}m < ${f2(heightM)}m)`);
      this.held = null;
    }
    this.releaseHeld(Infinity);   // anything older than the dedup span is final
    this.held = { jump, until: this.holdUntil(t0) };
    return true;
  }

  // ── Signal helpers ────────────────────────────────────────────────────────

  /** 0.1 s bins of world-vertical acceleration and float fraction, box-smoothed. */
  private liftBins(from: number, to: number): { t: number[]; az: number[] } | null {
    const STEP = 0.1;
    const nBins = Math.max(0, Math.round((to - from) / STEP));
    if (nBins < 10) return null;
    const t: number[] = new Array(nBins);
    const azRaw = new Float64Array(nBins);
    const attCnt = new Int32Array(nBins);
    for (let i = this.ringHead; i < this.ring.length; i++) {
      const s = this.ring[i]!;
      if (s.t < from) continue;
      if (s.t >= to) break;
      const k = Math.floor((s.t - from) / STEP);
      if (k < 0 || k >= nBins) continue;
      if (isFinite(s.az)) { azRaw[k] = azRaw[k]! + s.az; attCnt[k] = attCnt[k]! + 1 }
    }
    // A bin with no attitude sample becomes NaN, which breaks any lift run
    // passing through it (a shelf cannot be verified across a gap) without
    // discarding the whole evaluation. The apex window is protected separately
    // and far more strictly: apex() refuses if ANY of its samples lacks
    // attitude, because an integral cannot bridge a hole.
    //   (An earlier version compared the total attitude SAMPLE count to the BIN
    //   count — at 200 Hz that is 2100 vs 105, so the guard passed even when
    //   most samples had no attitude; and requiring every bin outright let one
    //   dropped 0.1 s of CMDeviceMotion silently kill a real jump.)
    for (let k = 0; k < nBins; k++) {
      t[k] = from + k * STEP;
      azRaw[k] = attCnt[k]! > 0 ? azRaw[k]! / attCnt[k]! : NaN;
    }
    const w = Math.max(0, Math.round(this.cfg.liftSmoothSec / STEP));
    return { t, az: boxSmooth(azRaw, w) };
  }

  /**
   * Landing = the moment the DESCENT IS ARRESTED.
   *
   * A kite flight is a sustained signed excursion: the canopy lifts, then the
   * rider comes down. Water contact brakes that descent — and it is the descent
   * that stops, not the motion. The arm keeps working the bar, so acceleration
   * stays noisy after touchdown; an earlier version of this rule demanded
   * sustained "float" after the dip and returned null on 2 of 19 goldens
   * because that quiet state never arrived.
   *
   * Measured on world-vertical acceleration, NOT on integrated velocity: a
   * single ∫a_z dt carries an unbounded bias b·t that swamps the descent (over
   * the reference jumps the integrated velocity never even goes negative).
   * Acceleration needs no integration and so has no bias to remove.
   *
   *   phase 1 — the lift shelf opens above landLiftThreshMS2 and closes
   *   phase 2 — the first descent run below landDipMS2 lasting
   *             landDipMinSec; the landing is the END of that run
   *
   * Validated ON THE ENGINE (not an offline reimplementation — an offline copy
   * misaligned its bins by 46 ms and reported a landing 1.1 s off on one jump)
   * against all 14 HOOLAN reference airtimes for log 287: 14/14 resolved, and
   * 0.34 s leave-one-out MAE with landOffsetSec refitted out-of-sample, versus
   * 0.75 s for a constant predictor. The old settle-based rule resolved only
   * 17/19 goldens overall. `airtimeSec` still carries LOW CONFIDENCE: the
   * reference covers one session and one rider, 2.1-8.5 m.
   */
  private landing(bins: { t: number[]; az: number[] }, t0: number): number | null {
    const { t, az } = bins;
    let i0 = 0;
    while (i0 < t.length && t[i0]! < t0) i0++;
    // phase 1 — the lift shelf must open and then close
    let plateauEnd = -1, run = 0;
    for (let i = i0; i < t.length; i++) {
      if (az[i]! > this.cfg.landLiftThreshMS2) run++;   // NaN fails → run resets
      else {
        if (run * 0.1 >= this.cfg.landMinPlateauSec) { plateauEnd = i; break }
        run = 0;
      }
    }
    if (plateauEnd < 0) return null;
    // phase 2 — the descent, ending where the water arrests it
    let dip = 0;
    for (let i = plateauEnd; i < t.length; i++) {
      if (az[i]! < this.cfg.landDipMS2) dip++;          // NaN gap is not a descent
      else {
        if (dip * 0.1 >= this.cfg.landDipMinSec) return t[i]! + this.cfg.landOffsetSec;
        dip = 0;
      }
    }
    return null;
  }

  /**
   * Bounded double integration over [from, from+T] with z(0)=z(T)=0.
   *
   *   a_meas = a_true + b            (b = constant bias: attitude error,
   *                                   sensor offset, gravity residual)
   *   W(t)   = ∫∫a_meas             = z_true(t) + v₀·t + ½b·t²
   *   z(t)   = W(t) − (t/T)·W(T)    forces z(0)=z(T)=0
   *          = z_true(t) − (t/T)·z_true(T) + ½b·t·(t−T)
   *
   * The unknown initial vertical velocity v₀ cancels EXACTLY (it is linear in
   * t). The bias term becomes ½b·t·(t−T): zero at both ends, extremum −bT²/8
   * at midpoint. A bias that would otherwise diverge quadratically is BOUNDED
   * by bT²/8 — with T=4.5 s that is 2.5·b, so 0.1 m/s² of bias costs 0.25 m.
   * No bias estimation is needed.
   */
  private apex(from: number, T: number): number | null {
    const to = from + T;
    // Collect the attitude-carrying samples in the window. Scattered dropouts
    // are integrated through with their real spacing; only a hole longer than
    // maxAttitudeGapSec is unbridgeable.
    const ts: number[] = [];
    const az: number[] = [];
    for (let i = this.ringHead; i < this.ring.length; i++) {
      const s = this.ring[i]!;
      if (s.t < from) continue;
      if (s.t > to) break;
      if (!isFinite(s.az)) continue;
      if (ts.length && s.t - ts[ts.length - 1]! > this.cfg.maxAttitudeGapSec) return null;
      ts.push(s.t);
      az.push(s.az);
    }
    const n = ts.length;
    if (n < 20) return null;
    // the window must also be covered at its edges, not just in the middle
    if (ts[0]! - from > this.cfg.maxAttitudeGapSec) return null;
    if (to - ts[n - 1]! > this.cfg.maxAttitudeGapSec) return null;

    // TRAPEZOID quadrature. The previous rule advanced velocity with the
    // RIGHT-hand sample over the whole interval (v += az[i]*dt) — a rectangle
    // rule that, across a dropout, integrates only the post-gap value over the
    // entire hole. Measured: on a 0.1 s hole the height error falls 32 -> 19 cm;
    // on clean 200 Hz data the two rules differ by 2 cm, so the calibration is
    // unaffected. Linear interpolation across a gap is algebraically identical
    // to this, so no explicit resampling is needed.
    const W = new Float64Array(n);
    const Ts = new Float64Array(n);
    let v = 0, z = 0;
    for (let i = 0; i < n; i++) {
      const dt = i === 0 ? 0 : ts[i]! - ts[i - 1]!;
      const a = i === 0 ? az[i]! : (az[i - 1]! + az[i]!) / 2;
      const vPrev = v;
      v += a * dt;
      z += (vPrev + v) / 2 * dt;
      W[i] = z;
      Ts[i] = ts[i]! - ts[0]!;
    }
    const Tf = Ts[n - 1]!;
    if (Tf <= 0) return null;
    const WT = W[n - 1]!;
    let apex = -Infinity;
    for (let i = 0; i < n; i++) {
      const q = W[i]! - (Ts[i]! / Tf) * WT;
      if (q > apex) apex = q;
    }
    return isFinite(apex) ? apex : null;
  }

  private gpsNear(t: number): GpsPt | null {
    let best: GpsPt | null = null, bd = 3.0;
    for (const g of this.gps) {
      const d = Math.abs(g.t - t);
      if (d < bd) { bd = d; best = g }
    }
    return best;
  }
}

// ── helpers ──────────────────────────────────────────────────────────────────

/** world-Z component of a device-frame vector rotated by the attitude quaternion. */
function worldZ(q: [number, number, number, number], vx: number, vy: number, vz: number): number {
  const [w, x, y, z] = q;
  return 2 * (x * z - w * y) * vx + 2 * (y * z + w * x) * vy + (1 - 2 * (x * x + y * y)) * vz;
}

/** Box smoother over +-halfWidth bins.
 *
 *  A NaN bin (no attitude) must stay NaN so it breaks any lift run passing
 *  through it — but only LOCALLY. The running sum is therefore kept over finite
 *  values only, with NaNs counted separately: adding NaN into the sum would
 *  make it NaN permanently (NaN - NaN = NaN), so a single empty 0.1 s bin used
 *  to poison every later bin in the window and the shelf could never be found
 *  again. Latent on 200 Hz logs, where no jump window contains an empty bin;
 *  live on the watch, where 0.1 s at 50 Hz is only 5 samples. */
function boxSmooth(src: Float64Array, halfWidth: number): number[] {
  const n = src.length;
  const out = new Array<number>(n);
  if (halfWidth <= 0) { for (let i = 0; i < n; i++) out[i] = src[i]!; return out }
  let sum = 0, nans = 0;
  const add = (v: number) => { if (isFinite(v)) sum += v; else nans++ };
  const rem = (v: number) => { if (isFinite(v)) sum -= v; else nans-- };
  for (let i = 0; i <= Math.min(n - 1, halfWidth); i++) add(src[i]!);
  for (let i = 0; i < n; i++) {
    const lo = i - halfWidth, hi = i + halfWidth;
    const width = Math.min(n - 1, hi) - Math.max(0, lo) + 1;
    out[i] = nans > 0 ? NaN : sum / width;
    if (hi + 1 < n) add(src[hi + 1]!);
    if (lo >= 0) rem(src[lo]!);
  }
  return out;
}

/** Longest continuous run above `thresh` from `from` onward, in seconds.
 *  Counted in whole BINS and scaled once: accumulating 0.1 ten times yields
 *  0.9999999999999999, which silently failed a `>= 1.0` shelf gate. */
function longestRun(az: number[], t: number[], from: number, thresh: number): number {
  let best = 0, run = 0;
  for (let i = 0; i < az.length; i++) {
    if (t[i]! < from) continue;
    // NaN (an attitude gap) fails the comparison and resets the run — a shelf
    // is never credited across a hole.
    if (az[i]! > thresh) { run++; if (run > best) best = run }
    else run = 0;
  }
  return best * 0.1;
}

function haversineM(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const r = 6371000;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLng = (lng2 - lng1) * Math.PI / 180;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.asin(Math.min(1, Math.sqrt(h)));
}

function r2(v: number): number { return Math.round(v * 100) / 100 }
function f2(v: number): string { return v.toFixed(2) }
