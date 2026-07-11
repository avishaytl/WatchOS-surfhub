/**
 * jumpEngine — kitesurf jump height from the BAROMETER (physics-forced).
 *
 * ════════════════════════════════════════════════════════════════════════════
 * THE KEY FINDING (proven on the real Surfr kite log 4173200D — see
 * NEXT_LOG_RECORDING_SPEC.md and JUMP_V8_PLAN.md)
 * ════════════════════════════════════════════════════════════════════════════
 * A kite lifts the rider in a smooth, canopy-borne, elevator-like rise. The
 * WRIST accelerometer feels almost NO vertical acceleration during that rise —
 * only chop. Measured on the biggest jump (3.37 m): physics needs a take-off
 * vertical velocity v0=√(2gh)=8.13 m/s, but the IMU's net upward impulse to the
 * apex integrates to 0.02 m/s (chop RMS 3.2 m/s² swamps it). The barometer's own
 * rise rate is 8.87 m/s — exactly the physics. So:
 *
 *   ► HEIGHT comes from the BAROMETER, never from integrating wrist accel.
 *   ► The IMU is used only to DETECT the jump (take-off pop) and bracket it.
 *
 * Baro height pipeline (robust to the 0.36 Hz rate the log was recorded at):
 *   1. baseline = a robust HIGH-pressure percentile over ±W s (the rider is on
 *      the water ~90% of the time → that percentile is true "sea level", immune
 *      to the brief jumps). altitude = (baseline − baro)·8.43.
 *   2. apex = local-max altitude per jump, refined by PARABOLIC interpolation
 *      (the apex falls between the sparse baro samples; the parabola recovers it).
 *   3. gates: height ≥ minJumpHeightM, airtime ≥ minAirTimeSec.
 *
 * Result on the current 0.36 Hz log: top-4 [4.05,3.82,3.38,3.17] vs Surfr
 * [3.77,3.45,3.17,3.14] → RMS 0.26 m. A ≥1 Hz baro is required for ≤0.20 m.
 *
 * UNITS: accel g · gyro rad/s · gravity g · baro hPa · t MILLISECONDS.
 */

import type { SensorSample, JumpEvent } from './types.ts';

const G = 9.80665;
const P2M = 8.43;    // hPa → m near sea level
const DEG2RAD = Math.PI / 180;

// ════════════════════════════════════════════════════════════════════════════
// Params
// ════════════════════════════════════════════════════════════════════════════
export interface JumpEngineParams {
  // ── baro height pipeline ──
  baselineHalfWinSec: number;   // ± window for the baseline percentile
  baselinePctile: number;       // high-pressure percentile = "sea level" (0..1)
  // "sea level" is the HIGH-pressure mode (rider on water ~90 % of the time), so a
  // percentile ABOVE the median measures small jumps better (median under-reads
  // them: LOG2 RMS 0.58→0.17 at 0.6). But on DIRTY baro a wide local spread makes
  // a high percentile grab elevated noise → phantoms (LOG3 7.5 m). So cap how far
  // the baseline may sit above the local MEDIAN: clean baro (small spread) keeps
  // the accuracy, dirty baro (wide spread) is clamped. 0 = uncapped (legacy).
  baselineMaxOffsetHpa: number;
  // The baseline window is ASYMMETRIC: [t − baselineHalfWinSec, t + baselineFutureWinSec].
  // The future side needs real-time samples → it sets the LATENCY. Symmetric
  // (future = halfWin = 15) is most accurate (~0.17 m) but ~16 s; a short future
  // (e.g. 5) is ready in ≤5 s at ~0.21 m (LOG2). Used by the provisional (fast)
  // vs final (symmetric) emission. (Drift detrend was tested — it HURT, removed.)
  baselineFutureWinSec: number;
  // SUSTAINED-GARBAGE guard: a bad baro can read a wrong pressure OFFSET for a run
  // of samples (not a spike → survives despikeUpward, e.g. LOG3 min 23-25 +5.7hPa
  // then returns). The rider is ALWAYS at sea level, so the local baseline can't
  // sit far above a SLOW robust reference (low percentile over ±baselineDriftWinSec,
  // which ignores the upward garbage but still tracks REAL weather/tide drift). If
  // the local baseline exceeds slowRef + baselineGarbageHpa, it's garbage → clamp.
  // 0 = off (leaves clean baro untouched; only bites on sustained upward garbage).
  baselineDriftWinSec: number;
  baselineGarbageHpa: number;
  // DE-TREND window: fit a robust line to the on-water envelope over ±this to make the
  // baseline follow a slow downward baro drift (which otherwise inflates heights). 0=off.
  baselineDetrendWinSec: number;
  // ── GPS⊕BARO COMPLEMENTARY FUSION (the real drift fix — needs GPS altitude) ──
  // The baro is high-res but drifts; GPS altitude is coarse but DRIFT-FREE. They are
  // strong in complementary frequency bands, so: keep the baro's HIGH freq (the fast
  // jump), take the LOW freq (sea level / drift) from GPS. driftCorr = LPF(alt_baro −
  // gps_rel) is the baro's residual drift → subtract it. Auto-engages ONLY when GPS
  // altitude is present in the log; a baro-only log is byte-for-byte unchanged.
  gpsFusion: boolean;
  gpsCrossWinSec: number;  // ± low-pass window = the baro/GPS crossover (~ the drift timescale)
  gpsTideWinSec: number;   // ± window for the GPS's own slow sea-level (allows real tide)
  // Reject a jump whose GPS vertical velocity never exceeds this over its arc (a real
  // jump moves vertically; a pure baro-drift phantom does not). 0 = off / no GPS vVel.
  gpsVertVelMinMs: number;
  // ── jump gates ──
  minJumpHeightM: number;
  // Grid-altitude PRE-gate as a fraction of minJumpHeightM. 1 = legacy (gate on the
  // sparse grid sample). <1 (e.g. 0.85) lets a sub-sample apex whose sparse samples
  // sit just under the gate reach the parabola refinement; the FINAL gate is then
  // enforced on the refined apexH. Re-validate on the goldens before lowering.
  heightPreGateFrac: number;
  // Minimum baro update points required inside the baseline window before the high
  // percentile is trusted. With 1–2 points the percentile degenerates to the MAX and
  // can inflate a leading-edge (provisional) baseline. Below the minimum the baseline
  // falls back to the window MEDIAN (conservative). 0 = off (legacy).
  baselineMinPoints: number;
  // ── EARLY-FINALIZE GATE (≤5 s FINAL for provably drift-free jumps) ──────────
  // The ONLY information the 16 s settle buys is the net baro DRIFT across the arc
  // (a symmetric baseline cancels a linear drift; a truncated one absorbs it). So a
  // jump may finalize EARLY iff the absence of drift is PROVEN four ways, all
  // available ≤5 s after landing. Signals are computed on every jump (cheap
  // diagnostics); the gate itself is applied by the V9 scanner (earlyFinalizeSec).
  // Philosophy-safe: a failed proof only DELAYS the final to settleSec — it never
  // drops a jump (unlike requireCrossValidation, the documented trap).
  // (1) RETURN-TO-ZERO: median of the first ≤2 post-landing on-water baro updates
  //     minus the pre-take-off baseline = the MEASURED net drift. |rtz| ≤ tol ⇒ clean.
  rtzToleranceHpa: number;
  // (2) PAST SLOPE: Theil-Sen slope of the on-water (high-pressure half) baro
  //     updates over the pre-take-off window. |slope| ≤ max ⇒ no active drift.
  driftSlopeWinSec: number;
  driftSlopeMaxHpaPerSec: number;
  // (3) REAL FLOAT: specForceQuieting < this (clean jumps 0.55–0.76; drift-inflated
  //     1.1–1.8 on LOG2) ⇒ a genuine supported flight occurred.
  quietingCleanMax: number;
  // (4) is landingTimedOut === false (the documented drift symptom: baro never
  //     returns to 0 and the bracket hits the maxAirTime cap).
  // ── ENDPOINT ½ΔB HEIGHT CORRECTION (experimental, 0 = off) ──────────────────
  // For a LINEAR drift the apex over-read ≈ half the measured net drift (rtz), so
  // apexH += clamp(rtz, ±this)/2 · 8.43. A ±0.03 hPa deadband ignores pure sensor
  // noise. UNLIKE the failed local water-line (which REPLACED the robust baseline
  // and collapsed LOG2 to 1.69 RMS), this keeps the baseline and only shifts it by
  // a bounded, MEASURED endpoint offset. Validate on the goldens before enabling.
  endpointDriftMaxHpa: number;
  minAirTimeSec: number;
  maxAirTimeSec: number;
  jumpSepSec: number;           // min spacing between distinct jumps
  // ── take-off detection (for timing, not height) ──
  popUpG: number;               // world-vertical UP accel marking the pop
  minRidingSpeed: number;       // m/s
  gyroIsDegPerSec: boolean | null;
  // ── airtime model ──
  // Airtime is DERIVED from the height, not measured: at 0.36 Hz the baro can't
  // time a 4 s arc, and the soft kite landing has no accel spike. A kite extends
  // the descent (glide), so the real airtime is a multiple of the symmetric
  // ballistic flight time 2·√(2h/g). Fitted to Surfr: factor ≈ 2.63 (RMS 0.28 s).
  kiteGlideFactor: number;
  onWaterAltM: number;          // baro-altitude on-water threshold (apex bracket)
  maxPlausibleHeightM: number;
  // ── KITE-AWARE NOISE FILTER (reject choppy-sea / standing artefacts) ──
  // A real kite jump launches WHILE RIDING FAST and the baro rises over a
  // sustained arc. False apexes come from: (a) the rider standing / drifting /
  // back at the beach (a stray baro bump with no riding speed); (b) a single
  // sparse-baro spike that jumps in one sample and is not supported by its
  // neighbours (sensor glitch / wave on a still rider). Rotation is intentionally
  // NOT a discriminator — kite tricks (board-offs, spins) rotate hard too.
  jumpRunUpSpeed: number;       // m/s — required max GPS speed in the run-up window
  runUpWindowSec: number;       // window before the apex to check the run-up speed
  // ── MULTI-SIGNAL CROSS-VALIDATION (robust to a degraded barometer) ──
  // A real kite jump shows a coherent signature across independent channels:
  // baro dip (height), a quieter wrist while airborne (no water chop — the "calm
  // window", which also measures airtime), a bar-pull before take-off, and
  // planing speed. These CONFIRM a jump and feed confidence; their ABSENCE does
  // NOT reject (a trick jump moves the hand, so the airborne phase isn't calm).
  chopHalfWinSec: number;       // ± window for the rolling |userAccel| std (chop)
  airborneChopRatio: number;    // airborne if arc-chop < this × the run-up chop (local contrast)
  barPullWindowSec: number;     // window before take-off to look for the bar-pull
  barPullMinG: number;          // sustained |userAccel| that marks a bar-pull (g)
  // ── CONFIDENCE FLOOR (the single composite noise gate) ──
  // Drops detections below this confidence. Confidence aggregates ALL independent
  // signals (run-up speed, height, pop, baro support, airborne calm-window,
  // bar-pull), so a floor is a SAFER noise filter than any single hard gate: a
  // real jump clears it with margin, while a bare baro-bump during fast riding —
  // no bar-pull, no airborne phase — falls below. Validated on the Surfr golden
  // (LOG2 4173200D): 0.5 removes the 3 no-corroboration ~1.7 m artefacts and
  // leaves the golden top-4 unchanged (RMS 0.579). NOT a hard airborne/bar-pull
  // gate — those individually drop real trick jumps (which move the hand).
  minConfidence: number;        // 0 = off; 0.5 = drop bare-baro-bump noise
  // CROSS-VALIDATION GATE: reject a detection that has NEITHER independent IMU signal
  // — no airborne calm-window AND no bar-pull. These are the pure baro-bumps with zero
  // corroboration (the #1/#11-style artefacts). Kept LENIENT (needs only ONE of the two)
  // so real trick jumps (airborne fails, bar-pull holds) and gentle launches (bar-pull
  // fails, airborne holds) still pass — only the no-support bumps are dropped.
  requireCrossValidation: boolean; // true = drop jumps with no airborne AND no bar-pull
  // ── ROBUST FILTERS (LOG3 — small jumps + garbage baro). Parameter-light: each
  // is self-scaling / physically-grounded so it needs little per-log tuning. ──
  // (a) BARO DE-SPIKE: a kitesurfer can only LOWER pressure (rise); pressure
  //     ABOVE the local robust median is a sensor glitch (LOG3 spiked to 1070 hPa
  //     and inflated the baseline → phantom 6 m jumps). One-sided upward Hampel
  //     reject — needs no amplitude tuning (jumps never push pressure up).
  baroDespikeWinSec: number;    // ± window for the de-spike robust median
  baroDespikeHpa: number;       // reject baro > localMedian + this (upward only)
  // (b) ARC-SUPPORT GATE: a real jump's baro arc spans several samples; an
  //     ISOLATED single-point spike (neighbours ≈ 0) is noise. Require ≥ this many
  //     of the ±3 neighbours to be elevated (≥ apex/3).
  minSupport: number;           // 0 = off; ≥1 rejects single-point spikes
  // (c) MEASURED-AIRTIME FLOOR: take-off→landing must last ≥ this. Measured from
  //     the out-of-water baro bracket (and the IMU calm-window when present), NOT
  //     the height-derived airtime. Rejects brief hops / spikes.
  minMeasuredAirSec: number;    // 0 = off; 1.5 = drop sub-1.5 s hops
  // (d) ARC-SHAPE CORRELATION: score the candidate's baro-altitude segment against
  //     an ideal concave (inverted-U) arc; a step / double-bump / spike scores low.
  //     Normalised correlation in [-1,1] → parameter-light threshold.
  arcShapeMinCorr: number;      // 0 = off; ~0.4 keeps real arcs, drops steps/spikes
  // ── BALLISTIC THROW PATH (testing aid; SPEED-DISJOINT from the kite path) ──
  // A thrown watch (rider standing on the beach to test) flies ballistically and
  // the baro barely moves, so the kite/baro path can't size it. This optional
  // path detects a launch-spike → smooth airborne (free-fall / steady-spin)
  // window → landing while the rider is NOT riding, and reports a time-of-flight
  // height. It is gated to STANDING speed only, so it can never fire during real
  // kite riding (which requires planing speed) — the kite path is untouched.
  detectThrows: boolean;        // enable the ballistic throw path
  throwMaxSpeed: number;        // m/s — throws are detected only below this (standing)
  throwLaunchG: number;         // launch-spike threshold (g)
  throwLandG: number;           // landing-spike threshold (g)
  throwFreefallG: number;       // |a| below this = free-fall (g)
  throwFreefallMinSec: number;  // a real flight needs this much sustained free-fall
  throwMaxAirtimeSec: number;   // a hand throw's flight tops out here (bounds landing search)
  throwAscentFraction: number;  // ballistic arc: h = ½·g·(f·airtime)², f≈0.5 (symmetric)
  throwMaxHeightM: number;      // sanity cap for a hand throw
}

export const DEFAULT_JUMP_PARAMS: JumpEngineParams = {
  baselineHalfWinSec: 15,
  // "sea level" = high-pressure mode → a percentile ABOVE the median measures
  // small jumps correctly (the median under-reads: LOG2 top-4 RMS 0.58→0.17).
  baselinePctile: 0.6,
  // …but cap it at median+0.4 hPa so a wide DIRTY-baro spread can't inflate the
  // baseline into a phantom (LOG3 7.5 m → 4.1 m). Clean baro (spread <0.4) is
  // untouched → keeps the accuracy; dirty baro is clamped.
  baselineMaxOffsetHpa: 0.4,
  baselineFutureWinSec: 15, // = baselineHalfWinSec → symmetric (most accurate, ~16 s)
  baselineDriftWinSec: 300, // ±5 min slow reference (tracks real drift, ignores bursts)
  baselineGarbageHpa: 1.5,  // clamp baseline that sits >1.5hPa above the slow reference
  baselineDetrendWinSec: 0, // 0 = off (swept below; enabled once validated on goldens)
  // OFF: scaffolded + tested on synthetic drift-free GPS — it does NOT fix the drift.
  // A drift big enough to inflate a jump also reads as "airborne", so the on-water mask
  // has no reference in the drift region (#8 stays 4.06); dropping the mask makes it
  // subtract REAL jumps; and consumer GPS altitude noise (±3–5 m) injects phantoms.
  // Needs cm-level (RTK/carrier-phase) vertical to work — see ALGORITHM_V9 §10.
  gpsFusion: false,
  gpsCrossWinSec: 6,    // ±6 s LPF ⇒ ~12 s crossover: faster = baro (jump), slower = GPS (drift)
  gpsTideWinSec: 300,   // ±5 min GPS sea-level (keeps real tide, drops per-jump/noise)
  gpsVertVelMinMs: 0,   // 0 = off until GPS vertical velocity is actually recorded
  minJumpHeightM: 1.5,
  heightPreGateFrac: 1.0,  // legacy: gate on the grid sample (lower only after re-validating)
  baselineMinPoints: 0,    // legacy: off (recommended 4 once validated; guards the provisional)
  // Early-Finalize diagnostics (computed always — gate applied only by the scanner)
  rtzToleranceHpa: 0.06,        // ≈0.5 m net drift; clean-jump rtz is sensor noise (±0.02–0.03)
  driftSlopeWinSec: 45,         // ~15 on-water updates @0.34 Hz for the Theil-Sen slope
  driftSlopeMaxHpaPerSec: 0.01, // LOG2 #8 drifted at ~0.043 hPa/s — 4× above this line
  quietingCleanMax: 0.9,        // clean floats 0.55–0.76; drift-inflated 1.1–1.8 (LOG2)
  endpointDriftMaxHpa: 0,       // ½ΔB endpoint correction OFF (experimental; validate first)
  minAirTimeSec: 2.0,
  // Big Air kite jumps hang for a LONG time — the world record is ~45 m with
  // 20+ s airtime. This bounds the on-water bracket search; keep it wide enough
  // to span a real Big Air (it does NOT cap the reported airtime, which is
  // height-derived and uncapped).
  maxAirTimeSec: 25.0,
  jumpSepSec: 4.0,
  popUpG: 0.9,
  minRidingSpeed: 4.0,
  gyroIsDegPerSec: false,
  kiteGlideFactor: 2.63,
  onWaterAltM: 0.4,
  // Kite jumps reach the WORLD RECORD ~45 m (Big Air). The cap must NOT clip a
  // real jump — 50 m gives margin above the record. (This is the KITE/baro cap;
  // the separate hand-throw cap is throwMaxHeightM ≈ 8 m, a different regime.)
  maxPlausibleHeightM: 50.0,
  jumpRunUpSpeed: 5.0,   // must be planing (kite jumps launch from speed, not a standstill)
  runUpWindowSec: 5.0,
  chopHalfWinSec: 0.2,   // ±0.2 s rolling std of |userAccel|
  airborneChopRatio: 0.85, // airborne when the arc's chop is below 85% of the run-up's
  barPullWindowSec: 1.0,
  barPullMinG: 0.45,     // a sustained pull toward the body before the rip-out
  // Drop bare baro-bumps with no corroboration. 0.6 pairs with the higher baseline
  // (which raises ALL altitudes, so the noise floor rises too): it keeps the LOG2
  // top-4 (RMS 0.17) while holding the count down (16→10). A planing jump ≥2 m
  // clears it on speed+height alone (0.35+0.15+0.12); bare bumps fall below.
  minConfidence: 0.6,
  // OFF by default: validated UNSAFE — on LOG3 the airborne/bar-pull signals don't fire
  // (different watch/IMU scaling), so this hard gate dropped 5 of 9 REAL jumps (incl.
  // Surfr-confirmed 2.16/1.69 m). Keep the param for future use once the signals are
  // made watch-robust; do NOT enable globally (violates "prefer a false positive over a
  // miss"). The real fix for the artefacts is the baro-drift baseline, not this gate.
  requireCrossValidation: false,
  // Robust LOG3 filters (each parameter-light / physically-grounded):
  baroDespikeWinSec: 10,
  baroDespikeHpa: 1.0,   // jumps never raise pressure >1 hPa; garbage does (→1070)
  minMeasuredAirSec: 1.5, // take-off→landing must last ≥1.5 s (works at any baro rate)
  // support & arc-shape need a WELL-SAMPLED arc (≥1 Hz baro); at today's ~0.34 Hz
  // they drop real jumps with an isolated sparse apex (LOG2 913 s, conf 1.00) —
  // implemented and available, defaulted OFF until the baro rate rises (see
  // NEXT_LOG_RECORDING_SPEC ≥1 Hz). The de-spike + airtime + throws-off do the work.
  minSupport: 0,         // 0=off; ≥1 rejects isolated spikes (needs ≥1 Hz baro)
  arcShapeMinCorr: 0,    // 0=off; ~0.4 rejects steps/spikes (needs ≥1 Hz baro)
  // OFF for real kite sessions: the ballistic throw path fires on STRONG HAND
  // MOVEMENTS during slow moments (proven on LOG3 → phantom 6.7 m "throws"). It
  // is a TESTING AID only — use DEFAULT_THROW_PARAMS for the Hoolan throw log.
  detectThrows: false,
  throwMaxSpeed: 3.0,    // standing — disjoint from the kite run-up speed (≥5)
  throwLaunchG: 2.5,
  throwLandG: 2.0,       // the landing IMPACT (higher than chop bumps) — keeps airtime to the real touchdown
  throwFreefallG: 0.5,     // |a| below this = genuine free-fall
  throwFreefallMinSec: 0.8, // sustained free-fall a wave/chop CANNOT fake → 0 kite false-positives
  // A hand throw's flight tops out ~2.5 s (≈7.7 m). A LONGER "flight" is a
  // STANDING GAP between two handling events (watch set down / held still),
  // which the launch→first-landing search would otherwise read as one long
  // ballistic arc → an unphysical 12 m. Bounding the landing search to 2.5 s
  // rejects that while keeping real throws (observed airtimes 1.2–2.2 s).
  throwMaxAirtimeSec: 2.5,
  throwAscentFraction: 0.5, // symmetric ballistic arc
  throwMaxHeightM: 8.0,   // physical cap for a hand throw (a 2.5 s flight ≈ 7.7 m)
};

// Throw-TEST profile: the ballistic throw path ON (for the Hoolan watch-throw
// calibration log only). Real kite sessions use DEFAULT_JUMP_PARAMS (throws off),
// because the throw path fires on strong hand movements during slow riding.
export const DEFAULT_THROW_PARAMS: JumpEngineParams = {
  ...DEFAULT_JUMP_PARAMS,
  detectThrows: true,
  // throws carry a fixed rough confidence (0.5); keep the floor at/below it so the
  // kite floor (0.6) doesn't filter them out on the throw-test log.
  minConfidence: 0.5,
};

// 'barometric' = kite jump (height from the baro apex). 'ballistic' = a free
// throw / out-of-water hop while NOT riding (height from time-of-flight). The two
// are SPEED-DISJOINT (kite needs run-up speed, throws are detected only when
// standing), so the throw path can never fire during real kite riding.
export type HeightSourceV8 = 'barometric' | 'ballistic';

export interface JumpResult {
  jumpHeightM: number;       // barometric apex (parabola-refined)
  airTimeSec: number;        // derived from height (kite glide × ballistic flight)
  apexTimeSec: number;       // take-off → apex (rough; baro-timed)
  jumpDistanceM: number | null;
  maxSpeedKmh: number;
  peakUpAccelG: number;      // pop strength (diagnostic)
  confidence: number;
  heightSource: HeightSourceV8;
  takeoffTimeMs: number | null;
  landingTimeMs: number | null;
  // ── cross-validation diagnostics (multi-signal agreement) ──
  measuredAirtimeSec: number | null; // airtime from the airborne "calm window" (IMU), when present
  airborneConfirmed: boolean;        // a calm/airborne window coincides with the baro arc
  barPullConfirmed: boolean;         // a sustained bar-pull preceded take-off
  // FRAME-INDEPENDENT cross-check: |specific force| std in-flight ÷ on-water. A REAL
  // kite float is a supported, QUIETER glide (ratio < ~0.8); a baro-DRIFT artifact has
  // no real float, so its "flight" is just on-water motion (ratio ≈ 1+). Unlike the
  // projected airborne-chop, |a| is rotation-invariant → robust and watch-independent.
  // A cross-check/confidence signal (does NOT reject — a plausible jump is never dropped).
  specForceQuieting: number;
  driftSuspect: boolean; // specForceQuieting > 1 → no real float → the baro height may be drift-inflated
  // ── Early-Finalize diagnostics (see the EARLY-FINALIZE GATE params) ──
  /** MEASURED net baro drift across the arc: median of the first ≤2 post-landing
   *  on-water updates minus the pre-take-off baseline (hPa). null = no post-landing
   *  on-water update in the window yet. Clean ≈ ±noise; drift-down → strongly negative. */
  returnToZeroHpa: number | null;
  /** Theil-Sen slope (hPa/s) of the pre-take-off on-water baro envelope. null = too few points. */
  pastDriftSlopeHpaS: number | null;
  /** The landing bracket hit the maxAirTime cap — the documented drift symptom. */
  landingTimedOut: boolean;
  /** All four drift-absence proofs hold → the V9 scanner may FINALIZE EARLY (≤5 s). */
  cleanNoDrift: boolean;
  /** Height correction (m) applied by the ½ΔB endpoint corrector (0 when off/deadband). */
  endpointDriftCorrM: number;
}

// ════════════════════════════════════════════════════════════════════════════
// helpers
// ════════════════════════════════════════════════════════════════════════════
function median(a: number[]): number { const s = [...a].sort((x, y) => x - y); return s.length ? s[s.length >> 1]! : 0; }
function mean(a: number[]): number { return a.length ? a.reduce((x, v) => x + v, 0) / a.length : 0; }
// Pearson correlation of two equal-length series (used for the arc-shape gate).
function pearson(a: number[], b: number[]): number {
  const m = Math.min(a.length, b.length);
  if (m < 3) return 1;
  const ma = mean(a.slice(0, m)), mb = mean(b.slice(0, m));
  let num = 0, da = 0, db = 0;
  for (let i = 0; i < m; i++) { const x = a[i]! - ma, y = b[i]! - mb; num += x * y; da += x * x; db += y * y; }
  const den = Math.sqrt(da * db);
  return den > 1e-9 ? num / den : 0;
}

function vertAccelG(s: SensorSample): number {
  const gx = s.gvX ?? 0, gy = s.gvY ?? 0, gz = s.gvZ ?? -1;
  const m = Math.hypot(gx, gy, gz) || 1;
  return -((s.ax * gx + s.ay * gy + s.az * gz) / m);
}
/** |specific force| (g) = |userAccel + gravity| — frame-independent (no attitude).
 *  ≈1 g = supported (standing / on-water / kite float) · ≈0 g = FREE-FALL (a throw). */
function specForceMag(s: SensorSample): number {
  return Math.hypot((s.ax ?? 0) + (s.gvX ?? 0), (s.ay ?? 0) + (s.gvY ?? 0), (s.az ?? 0) + (s.gvZ ?? -1));
}
function gyroMag(s: SensorSample): number {
  if (s.gM != null) return s.gM;
  return Math.hypot(s.gx ?? 0, s.gy ?? 0, s.gz ?? 0);
}
function estimateDtMs(s: SensorSample[]): number {
  if (s.length < 6) return 20;
  // Probe the START, MIDDLE and END of the log (60 pairs each). A log that opens
  // at a warm-up rate (e.g. 1 Hz before the 50 Hz stream settles) no longer skews
  // the estimate; on a uniform-rate log the median is identical to the legacy
  // first-60 estimate, so the goldens are unaffected.
  const d: number[] = [];
  const probe = (from: number) => {
    const lo = Math.max(1, from), hi = Math.min(s.length, lo + 60);
    for (let i = lo; i < hi; i++) { const x = s[i]!.t - s[i - 1]!.t; if (x > 5 && x < 500) d.push(x); }
  };
  probe(1); probe(s.length >> 1); probe(s.length - 60);
  return d.length > 3 ? median(d) : 20;
}
function dedupeByTime(s: SensorSample[]): SensorSample[] {
  const out: SensorSample[] = []; let last = -Infinity;
  for (const x of s) if (x.t > last) { out.push(x); last = x.t; }
  return out;
}

// One-sided UPWARD de-spike of a forward-filled baro series. A kitesurfer can
// only LOWER pressure (rise above sea level), so any sample whose pressure is
// > localMedian + baroDespikeHpa is a sensor glitch (LOG3 spiked to 1070 hPa).
// Robust coarse-grid median (time-weighted, immune to the brief bursts) keeps it
// parameter-light — no amplitude tuning, since real jumps never push pressure up.
function despikeUpward(raw: number[], s: SensorSample[], params: JumpEngineParams): number[] {
  const n = raw.length;
  const win = params.baroDespikeWinSec * 1000;
  const thr = params.baroDespikeHpa;
  if (win <= 0 || thr <= 0 || n < 8) return raw;
  const ST = 500; // ms coarse grid
  const t0 = s[0]!.t, tN = s[n - 1]!.t;
  const ng = Math.max(1, Math.floor((tN - t0) / ST) + 1);
  const gridVal = new Array<number>(ng);
  let si = 0;
  for (let g = 0; g < ng; g++) { const gt = t0 + g * ST; while (si + 1 < n && s[si + 1]!.t <= gt) si++; gridVal[g] = raw[si]!; }
  const gw = Math.max(1, Math.round(win / ST));
  const gridMed = new Array<number>(ng);
  for (let g = 0; g < ng; g++) {
    const w: number[] = [];
    for (let j = Math.max(0, g - gw); j <= Math.min(ng - 1, g + gw); j++) w.push(gridVal[j]!);
    w.sort((a, b) => a - b);
    gridMed[g] = w[w.length >> 1]!;
  }
  const out = new Array<number>(n);
  for (let i = 0; i < n; i++) {
    const g = Math.min(ng - 1, Math.max(0, Math.round((s[i]!.t - t0) / ST)));
    const m = gridMed[g]!;
    out[i] = raw[i]! > m + thr ? m : raw[i]!;
  }
  return out;
}

// ════════════════════════════════════════════════════════════════════════════
// Barometric altitude on the 50 Hz grid (robust baseline). Returns altitude (m)
// above the rider's ambient "sea level" at every sample.
// ════════════════════════════════════════════════════════════════════════════
export function baroAltitudeSeries(s: SensorSample[], params: JumpEngineParams): number[] {
  const n = s.length;
  // forward-fill the sparse baro onto the grid, then DE-SPIKE upward garbage.
  const raw = new Array<number>(n);
  let last = s.find((x) => x.baro != null)?.baro ?? 1013.25;
  for (let i = 0; i < n; i++) { if (s[i]!.baro != null) last = s[i]!.baro!; raw[i] = last; }
  const baro = despikeUpward(raw, s, params);

  // baseline: high-pressure percentile over a ± time window (robust to jumps).
  // Update points are taken from the CLEANED baro (garbage runs collapse to the
  // median → no longer over-weight the baseline). Cheap, then mapped to the grid.
  const upIdx: number[] = []; const upVal: number[] = [];
  for (let i = 0; i < n; i++) if (!upVal.length || baro[i] !== upVal[upVal.length - 1]) { upIdx.push(i); upVal.push(baro[i]!); }
  const pastW = params.baselineHalfWinSec * 1000;
  const futW = params.baselineFutureWinSec * 1000; // ms (future side sets the latency)
  // Two-pointer sliding window over the time-ordered update points — identical
  // membership to the previous full O(U²) scan, but O(U·W): the whole-log offline
  // tools scanned ~14 M pairs on a 3-hour session; this is linear in practice.
  const U = upVal.length;
  const upT = upIdx.map((ix) => s[ix]!.t);
  let wLo = 0, wHi = -1;
  const baseUp = upVal.map((_, k) => {
    const tk = upT[k]!;
    while (wLo < U && upT[wLo]! < tk - pastW) wLo++;
    if (wHi < wLo - 1) wHi = wLo - 1;
    while (wHi + 1 < U && upT[wHi + 1]! <= tk + futW) wHi++;
    const wv = upVal.slice(wLo, wHi + 1);
    const sorted = [...wv].sort((a, b) => a - b);
    const med = sorted[Math.min(sorted.length - 1, sorted.length >> 1)]!;
    // LEADING-EDGE GUARD: with too few update points the high percentile degenerates
    // to the max → an inflated (provisional) baseline. Fall back to the median.
    if (params.baselineMinPoints > 0 && sorted.length < params.baselineMinPoints) return med;
    const hi = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * params.baselinePctile))]!;
    return params.baselineMaxOffsetHpa <= 0 ? hi : med + Math.min(hi - med, params.baselineMaxOffsetHpa);
  });
  // SUSTAINED-GARBAGE clamp: a slow, garbage-robust sea-level reference (low
  // percentile over ±driftWin — upward bursts land in the HIGH percentiles, so a
  // LOW one ignores them, yet still follows genuine slow drift). Any local baseline
  // sitting far above it is a bad-baro pressure offset → pull it down to the ref.
  if (params.baselineGarbageHpa > 0) {
    const driftW = params.baselineDriftWinSec * 1000;
    let dLo = 0, dHi = -1;
    for (let k = 0; k < baseUp.length; k++) {
      const tk = upT[k]!;
      while (dLo < U && upT[dLo]! < tk - driftW) dLo++;
      if (dHi < dLo - 1) dHi = dLo - 1;
      while (dHi + 1 < U && upT[dHi + 1]! <= tk + driftW) dHi++;
      const wv = upVal.slice(dLo, dHi + 1);
      wv.sort((a, b) => a - b);
      const slowRef = wv[Math.min(wv.length - 1, Math.floor(wv.length * 0.2))]!; // 20th pct
      const cap = slowRef + params.baselineGarbageHpa;
      if (baseUp[k]! > cap) baseUp[k] = cap;
    }
  }
  // ── BASELINE DE-TREND: a slow baro drift (pressure creeping down over ~10-15 s)
  //    makes the ±window high-percentile LAG at the drift extreme → the water level is
  //    over-estimated there → the jump height is INFLATED (LOG2 #8: 4.06 vs golden
  //    3.77). Fix: fit a ROBUST LINE to the on-water envelope (upper half of the window,
  //    which excludes the fast jump DIPS) → the line FOLLOWS the drift trend instead of
  //    lagging, and stays flat in clean regions (no change there). 0 = off. ──
  if (params.baselineDetrendWinSec > 0) {
    const dW = params.baselineDetrendWinSec * 1000;
    const detr = baseUp.map((_, k) => {
      const tk = s[upIdx[k]!]!.t;
      const ts: number[] = [], vs: number[] = [];
      for (let j = 0; j < upVal.length; j++) { const dt = s[upIdx[j]!]!.t - tk; if (dt >= -dW && dt <= dW) { ts.push(dt / 1000); vs.push(upVal[j]!); } }
      if (ts.length < 4) return baseUp[k]!;
      const med = [...vs].sort((a, b) => a - b)[vs.length >> 1]!;
      // robust least-squares line over the ON-WATER (≥ median) samples only
      let sx = 0, sy = 0, sxx = 0, sxy = 0, cnt = 0;
      for (let j = 0; j < ts.length; j++) if (vs[j]! >= med) { sx += ts[j]!; sy += vs[j]!; sxx += ts[j]! * ts[j]!; sxy += ts[j]! * vs[j]!; cnt++; }
      if (cnt < 2) return baseUp[k]!;
      const denom = cnt * sxx - sx * sx;
      const slope = Math.abs(denom) > 1e-9 ? (cnt * sxy - sx * sy) / denom : 0;
      const intercept = (sy - slope * sx) / cnt; // line value at dt = 0 (i.e. at tk)
      // never RAISE the baseline (that would inflate) — only let the trend LOWER it.
      return Math.min(baseUp[k]!, intercept);
    });
    for (let kk = 0; kk < baseUp.length; kk++) baseUp[kk] = detr[kk]!;
  }
  // map baseline back to grid (nearest update point)
  const base = new Array<number>(n);
  let k = 0;
  for (let i = 0; i < n; i++) {
    while (k + 1 < upIdx.length && upIdx[k + 1]! <= i) k++;
    base[i] = baseUp[k] ?? upVal[k] ?? baro[i]!;
  }
  const alt = baro.map((b, i) => (base[i]! - b) * P2M);

  // ── GPS⊕BARO COMPLEMENTARY FUSION — cancels the baro's residual drift using the
  //    DRIFT-FREE GPS altitude. Engages ONLY when GPS altitude is present (baro-only
  //    logs return `alt` unchanged). driftCorr = LPF(alt_baro − gps_rel), where gps_rel
  //    = GPS altitude minus its own slow sea-level (real tide kept). At LOW freq the
  //    baro drifts and GPS doesn't → the difference IS the drift → subtract it; at HIGH
  //    freq the jump lives in the baro and the LPF removes GPS noise → the jump is kept. ──
  if (params.gpsFusion && s.some((x) => x.gpsAlt != null)) {
    // forward-fill GPS altitude onto the grid
    const g = new Array<number>(n);
    let lastG = s.find((x) => x.gpsAlt != null)?.gpsAlt ?? 0;
    for (let i = 0; i < n; i++) { if (s[i]!.gpsAlt != null) lastG = s[i]!.gpsAlt!; g[i] = lastG; }
    const tideW = params.gpsTideWinSec * 1000, crossW = params.gpsCrossWinSec * 1000;
    const t0 = s[0]!.t, tN = s[n - 1]!.t;
    // coarse 1 s grid for cheap windowed means (n can be ~84k)
    const ST = 1000, ng = Math.max(1, Math.floor((tN - t0) / ST) + 1);
    const gsum = new Array<number>(ng).fill(0), gcnt = new Array<number>(ng).fill(0);
    const dsum = new Array<number>(ng).fill(0), dcnt = new Array<number>(ng).fill(0);
    for (let i = 0; i < n; i++) {
      const c = Math.min(ng - 1, Math.max(0, Math.round((s[i]!.t - t0) / ST)));
      gsum[c]! += g[i]!; gcnt[c]!++;
    }
    const prefix = (a: number[]) => { const p = new Array<number>(a.length + 1).fill(0); for (let i = 0; i < a.length; i++) p[i + 1] = p[i]! + a[i]!; return p; };
    const gsP = prefix(gsum), gcP = prefix(gcnt);
    const win = (P: number[], lo: number, hi: number) => P[Math.min(P.length - 1, hi + 1)]! - P[Math.max(0, lo)]!;
    // gps_rel = GPS altitude − its slow sea level (tide window)
    const gpsRel = new Array<number>(n);
    for (let i = 0; i < n; i++) {
      const c = Math.round((s[i]!.t - t0) / ST);
      const w = Math.round(tideW / ST);
      const sea = win(gsP, c - w, c + w) / Math.max(1, win(gcP, c - w, c + w));
      gpsRel[i] = g[i]! - sea;
    }
    // diff = alt_baro − gps_rel, accumulated over ON-WATER samples ONLY (alt below the
    // on-water threshold) so a real jump's bump does NOT leak into the drift estimate —
    // the correction reflects the sea-level mismatch between jumps, then LPF-smoothed.
    for (let i = 0; i < n; i++) {
      // genuine on-water only: 0 ≤ alt < threshold (exclude airborne AND the negative
      // pre-jump baseline overshoot, which would otherwise poison the drift estimate).
      if (alt[i]! < 0 || alt[i]! >= params.onWaterAltM) continue;
      const c = Math.min(ng - 1, Math.max(0, Math.round((s[i]!.t - t0) / ST)));
      dsum[c]! += alt[i]! - gpsRel[i]!; dcnt[c]!++;
    }
    const dsP = prefix(dsum), dcP = prefix(dcnt);
    for (let i = 0; i < n; i++) {
      const c = Math.round((s[i]!.t - t0) / ST);
      const w = Math.round(crossW / ST);
      const cnt = win(dcP, c - w, c + w);
      if (cnt < 1) continue; // no on-water reference nearby → leave the sample untouched
      alt[i] = alt[i]! - win(dsP, c - w, c + w) / cnt; // remove the low-freq drift
    }
  }
  return alt;
}

// ════════════════════════════════════════════════════════════════════════════
// Whole-session detection: find barometric-altitude apexes (jumps), refine each
// apex by parabolic interpolation on the raw baro points, bracket airtime by the
// out-of-water crossings, and attribute a take-off pop for timing/diagnostics.
// ════════════════════════════════════════════════════════════════════════════
export function detectJumps(
  samplesIn: SensorSample[],
  params: JumpEngineParams = DEFAULT_JUMP_PARAMS,
): JumpResult[] {
  const s = dedupeByTime(samplesIn);
  const n = s.length;
  if (n < 24) return [];
  const dt = estimateDtMs(s) / 1000;
  const gscale = params.gyroIsDegPerSec === true ? DEG2RAD : 1;

  // No baro → the kite path can't size a jump, but the ballistic throw path (which
  // is time-of-flight, baro-free) can still run. So don't return early; just skip
  // the baro/kite loop below when haveBaro is false.
  const haveBaro = s.some((x) => x.baro != null);
  const alt = haveBaro ? baroAltitudeSeries(s, params) : new Array<number>(n).fill(0);

  // world-vertical accel, bias-removed (for pop detection / timing only)
  const aRaw = s.map(vertAccelG);
  const calm: number[] = [];
  for (let i = 0; i < n; i++) if (gyroMag(s[i]!) * gscale < 1.0 && (s[i]!.aM ?? 0) < 0.6 && (s[i]!.spd ?? 0) > params.minRidingSpeed) calm.push(aRaw[i]!);
  const bias = calm.length ? mean(calm) : 0;

  const maxSpeed = (() => {
    const top: number[] = [];
    for (const x of s) if (x.spd != null && x.spd > 0) { top.push(x.spd); top.sort((a, b) => b - a); if (top.length > 3) top.pop(); }
    return top.length ? mean(top) : 0;
  })();

  // ── CHOP series: rolling std of |userAccel|. High while riding (water impacts),
  // LOW while airborne (no water contact). Used to confirm the airborne phase and
  // measure airtime — a cross-check on the baro, robust if the baro is degraded. ──
  const accMagAll = s.map((x) => x.aM ?? Math.hypot(x.ax, x.ay, x.az));
  const chopHW = Math.max(3, Math.round(params.chopHalfWinSec / dt));
  const chop = new Array<number>(n);
  for (let i = 0; i < n; i++) {
    let sum = 0, sq = 0, cnt = 0;
    for (let j = Math.max(0, i - chopHW); j <= Math.min(n - 1, i + chopHW); j++) { sum += accMagAll[j]!; sq += accMagAll[j]! * accMagAll[j]!; cnt++; }
    chop[i] = Math.sqrt(Math.max(0, sq / cnt - (sum / cnt) ** 2));
  }
  // (airborne is judged per-jump by a LOCAL chop contrast — arc vs run-up — not a
  //  global baseline, since smooth riding is also globally quiet.)

  // sparse baro update points (for the parabolic apex)
  const upIdx: number[] = []; const upAlt: number[] = [];
  for (let i = 0; i < n; i++) if (s[i]!.baro != null && (!upIdx.length || s[i]!.baro !== s[upIdx[upIdx.length - 1]!]!.baro)) { upIdx.push(i); upAlt.push(alt[i]!); }

  const out: JumpResult[] = [];
  let lastApexT = -Infinity;
  const sepMs = params.jumpSepSec * 1000;
  const maxAirSamp = Math.round(params.maxAirTimeSec / dt);

  for (let u = 1; u < upIdx.length - 1; u++) {
    const i = upIdx[u]!;
    // PRE-GATE on the grid altitude. With heightPreGateFrac = 1 (legacy) this is the
    // final gate; with a fraction < 1 the pre-gate loosens so a sub-sample apex whose
    // sparse samples sit just under the gate can still be parabola-refined, and the
    // FINAL gate below (on the refined apexH) enforces minJumpHeightM.
    if (alt[i]! < params.minJumpHeightM * params.heightPreGateFrac) continue;
    // local max on the sparse baro series
    if (!(upAlt[u]! >= upAlt[u - 1]! && upAlt[u]! >= upAlt[u + 1]!)) continue;
    // SEP-CONFLICT: two apexes within jumpSepSec — keep the higher. Do NOT pop the
    // previously-ACCEPTED jump until the new candidate has passed EVERY gate below:
    // an eager pop lost BOTH jumps whenever the taller candidate later failed a gate
    // (e.g. run-up speed). Mark the replacement; apply it only on acceptance.
    let replaceIdx = -1;
    if (s[i]!.t - lastApexT < sepMs) {
      if (out.length && alt[i]! > out[out.length - 1]!.jumpHeightM) replaceIdx = out.length - 1;
      else continue;
    }

    // parabolic apex refinement through (u-1,u,u+1). MUST be concave (den<0, a
    // real peak) and the vertex MUST lie between the samples (|d|≤0.5) — otherwise
    // it is sub-sample EXTRAPOLATION on a near-collinear triple, which explodes
    // (a flat 0.5 m bump refined to 6.7 m on LOG3). Non-concave → no refinement.
    const y0 = upAlt[u - 1]!, y1 = upAlt[u]!, y2 = upAlt[u + 1]!;
    const den = y0 - 2 * y1 + y2;
    let apexH = y1;
    if (den < -1e-6) {
      let d = 0.5 * (y0 - y2) / den;
      d = Math.max(-0.5, Math.min(0.5, d)); // vertex stays within the 3 samples
      apexH = y1 - 0.25 * (y0 - y2) * d;
    }
    apexH = Math.min(Math.max(apexH, y1), params.maxPlausibleHeightM);
    // FINAL height gate on the REFINED apex (a no-op when heightPreGateFrac = 1,
    // since then alt[i] ≥ minJumpHeightM and apexH ≥ y1 = alt[i] already).
    if (apexH < params.minJumpHeightM) continue;

    // AIRTIME from PHYSICS, not from the baro bracket. At 0.36 Hz the baro can't
    // time a ~4 s arc and the soft kite landing has no accel spike, so a measured
    // airtime is wildly unstable (5–13 s). Instead derive it from the (accurate)
    // height: a kite extends the descent (glide), so the airtime is a multiple of
    // the symmetric ballistic flight 2·√(2h/g). Fitted to Surfr → RMS 0.28 s.
    let airTimeSec = params.kiteGlideFactor * 2 * Math.sqrt(2 * apexH / G);
    if (airTimeSec < params.minAirTimeSec) continue;

    // loose on-water bracket only to locate the take-off (for the pop/timing).
    let t0 = Math.max(0, i - maxAirSamp);
    for (let k = i; k > Math.max(0, i - maxAirSamp); k--) { if (alt[k]! < params.onWaterAltM) { t0 = k; break; } }
    let tl = Math.min(n - 1, i + maxAirSamp);
    let landingTimedOut = true; // the documented drift symptom: baro never returns to 0
    for (let k = i; k < Math.min(n - 1, i + maxAirSamp); k++) { if (alt[k]! < params.onWaterAltM) { tl = k; landingTimedOut = false; break; } }

    // ── MEASURED-AIRTIME FLOOR (take-off→landing) ────────────────────────
    // The out-of-water bracket width is the real airborne duration. A brief hop /
    // single-sample spike spans << 1.5 s; a real jump spans ≥ its flight time.
    const arcWidthSec = (s[tl]!.t - s[t0]!.t) / 1000;
    if (arcWidthSec < params.minMeasuredAirSec) continue;

    // ── ARC-SHAPE GATE ───────────────────────────────────────────────────
    // A real jump's altitude over the bracket is a single concave hump. Correlate
    // it with an inverted-U template centred on the apex; a step / double-bump /
    // residual spike scores low. Parameter-light (normalised correlation).
    if (params.arcShapeMinCorr > 0 && tl - t0 >= 4) {
      const seg: number[] = [], tmpl: number[] = [];
      const span = Math.max(i - t0, tl - i, 1);
      for (let kk = t0; kk <= tl; kk++) { seg.push(alt[kk]!); const x = (kk - i) / span; tmpl.push(1 - x * x); }
      if (pearson(seg, tmpl) < params.arcShapeMinCorr) continue;
    }

    // ── KITE-AWARE NOISE FILTER ──────────────────────────────────────────
    // (a) RUN-UP SPEED: a kite jump launches while planing. If the rider was not
    //     moving fast in the seconds before the apex, this baro bump is the rider
    //     standing / drifting / back at the beach, or a stray pressure wiggle —
    //     not a jump. (This removed the spd≈0 false apexes that out-read the real
    //     jumps on the test log.)
    const runUpSamp = Math.round(params.runUpWindowSec / dt);
    let runUpSpeed = 0;
    for (let k = Math.max(0, i - runUpSamp); k <= i; k++) { const sp = s[k]!.spd; if (sp != null && sp > runUpSpeed) runUpSpeed = sp; }
    // A kite jump launches while PLANING. BUT a genuine free-fall THROW (the watch
    // tossed in the air) has no run-up yet IS a real altitude the baro measures. So
    // bypass the run-up gate ONLY when the arc shows a CONTIGUOUS free-fall — |specific
    // force| ≈ 0 g (weightless) for an unbroken run ≥ throwFreefallMinSec. A CONTIGUOUS
    // run (not scattered low samples) is the real ballistic signature: beach-noise, a
    // stray bump and a dirty IMU's scattered <0.5 g samples never form a sustained run.
    // Opt-in via detectThrows (default off) → production/goldens are byte-identical.
    let ffRun = 0, ffMax = 0;
    for (let k = t0; k <= tl; k++) { if (specForceMag(s[k]!) < params.throwFreefallG) { ffRun += dt; if (ffRun > ffMax) ffMax = ffRun; } else ffRun = 0; }
    const isFreefallThrow = params.detectThrows && ffMax >= params.throwFreefallMinSec;
    if (runUpSpeed < params.jumpRunUpSpeed && !isFreefallThrow) continue;

    // (b) BARO SUPPORT (soft): count neighbouring baro updates that are also
    //     elevated (≥ a third of the apex). A well-supported arc is more
    //     trustworthy; a lone spike on a fast rider is rare so this only feeds
    //     confidence (a real but short jump may legitimately have one baro point).
    let support = 0;
    for (let d = 1; d <= 3; d++) { if (upAlt[u - d] != null && upAlt[u - d]! >= apexH / 3) support++; if (upAlt[u + d] != null && upAlt[u + d]! >= apexH / 3) support++; }
    // ARC-SUPPORT GATE: an isolated single-point spike (neighbours ≈ 0) is noise.
    if (support < params.minSupport) continue;

    // take-off pop (for timing/diagnostics): the kite pop is a brief UP impulse
    // shortly before the apex. Search a bounded pre-apex window (the rise is
    // short — a few seconds) so the apex time stays meaningful even when the
    // on-water bracket t0 sits far back.
    // window starts at the LATER of the on-water bracket and 3 s before the apex,
    // so the rise time stays bounded (a kite rise is a few seconds).
    const popLo = Math.max(0, t0, i - Math.round(3.0 / dt));
    let peakUp = 0, popIdx = popLo;
    for (let k = popLo; k <= i; k++) { const a = aRaw[k]! - bias; if (a > peakUp) { peakUp = a; popIdx = k; } }
    const apexTimeSec = Math.max(0, (i - popIdx) * dt);

    // NB: we deliberately do NOT reject on high rotation. A kite jump can have
    // big rotations (board-offs, spins, handle-passes), so a gyro-based "tumble"
    // reject would wrongly drop legitimate trick jumps. Standing/junk artefacts
    // are already removed by the run-up speed gate (a real jump is launched while
    // planing); rotation is not a discriminator here.

    // ── CROSS-VALIDATION: airborne "calm window" (IMU) ───────────────────
    // While airborne the wrist leaves the water → the chop is QUIETER than the
    // approach (where the board slaps chop at speed). A robust, threshold-free
    // test compares the mean chop over the baro arc to the mean chop in the
    // run-up to THIS jump (a local contrast — far cleaner than a global
    // baseline, since smooth riding is also globally quiet). A SMOOTH jump goes
    // clearly quiet; a TRICK jump moves the hand so it stays noisier — so its
    // absence does NOT reject (baro+speed already confirmed it), only lowers
    // confidence. The measured airtime is the longest calm run vs the local mean.
    const arcLo = Math.max(0, t0), arcHi = Math.min(n - 1, tl);
    let arcSum = 0, arcN = 0; for (let kk = arcLo; kk <= arcHi; kk++) { arcSum += chop[kk]!; arcN++; }
    const arcChop = arcN ? arcSum / arcN : 0;
    const ruLo = Math.max(0, t0 - Math.round(params.runUpWindowSec / dt));
    let ruSum = 0, ruN = 0; for (let kk = ruLo; kk < t0; kk++) { ruSum += chop[kk]!; ruN++; }
    const runUpChop = ruN ? ruSum / ruN : arcChop;
    const airborneConfirmed = arcChop < runUpChop * params.airborneChopRatio;
    // measured airtime = longest run below the LOCAL mid-level (arc+runUp)/2,
    // overlapping the arc — a rough, baro-free airtime cross-check.
    const localThr = (arcChop + runUpChop) / 2;
    let bestLen = 0, runStart = -1, bestA = i, bestB = i;
    for (let kk = Math.max(0, t0 - Math.round(0.5 / dt)); kk <= Math.min(n - 1, tl + Math.round(0.5 / dt)); kk++) {
      if (chop[kk]! < localThr) { if (runStart < 0) runStart = kk; if (kk - runStart > bestLen) { bestLen = kk - runStart; bestA = runStart; bestB = kk; } }
      else runStart = -1;
    }
    const measuredAirtime = (s[bestB]!.t - s[bestA]!.t) / 1000;

    // ── CROSS-VALIDATION: bar-pull before take-off ───────────────────────
    // To launch, the rider pulls the bar hard toward the body and HOLDS it
    // through the rip-out: a SUSTAINED elevated |userAccel| in the ~1 s before
    // take-off (distinct from a brief chop spike). Confirms the take-off intent.
    const bpLo = Math.max(0, popIdx - Math.round(params.barPullWindowSec / dt));
    let bpHeld = 0;
    for (let k = bpLo; k < popIdx; k++) if (accMagAll[k]! >= params.barPullMinG) bpHeld++;
    const barPullConfirmed = bpHeld * dt >= params.barPullWindowSec * 0.5;

    // ── RETURN-TO-ZERO: the MEASURED net drift across the arc ────────────────
    // Pre-take-off water level (the baseline) reconstructed at the take-off
    // bracket via base = baro + alt/8.43, vs the median of the first ≤2
    // post-landing ON-WATER baro updates. A clean arc returns to ±noise; a
    // drift-down leaves rtz strongly negative. This is the single number the
    // 16 s settle waits to learn — here it is measured ~2.6 s after landing.
    let returnToZeroHpa: number | null = null;
    {
      let bi = -1;
      for (let k = t0; k >= 0; k--) if (s[k]!.baro != null) { bi = k; break; }
      if (bi >= 0) {
        const baseT0 = s[bi]!.baro! + alt[bi]! / P2M;
        const post: number[] = [];
        for (let uu = u + 1; uu < upIdx.length && post.length < 2; uu++) {
          const ix = upIdx[uu]!;
          if (ix > tl && upAlt[uu]! < params.onWaterAltM && s[ix]!.baro != null) post.push(s[ix]!.baro!);
        }
        if (post.length) returnToZeroHpa = median(post) - baseT0;
      }
    }

    // ── PAST DRIFT SLOPE: Theil-Sen over the pre-take-off on-water envelope ──
    // Robust slope (median of pairwise slopes) on the HIGH-pressure half of the
    // update points (excludes earlier jump dips). CI-free but outlier-immune;
    // |slope| ≤ driftSlopeMaxHpaPerSec proves no ACTIVE drift entering the jump.
    let pastDriftSlopeHpaS: number | null = null;
    {
      const winMs = params.driftSlopeWinSec * 1000;
      const T: number[] = [], P: number[] = [];
      for (let uu = u - 1; uu >= 0; uu--) {
        const ix = upIdx[uu]!;
        const back = s[t0]!.t - s[ix]!.t;
        if (back > winMs) break;
        if (back < 0) continue;
        if (s[ix]!.baro != null) { T.push(s[ix]!.t / 1000); P.push(s[ix]!.baro!); }
      }
      if (P.length >= 5) {
        const medP = median(P);
        const Tw: number[] = [], Pw: number[] = [];
        for (let j = 0; j < P.length; j++) if (P[j]! >= medP) { Tw.push(T[j]!); Pw.push(P[j]!); }
        if (Tw.length >= 4) {
          const slopes: number[] = [];
          for (let a = 0; a < Tw.length; a++) for (let b = a + 1; b < Tw.length; b++) {
            const dts = Tw[b]! - Tw[a]!;
            if (Math.abs(dts) > 1) slopes.push((Pw[b]! - Pw[a]!) / dts);
          }
          if (slopes.length) pastDriftSlopeHpaS = median(slopes);
        }
      }
    }

    // ── ½ΔB ENDPOINT CORRECTION (param-gated, 0 = off) ───────────────────────
    // Linear drift ⇒ the apex over-read ≈ half the measured net offset. Bounded
    // (clamped) and deadbanded (±0.03 hPa = sensor noise): a clean jump is never
    // touched; only a MEASURED endpoint offset shifts the height.
    let endpointDriftCorrM = 0;
    if (params.endpointDriftMaxHpa > 0 && returnToZeroHpa != null && Math.abs(returnToZeroHpa) >= 0.03) {
      const dB = Math.max(-params.endpointDriftMaxHpa, Math.min(params.endpointDriftMaxHpa, returnToZeroHpa));
      endpointDriftCorrM = (dB / 2) * P2M; // drift-down (rtz<0) shrinks an inflated apex
      apexH = Math.min(Math.max(apexH + endpointDriftCorrM, params.minJumpHeightM), params.maxPlausibleHeightM);
      airTimeSec = params.kiteGlideFactor * 2 * Math.sqrt(2 * apexH / G); // re-derive from the corrected height
    }

    // distance: GPS speed at take-off × airtime
    let spd: number | null = null, bd = Infinity;
    for (const x of s) { if (x.spd == null) continue; const d = Math.abs(x.t - s[t0]!.t); if (d < bd) { bd = d; spd = x.spd; } }
    const distanceM = spd != null ? Math.round(spd * airTimeSec * 10) / 10 : null;

    // FRAME-INDEPENDENT float cross-check: |specific force| std over the airborne arc vs
    // the on-water run-up. A real float is a supported, quieter glide (ratio < 1); a baro
    // drift artifact stays in on-water motion (ratio ≈ 1+). Rotation-invariant (no attitude),
    // so it is watch-independent — the trap that made airborne-chop unusable as a gate.
    const specForce = (x: SensorSample) => Math.hypot((x.ax ?? 0) + (x.gvX ?? 0), (x.ay ?? 0) + (x.gvY ?? 0), (x.az ?? 0) + (x.gvZ ?? -1));
    const sfStd = (lo: number, hi: number) => { const v: number[] = []; for (let k = Math.max(0, lo); k <= Math.min(n - 1, hi); k++) v.push(specForce(s[k]!)); if (v.length < 2) return 0; const m = v.reduce((a, b) => a + b, 0) / v.length; return Math.sqrt(v.reduce((a, b) => a + (b - m) ** 2, 0) / v.length); };
    const flightSf = sfStd(i - Math.round((i - t0) * 0.6), i + Math.round((tl - i) * 0.6));
    const waterSf = sfStd(t0 - Math.round(params.runUpWindowSec / dt), t0 - 1);
    const specForceQuieting = waterSf > 1e-3 ? Math.round((flightSf / waterSf) * 100) / 100 : 1;
    // baro-DRIFT suspect: no real supported float (flight not quieter than on-water) →
    // the "apex" is likely inflated by a slow baro drift, so TRUST THE HEIGHT LESS. This
    // is a cross-check, never a rejection (a plausible jump is kept — prefer FP over miss).
    const driftSuspect = specForceQuieting > 1.0;

    // ── EARLY-FINALIZE ELIGIBILITY: absence of drift PROVEN four ways ────────
    // Conservative AND of independent proofs, all available ≤5 s after landing.
    // A missing/failed proof only delays the FINAL to settleSec — never rejects.
    const cleanNoDrift =
      !landingTimedOut &&
      (returnToZeroHpa != null && Math.abs(returnToZeroHpa) <= params.rtzToleranceHpa) &&
      (pastDriftSlopeHpaS != null && Math.abs(pastDriftSlopeHpaS) <= params.driftSlopeMaxHpaPerSec) &&
      (specForceQuieting > 0 && specForceQuieting < params.quietingCleanMax);

    // confidence: multi-signal agreement (baro height + planing + pop + airborne
    // calm-window + bar-pull + frame-independent float). Each channel that agrees raises it.
    let conf = 0.35;
    if (runUpSpeed >= params.jumpRunUpSpeed + 2) conf += 0.15;      // solidly planing
    if (apexH >= params.minJumpHeightM + 0.5) conf += 0.12;
    if (peakUp >= params.popUpG) conf += 0.12;
    if (support >= 2) conf += 0.08;                                 // well-supported baro arc
    if (airborneConfirmed) conf += 0.15;                           // IMU calm window agrees
    if (barPullConfirmed) conf += 0.08;                            // bar-pull present
    if (airborneConfirmed && Math.abs(measuredAirtime - airTimeSec) < 1.5) conf += 0.05;
    if (specForceQuieting > 0 && specForceQuieting < 0.85) conf += 0.10; // clean supported float
    else if (driftSuspect) conf -= 0.06;                           // drift-suspect: mild, never rejects
    conf = Math.max(0, Math.min(1, conf));

    lastApexT = s[i]!.t;
    // apply the deferred sep-conflict replacement ONLY now that every gate passed
    if (replaceIdx >= 0 && replaceIdx < out.length) out.splice(replaceIdx, 1);
    const r2 = (x: number) => Math.round(x * 100) / 100;
    out.push({
      jumpHeightM: r2(apexH),
      airTimeSec: r2(airTimeSec),
      apexTimeSec: r2(apexTimeSec),
      jumpDistanceM: distanceM,
      maxSpeedKmh: Math.round(maxSpeed * 3.6 * 10) / 10,
      peakUpAccelG: r2(peakUp),
      confidence: Math.round(conf * 1000) / 1000,
      heightSource: 'barometric',
      takeoffTimeMs: s[t0]?.t ?? null,
      landingTimeMs: s[tl]?.t ?? null,
      measuredAirtimeSec: airborneConfirmed ? r2(measuredAirtime) : null,
      airborneConfirmed,
      barPullConfirmed,
      specForceQuieting,
      driftSuspect,
      returnToZeroHpa: returnToZeroHpa != null ? Math.round(returnToZeroHpa * 1000) / 1000 : null,
      pastDriftSlopeHpaS: pastDriftSlopeHpaS != null ? Math.round(pastDriftSlopeHpaS * 10000) / 10000 : null,
      landingTimedOut,
      cleanNoDrift,
      endpointDriftCorrM: r2(endpointDriftCorrM),
    });
  }

  // ── BALLISTIC THROW PATH (optional, speed-disjoint from the kite path) ──
  if (params.detectThrows) out.push(...detectThrowsBallistic(s, params, dt, out));

  // ── CONFIDENCE FLOOR — the composite noise gate (see params.minConfidence) ──
  let kept = params.minConfidence > 0
    ? out.filter((r) => r.confidence >= params.minConfidence)
    : out;
  // ── CROSS-VALIDATION GATE — drop pure baro-bumps with zero IMU corroboration
  //    (no airborne calm-window AND no bar-pull). Lenient: ONE signal suffices. ──
  if (params.requireCrossValidation) kept = kept.filter((r) => r.airborneConfirmed || r.barPullConfirmed);

  // keep chronological order (kite apexes + throws interleaved)
  kept.sort((a, b) => (a.takeoffTimeMs ?? 0) - (b.takeoffTimeMs ?? 0));
  return kept;
}

/**
 * Ballistic throw detector — for a watch thrown while the rider is NOT riding
 * (standing test). A throw flies ballistically: a launch spike, a SMOOTH airborne
 * window (free-fall ≈ 0 g, or steady centripetal if spinning — chop is spiky, so
 * smoothness separates a real flight from sea chop), then a landing spike. The
 * baro barely moves for a hand throw, so height is time-of-flight:
 *   h = ½·g·(throwAscentFraction · airtime)²   (symmetric arc, f≈0.5).
 *
 * It only runs below `throwMaxSpeed` (standing), which is DISJOINT from the kite
 * run-up speed — so it can never fire during kite riding. Heights are rough (a
 * throw's airtime is noisy); this is a testing aid, not a calibrated metric.
 */
function detectThrowsBallistic(
  s: SensorSample[], params: JumpEngineParams, dt: number, kiteJumps: JumpResult[],
): JumpResult[] {
  const n = s.length;
  const accM = (x: SensorSample) => x.aM ?? Math.hypot(x.ax, x.ay, x.az);
  const maxAir = Math.round(params.maxAirTimeSec / dt);
  const throwMinAir = Math.round(params.throwFreefallMinSec / dt); // a throw flight can be < 2 s (uses the short throw-min, not the kite 2 s)
  const out: JumpResult[] = [];
  const G_ = 9.80665;

  const throwMaxAirSamp = Math.round(params.throwMaxAirtimeSec / dt);
  let i = 3;
  while (i < n - 5) {
    if (accM(s[i]!) >= params.throwLaunchG && accM(s[i]!) - accM(s[i - 3]!) >= 1.0) {
      // LANDING = the FIRST impact spike after the minimum airtime, bounded to a
      // physical throw flight (≤ throwMaxAirtimeSec). First (not last) keeps a
      // throw-and-rest from inflating the airtime; the time bound keeps it sane.
      // NB: we do NOT require a free-fall window — a SPINNING throw never has one
      // (centripetal accel), and those are the realistic throws. The STANDING
      // speed gate is what keeps the kite path safe (kite needs planing speed),
      // so this never fires during real riding.
      let last = -1;
      for (let k = i + throwMinAir; k < Math.min(n, i + throwMaxAirSamp); k++) { if (accM(s[k]!) >= params.throwLandG) { last = k; break; } }
      if (last > 0) {
        // diagnostic: did a free-fall window occur? (true for clean throws)
        let run = 0, freefall = 0;
        for (let k = i; k <= last; k++) { if (accM(s[k]!) < params.throwFreefallG) { run++; freefall = Math.max(freefall, run); } else run = 0; }
        // speed must be STANDING (disjoint from kite riding)
        let spd = 0;
        for (let k = Math.max(0, i - 50); k <= last; k++) { const sp = s[k]!.spd; if (sp != null && sp > spd) spd = sp; }
        const airtime = (s[last]!.t - s[i]!.t) / 1000; // launch → first landing impact
        const h = Math.min(0.5 * G_ * (params.throwAscentFraction * airtime) ** 2, params.throwMaxHeightM);
        // not overlapping a kite jump already detected
        const overlapsKite = kiteJumps.some((j) => Math.abs((j.takeoffTimeMs ?? 0) - s[i]!.t) < 2000);
        if (spd <= params.throwMaxSpeed && h >= params.minJumpHeightM && !overlapsKite) {
          let peakUp = 0; for (let k = Math.max(0, i - 2); k < Math.min(n, i + 6); k++) peakUp = Math.max(peakUp, accM(s[k]!));
          const r2 = (x: number) => Math.round(x * 100) / 100;
          out.push({
            jumpHeightM: r2(h),
            airTimeSec: r2(airtime),
            apexTimeSec: r2(airtime * params.throwAscentFraction),
            jumpDistanceM: null,
            maxSpeedKmh: 0,
            peakUpAccelG: r2(peakUp),
            confidence: 0.5, // rough — time-of-flight on a noisy throw
            heightSource: 'ballistic',
            takeoffTimeMs: s[i]!.t,
            landingTimeMs: s[last]!.t,
            measuredAirtimeSec: r2(airtime), // throw airtime IS measured (launch→landing)
            airborneConfirmed: freefall * dt >= params.throwFreefallMinSec, // clean (non-spinning) throw
            barPullConfirmed: false,         // no bar in a throw
            specForceQuieting: 0,            // a throw is free-fall (not a supported float) — n/a
            driftSuspect: false,
            returnToZeroHpa: null,
            pastDriftSlopeHpaS: null,
            landingTimedOut: false,
            cleanNoDrift: false,             // throws always ripen on the normal settle path
            endpointDriftCorrM: 0,
          });
          i = last + Math.round(1.0 / dt);
          continue;
        }
      }
    }
    i++;
  }
  return out;
}

/** Convert a v8 result to the compact app JumpEvent (cm, tenths, km/h, dm). */
export function toJumpEvent(r: JumpResult, takeoff: SensorSample): JumpEvent {
  return {
    t: Math.round(takeoff.t / 1000),
    h: Math.round(r.jumpHeightM * 100),
    a: Math.round(r.airTimeSec * 10),
    s: Math.round(r.maxSpeedKmh),
    d: r.jumpDistanceM != null ? Math.round(r.jumpDistanceM * 10) : 0,
    y: takeoff.lat != null ? Math.round(takeoff.lat * 1e4) : 0,
    x: takeoff.lng != null ? Math.round(takeoff.lng * 1e4) : 0,
  };
}
