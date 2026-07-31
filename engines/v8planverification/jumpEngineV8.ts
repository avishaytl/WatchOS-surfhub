/**
 * jumpEngineV8 — kitesurf jump height from the BAROMETER (physics-forced).
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
export interface JumpEngineV8Params {
  // ── baro height pipeline ──
  baselineHalfWinSec: number;   // ± window for the baseline percentile
  baselinePctile: number;       // high-pressure percentile = "sea level" (0..1)
  // ── jump gates ──
  minJumpHeightM: number;
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

export const DEFAULT_V8_PARAMS: JumpEngineV8Params = {
  baselineHalfWinSec: 15,
  baselinePctile: 0.5,
  minJumpHeightM: 1.5,
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
  // ON: detect free throws too (a thrown watch while standing). It is SPEED-
  // DISJOINT from the kite path (throws require standing, kite requires planing),
  // so it never fires during kite riding — the kite jumps are untouched. Throw
  // HEIGHT is rough (time-of-flight on a noisy hand throw); a spinning throw with
  // no free-fall window is missed. Better to detect (≥1.5 m) than to over-filter.
  detectThrows: true,
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

// 'barometric' = kite jump (height from the baro apex). 'ballistic' = a free
// throw / out-of-water hop while NOT riding (height from time-of-flight). The two
// are SPEED-DISJOINT (kite needs run-up speed, throws are detected only when
// standing), so the throw path can never fire during real kite riding.
export type HeightSourceV8 = 'barometric' | 'ballistic';

export interface JumpResultV8 {
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
}

// ════════════════════════════════════════════════════════════════════════════
// helpers
// ════════════════════════════════════════════════════════════════════════════
function median(a: number[]): number { const s = [...a].sort((x, y) => x - y); return s.length ? s[s.length >> 1]! : 0; }
function mean(a: number[]): number { return a.length ? a.reduce((x, v) => x + v, 0) / a.length : 0; }

function vertAccelG(s: SensorSample): number {
  const gx = s.gvX ?? 0, gy = s.gvY ?? 0, gz = s.gvZ ?? -1;
  const m = Math.hypot(gx, gy, gz) || 1;
  return -((s.ax * gx + s.ay * gy + s.az * gz) / m);
}
function gyroMag(s: SensorSample): number {
  if (s.gM != null) return s.gM;
  return Math.hypot(s.gx ?? 0, s.gy ?? 0, s.gz ?? 0);
}
function estimateDtMs(s: SensorSample[]): number {
  if (s.length < 6) return 20;
  const d: number[] = [];
  for (let i = 1; i < Math.min(60, s.length); i++) { const x = s[i]!.t - s[i - 1]!.t; if (x > 5 && x < 500) d.push(x); }
  return d.length > 3 ? median(d) : 20;
}
function dedupeByTime(s: SensorSample[]): SensorSample[] {
  const out: SensorSample[] = []; let last = -Infinity;
  for (const x of s) if (x.t > last) { out.push(x); last = x.t; }
  return out;
}

// ════════════════════════════════════════════════════════════════════════════
// Barometric altitude on the 50 Hz grid (robust baseline). Returns altitude (m)
// above the rider's ambient "sea level" at every sample.
// ════════════════════════════════════════════════════════════════════════════
export function baroAltitudeSeries(s: SensorSample[], params: JumpEngineV8Params): number[] {
  const n = s.length;
  // forward-fill the sparse baro onto the grid
  const baro = new Array<number>(n);
  let last = s.find((x) => x.baro != null)?.baro ?? 1013.25;
  for (let i = 0; i < n; i++) { if (s[i]!.baro != null) last = s[i]!.baro!; baro[i] = last; }

  // baseline: high-pressure percentile over a ± time window (robust to jumps).
  // Use the sparse UPDATE points to keep it cheap, then map back to the grid.
  const upIdx: number[] = []; const upVal: number[] = [];
  for (let i = 0; i < n; i++) if (s[i]!.baro != null && (!upVal.length || s[i]!.baro !== upVal[upVal.length - 1])) { upIdx.push(i); upVal.push(s[i]!.baro!); }
  const W = params.baselineHalfWinSec * 1000; // ms
  const baseUp = upVal.map((_, k) => {
    const w: number[] = [];
    for (let j = 0; j < upVal.length; j++) if (Math.abs(s[upIdx[j]!]!.t - s[upIdx[k]!]!.t) <= W) w.push(upVal[j]!);
    w.sort((a, b) => a - b);
    return w[Math.min(w.length - 1, Math.floor(w.length * params.baselinePctile))]!;
  });
  // map baseline back to grid (nearest update point)
  const base = new Array<number>(n);
  let k = 0;
  for (let i = 0; i < n; i++) {
    while (k + 1 < upIdx.length && upIdx[k + 1]! <= i) k++;
    base[i] = baseUp[k] ?? upVal[k] ?? baro[i]!;
  }
  return baro.map((b, i) => (base[i]! - b) * P2M);
}

// ════════════════════════════════════════════════════════════════════════════
// Whole-session detection: find barometric-altitude apexes (jumps), refine each
// apex by parabolic interpolation on the raw baro points, bracket airtime by the
// out-of-water crossings, and attribute a take-off pop for timing/diagnostics.
// ════════════════════════════════════════════════════════════════════════════
export function detectJumpsV8(
  samplesIn: SensorSample[],
  params: JumpEngineV8Params = DEFAULT_V8_PARAMS,
): JumpResultV8[] {
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

  const out: JumpResultV8[] = [];
  let lastApexT = -Infinity;
  const sepMs = params.jumpSepSec * 1000;
  const maxAirSamp = Math.round(params.maxAirTimeSec / dt);

  for (let u = 1; u < upIdx.length - 1; u++) {
    const i = upIdx[u]!;
    if (alt[i]! < params.minJumpHeightM) continue;
    // local max on the sparse baro series
    if (!(upAlt[u]! >= upAlt[u - 1]! && upAlt[u]! >= upAlt[u + 1]!)) continue;
    if (s[i]!.t - lastApexT < sepMs) {
      if (out.length && alt[i]! > out[out.length - 1]!.jumpHeightM) out.pop(); else continue;
    }

    // parabolic apex refinement through (u-1,u,u+1)
    const y0 = upAlt[u - 1]!, y1 = upAlt[u]!, y2 = upAlt[u + 1]!;
    const den = y0 - 2 * y1 + y2;
    let apexH = y1;
    if (Math.abs(den) > 1e-6) { const d = 0.5 * (y0 - y2) / den; apexH = y1 - 0.25 * (y0 - y2) * d; }
    apexH = Math.min(Math.max(apexH, y1), params.maxPlausibleHeightM);

    // AIRTIME from PHYSICS, not from the baro bracket. At 0.36 Hz the baro can't
    // time a ~4 s arc and the soft kite landing has no accel spike, so a measured
    // airtime is wildly unstable (5–13 s). Instead derive it from the (accurate)
    // height: a kite extends the descent (glide), so the airtime is a multiple of
    // the symmetric ballistic flight 2·√(2h/g). Fitted to Surfr → RMS 0.28 s.
    const airTimeSec = params.kiteGlideFactor * 2 * Math.sqrt(2 * apexH / G);
    if (airTimeSec < params.minAirTimeSec) continue;

    // loose on-water bracket only to locate the take-off (for the pop/timing).
    let t0 = Math.max(0, i - maxAirSamp);
    for (let k = i; k > Math.max(0, i - maxAirSamp); k--) { if (alt[k]! < params.onWaterAltM) { t0 = k; break; } }
    let tl = Math.min(n - 1, i + maxAirSamp);
    for (let k = i; k < Math.min(n - 1, i + maxAirSamp); k++) { if (alt[k]! < params.onWaterAltM) { tl = k; break; } }

    // ── KITE-AWARE NOISE FILTER ──────────────────────────────────────────
    // (a) RUN-UP SPEED: a kite jump launches while planing. If the rider was not
    //     moving fast in the seconds before the apex, this baro bump is the rider
    //     standing / drifting / back at the beach, or a stray pressure wiggle —
    //     not a jump. (This removed the spd≈0 false apexes that out-read the real
    //     jumps on the test log.)
    const runUpSamp = Math.round(params.runUpWindowSec / dt);
    let runUpSpeed = 0;
    for (let k = Math.max(0, i - runUpSamp); k <= i; k++) { const sp = s[k]!.spd; if (sp != null && sp > runUpSpeed) runUpSpeed = sp; }
    if (runUpSpeed < params.jumpRunUpSpeed) continue;

    // (b) BARO SUPPORT (soft): count neighbouring baro updates that are also
    //     elevated (≥ a third of the apex). A well-supported arc is more
    //     trustworthy; a lone spike on a fast rider is rare so this only feeds
    //     confidence (a real but short jump may legitimately have one baro point).
    let support = 0;
    for (let d = 1; d <= 3; d++) { if (upAlt[u - d] != null && upAlt[u - d]! >= apexH / 3) support++; if (upAlt[u + d] != null && upAlt[u + d]! >= apexH / 3) support++; }

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

    // distance: GPS speed at take-off × airtime
    let spd: number | null = null, bd = Infinity;
    for (const x of s) { if (x.spd == null) continue; const d = Math.abs(x.t - s[t0]!.t); if (d < bd) { bd = d; spd = x.spd; } }
    const distanceM = spd != null ? Math.round(spd * airTimeSec * 10) / 10 : null;

    // confidence: multi-signal agreement (baro height + planing + pop + airborne
    // calm-window + bar-pull). Each independent channel that agrees raises it.
    let conf = 0.35;
    if (runUpSpeed >= params.jumpRunUpSpeed + 2) conf += 0.15;      // solidly planing
    if (apexH >= params.minJumpHeightM + 0.5) conf += 0.12;
    if (peakUp >= params.popUpG) conf += 0.12;
    if (support >= 2) conf += 0.08;                                 // well-supported baro arc
    if (airborneConfirmed) conf += 0.15;                           // IMU calm window agrees
    if (barPullConfirmed) conf += 0.08;                            // bar-pull present
    // measured airtime agrees with the height-derived airtime → strong evidence
    if (airborneConfirmed && Math.abs(measuredAirtime - airTimeSec) < 1.5) conf += 0.05;
    conf = Math.max(0, Math.min(1, conf));

    lastApexT = s[i]!.t;
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
    });
  }

  // ── BALLISTIC THROW PATH (optional, speed-disjoint from the kite path) ──
  if (params.detectThrows) out.push(...detectThrowsBallistic(s, params, dt, out));

  // keep chronological order (kite apexes + throws interleaved)
  out.sort((a, b) => (a.takeoffTimeMs ?? 0) - (b.takeoffTimeMs ?? 0));
  return out;
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
  s: SensorSample[], params: JumpEngineV8Params, dt: number, kiteJumps: JumpResultV8[],
): JumpResultV8[] {
  const n = s.length;
  const accM = (x: SensorSample) => x.aM ?? Math.hypot(x.ax, x.ay, x.az);
  const maxAir = Math.round(params.maxAirTimeSec / dt);
  const throwMinAir = Math.round(params.throwFreefallMinSec / dt);
  const out: JumpResultV8[] = [];
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
export function toJumpEventV8(r: JumpResultV8, takeoff: SensorSample): JumpEvent {
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
