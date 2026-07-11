/**
 * trajectoryV9 — the Vertical Trajectory Reconstruction Engine (V9 core).
 *
 * Per the governing design philosophy (Engineering Insights): the product output
 * is "Maximum WATCH Height" — the wrist's own vertical trajectory. We do NOT
 * "detect a spike then compute height"; we RECONSTRUCT the most probable vertical
 * trajectory z(t) over the complete jump event [take-off, landing] from ALL the
 * measurements, then read max z and validate physical consistency.
 *
 * BARO-ANCHORED, accel-ASSISTED (proven constraint): the kite vertical rise is
 * NOT in the wrist accelerometer (it integrates to ~0). So the barometer is the
 * drift-free vertical-POSITION sensor; the accel only shapes/times the curve
 * between sparse baro samples and constrains velocity. NEVER integrate accel for
 * the absolute height.
 *
 * THE ≤5 s KEY — endpoint anchors replace the ±15 s baseline: at take-off and
 * landing the watch is ON THE WATER → z=0 and v=0 there (ZUPT). Those two anchors
 * fix "sea level" from the jump's OWN boundaries, so we need only the event window
 * (+ a few seconds of on-water context), NOT ±15 s of future → the result is ready
 * within ~5 s of landing.
 *
 * Estimator: a batch MAP / smoothing-spline (Gaussian → linear least squares) on a
 * uniform grid. Cost = baro data terms + endpoint position/velocity anchors +
 * curvature smoothness (tied softly to the measured vertical accel). Minimising it
 * is a symmetric positive-definite banded system → one linear solve per jump.
 */

import type { SensorSample } from './types.ts';
import type { JumpResult } from './jumpEngine.ts';

const G = 9.80665;
const P2M = 8.43; // hPa → m near sea level

export interface ReconstructParams {
  gridHz: number;          // reconstruction grid rate (decimated from 50 Hz IMU)
  onWaterSec: number;      // ± window of on-water samples around each endpoint → baseline
  baroDespikeHpa: number;  // one-sided upward de-spike (garbage > localMed + this)
  // MAP weights (precision = 1/σ²). Tuned against the Surfr golden.
  wBaro: number;           // baro position measurement
  wAnchorPos: number;      // z=0 at take-off & landing
  wAnchorVel: number;      // v=0 at take-off & landing
  wSmooth: number;         // curvature (2nd-difference) smoothness
  wAccel: number;          // soft tie of curvature to the measured vertical accel
  // validation (physical consistency, not detection thresholds)
  minHeightM: number;      // a real jump clears this
  minAirSec: number;       // and lasts at least this
  maxRiseFrac: number;     // apex must be interior (not at an endpoint)
}

export const DEFAULT_RECON_PARAMS: ReconstructParams = {
  gridHz: 10,
  onWaterSec: 3,
  baroDespikeHpa: 1.0,
  wBaro: 6,        // baro σ ≈ 0.4 m
  wAnchorPos: 40,  // endpoints are firmly at water level
  wAnchorVel: 8,
  wSmooth: 30,
  wAccel: 0.0,     // accel is weak for vertical → default off (assists timing only)
  minHeightM: 1.5,
  minAirSec: 1.5,
  maxRiseFrac: 0.9,
};

export interface TrajectoryResult {
  maxHeightM: number;
  apexTimeMs: number;
  takeoffTimeMs: number;
  landingTimeMs: number;
  airtimeSec: number;
  z: number[];      // reconstructed vertical trajectory (m) on the grid
  tMs: number[];    // grid times
  baselineHpa: number;
  valid: boolean;   // physical-consistency verdict
  reject?: string;  // why rejected (if !valid)
}

function median(a: number[]): number { if (!a.length) return 0; const s = [...a].sort((x, y) => x - y); return s[s.length >> 1]!; }

/** World-vertical (up) user-acceleration in m/s² (gravity already removed). */
function vertAccelMs2(s: SensorSample): number {
  const gx = s.gvX ?? 0, gy = s.gvY ?? 0, gz = s.gvZ ?? -1;
  const m = Math.hypot(gx, gy, gz) || 1;
  return -((s.ax * gx + s.ay * gy + s.az * gz) / m) * G;
}

/**
 * Reconstruct the vertical trajectory over [t0Ms, t1Ms] (the jump event) and read
 * the maximum watch height. `t0/t1` are the take-off / landing instants; a few
 * seconds of on-water context on each side define the local water-level baseline.
 */
export function reconstructTrajectory(
  samples: SensorSample[],
  t0Ms: number,
  t1Ms: number,
  params: ReconstructParams = DEFAULT_RECON_PARAMS,
): TrajectoryResult {
  const dt = 1 / params.gridHz;
  const ctx = params.onWaterSec * 1000;

  // ── local water-level baseline: on-water baro just before take-off & after
  //    landing (de-spiked one-sided). These bracket the jump at z≈0. ──
  const onWater: number[] = [];
  for (const s of samples) {
    if (s.baro == null) continue;
    if ((s.t >= t0Ms - ctx && s.t <= t0Ms) || (s.t >= t1Ms && s.t <= t1Ms + ctx)) onWater.push(s.baro);
  }
  const med = median(onWater);
  const baseline = onWater.length ? median(onWater.filter((b) => b <= med + params.baroDespikeHpa)) : med;

  // ── grid over the event window ──
  const N = Math.max(4, Math.round((t1Ms - t0Ms) / 1000 * params.gridHz));
  const tMs = new Array<number>(N + 1);
  for (let k = 0; k <= N; k++) tMs[k] = t0Ms + (k / N) * (t1Ms - t0Ms);

  // baro observation per grid node (z = (baseline − baro)·P2M), de-spiked.
  const obs = new Array<number | null>(N + 1).fill(null);
  // accel (m/s²) per grid node, averaged from the IMU samples in the cell.
  const accel = new Array<number>(N + 1).fill(0);
  {
    const baroPts: { t: number; b: number }[] = [];
    for (const s of samples) if (s.baro != null && s.t >= t0Ms - ctx && s.t <= t1Ms + ctx) baroPts.push({ t: s.t, b: s.baro });
    for (let k = 0; k <= N; k++) {
      // nearest baro point within half a grid cell
      let best = Infinity, bv: number | null = null;
      for (const p of baroPts) { const d = Math.abs(p.t - tMs[k]!); if (d < best && d <= (1000 / params.gridHz) / 2) { best = d; bv = p.b; } }
      if (bv != null) { const clean = bv > baseline + params.baroDespikeHpa ? baseline : bv; obs[k] = (baseline - clean) * P2M; }
    }
    // accel per cell
    let si = 0;
    for (let k = 0; k <= N; k++) {
      const lo = tMs[k]! - 500 * dt, hi = tMs[k]! + 500 * dt;
      let sum = 0, cnt = 0;
      for (; si < samples.length && samples[si]!.t < lo; si++) { /* advance */ }
      for (let j = si; j < samples.length && samples[j]!.t <= hi; j++) { sum += vertAccelMs2(samples[j]!); cnt++; }
      accel[k] = cnt ? sum / cnt : 0;
    }
  }

  // ── batch MAP / smoothing-spline: minimise the quadratic cost → A z = c ──
  const z = solveTrajectory(N, dt, obs, accel, params);

  // apex (interior max), airtime, validation.
  let apexK = 0, maxH = -Infinity;
  for (let k = 0; k <= N; k++) if (z[k]! > maxH) { maxH = z[k]!; apexK = k; }
  const airtimeSec = (t1Ms - t0Ms) / 1000;

  // physical consistency: interior apex, sustained single hump, returns to ~0.
  let reject: string | undefined;
  if (maxH < params.minHeightM) reject = 'below min height';
  else if (airtimeSec < params.minAirSec) reject = 'below min airtime';
  else if (apexK <= N * (1 - params.maxRiseFrac) || apexK >= N * params.maxRiseFrac) reject = 'apex at edge (not a hump)';
  else if (!coherentHump(z, apexK)) reject = 'incoherent ascent/descent';

  return {
    maxHeightM: Math.round(Math.max(0, maxH) * 100) / 100,
    apexTimeMs: tMs[apexK]!,
    takeoffTimeMs: t0Ms,
    landingTimeMs: t1Ms,
    airtimeSec: Math.round(airtimeSec * 100) / 100,
    z, tMs, baselineHpa: Math.round(baseline * 100) / 100,
    valid: reject == null,
    reject,
  };
}

/** A coherent jump rises (mostly) to the apex then falls — not a step / spike. */
function coherentHump(z: number[], apexK: number): boolean {
  const N = z.length - 1;
  const up = monotoneFrac(z.slice(0, apexK + 1), +1);
  const down = monotoneFrac(z.slice(apexK), -1);
  return up >= 0.7 && down >= 0.7 && apexK > 1 && apexK < N - 1;
}
function monotoneFrac(a: number[], sign: number): number {
  if (a.length < 2) return 1;
  let ok = 0; for (let i = 1; i < a.length; i++) if (Math.sign(a[i]! - a[i - 1]!) === sign || a[i] === a[i - 1]) ok++;
  return ok / (a.length - 1);
}

/**
 * Solve the MAP trajectory: minimise
 *   Σ wBaro·(z_k−obs_k)²  +  wAnchorPos·(z_0²+z_N²)  +  wAnchorVel·((z_1−z_0)²+(z_N−z_{N-1})²)
 *   + wSmooth·Σ(z_{k-1}−2z_k+z_{k+1})²  + wAccel·Σ((z_{k-1}−2z_k+z_{k+1})/dt² − a_k)²
 * → a symmetric positive-definite system A z = c. Solved densely (N≈50, trivial).
 */
function solveTrajectory(N: number, dt: number, obs: (number | null)[], accel: number[], p: ReconstructParams): number[] {
  const n = N + 1;
  const A: number[][] = Array.from({ length: n }, () => new Array<number>(n).fill(0));
  const c = new Array<number>(n).fill(0);
  const add = (i: number, j: number, v: number) => { if (i >= 0 && i < n && j >= 0 && j < n) A[i]![j]! += v; };

  // baro data terms
  for (let k = 0; k < n; k++) if (obs[k] != null) { A[k]![k]! += 2 * p.wBaro; c[k]! += 2 * p.wBaro * (obs[k] as number); }
  // position anchors z_0=0, z_N=0
  A[0]![0]! += 2 * p.wAnchorPos; A[N]![N]! += 2 * p.wAnchorPos;
  // velocity anchors (z_1−z_0)=0, (z_N−z_{N-1})=0
  for (const [a, b] of [[0, 1], [N, N - 1]] as const) {
    add(a, a, 2 * p.wAnchorVel); add(b, b, 2 * p.wAnchorVel); add(a, b, -2 * p.wAnchorVel); add(b, a, -2 * p.wAnchorVel);
  }
  // curvature smoothness + soft accel tie: for each interior j, r = z_{j-1}−2z_j+z_{j+1}
  const dt2 = dt * dt;
  for (let j = 1; j < N; j++) {
    const w = p.wSmooth + p.wAccel / (dt2 * dt2);
    const stencil = [[j - 1, 1], [j, -2], [j + 1, 1]] as const;
    for (const [r, cr] of stencil) for (const [s, cs] of stencil) add(r, s, 2 * w * cr * cs);
    if (p.wAccel > 0) { const target = accel[j]! * dt2; for (const [r, cr] of stencil) c[r]! += 2 * (p.wAccel / dt2) * cr * target; }
  }

  return gaussSolve(A, c);
}

// ════════════════════════════════════════════════════════════════════════════
// PER-JUMP VIEW — the watch's vertical trajectory + the raw sensors over a jump,
// for the dashboard graph. The baro is the real height (the only sensor that sees
// the non-ballistic rise); the vertical accel is ~0 during the float (the kite
// lift cancels gravity → equilibrium → the accel is BLIND to the rise — this is
// why the height must come from the baro).
// ════════════════════════════════════════════════════════════════════════════

export interface JumpTrajectoryPoint {
  tSec: number;          // seconds relative to the APEX (apex = 0)
  baroAltM: number;      // watch height above the LOCAL water level (0 on water)
  reconAltM: number;     // GREEN — explicit PHYSICAL jump arc: an asymmetric hump pinned
                         // to 0 at take-off/landing, peak = near-apex baro reading, rise/
                         // fall widths from the airtime. Fills the sparse-baro gaps with
                         // physics (not interpolation) → the trajectory the watch flew.
  accelAltM: number;     // RED — the PURE accel DISTANCE (NO baro): vertical accel DOUBLE-
                         // integrated (→ position), ZUPT ends, clamped ≥0 (a rise distance,
                         // not a velocity). Stays ≈0: the accel can't size the rise.
  vertAccelG: number;    // world-vertical user accel (≈0 airborne — equilibrium)
  gyroMag: number;       // |ω| rad/s (rotations)
  speedKmh: number | null;
}
export interface JumpTrajectoryView {
  maxHeightM: number;    // = the jump's height
  airtimeSec: number;
  markersSec: number[];  // [take-off (0), apex, landing] on the tSec axis (0 = TAKE-OFF)
  peakSec: number;       // apex time on the tSec axis (for the peak marker)
  apexMeasured: boolean; // true = apex time from the baro; false = 40/60 physical default
  confidence: number;    // engine composite confidence (incl. the |a| float cross-check)
  specForceQuieting: number; // |a|-std in-flight ÷ on-water (< 0.85 real float, > 1 drift)
  driftSuspect: boolean; // no real float → the baro height may be baro-drift-inflated
  points: JumpTrajectoryPoint[];
}

function vertAccelG(s: SensorSample): number {
  const gx = s.gvX ?? 0, gy = s.gvY ?? 0, gz = s.gvZ ?? -1;
  const m = Math.hypot(gx, gy, gz) || 1;
  return -((s.ax * gx + s.ay * gy + s.az * gz) / m);
}

/** Build the per-jump trajectory + sensor series for plotting. Uses the ENGINE's
 *  accurate altitude series `alt` (which peaks at the real jump height), CENTRES
 *  the window on the actual apex (max alt), and CLAMPS negatives to 0 (there is no
 *  negative height — on the water the altitude is 0, the jump is a positive delta,
 *  back to 0 on landing). `alt` = baroAltitudeSeries(samples, params). */
export function jumpTrajectoryView(
  samples: SensorSample[],
  alt: number[],
  jump: JumpResult,
): JumpTrajectoryView {
  const n = samples.length;
  const airMs = Math.max(jump.airTimeSec * 1000, 2000);
  const tkEngine = jump.takeoffTimeMs ?? 0;

  // apex = MAX of the engine's altitude (de-spiked, robust) near the jump.
  let apexMs = tkEngine, maxA = -Infinity;
  for (let i = 0; i < n; i++) { const t = samples[i]!.t; if (t >= tkEngine - 4000 && t <= tkEngine + airMs + 4000 && alt[i]! > maxA) { maxA = alt[i]!; apexMs = t; } }

  // ASYMMETRIC bracket, 0 = TAKE-OFF: the rise (take-off → apex) is the MEASURED
  // interval from the real take-off (accel pop) to the baro apex; the kite yanks you
  // up fast then floats you down slowly, so the fall (apex → landing) fills the rest
  // of the airtime and is LONGER. Falls back to a 40/60 rise/fall split if the engine
  // gave no usable take-off.
  let riseMs = apexMs - tkEngine;
  // apexMeasured = the baro-apex time is CONSISTENT with the take-off (rise sits inside
  // the airtime). If not, we fall back to a physical 40/60 default — the asymmetry is
  // then NOT measured, just assumed. (The baro-apex is coarse anyway: ±~1.4 s at 0.34 Hz.)
  const apexMeasured = riseMs > 300 && riseMs < airMs;
  if (!apexMeasured) riseMs = airMs * 0.4;
  const fallMs = Math.max(riseMs, airMs - riseMs); // fall ≥ rise (kite float)
  const evT0 = apexMs - riseMs, evT1 = apexMs + fallMs;

  const lo = evT0 - 2000, hi = evT1 + 3000; // show 2 s of run-up + 3 s after landing

  // on-water accel bias (world-vertical m/s²) from the context around the event.
  const bctx = 3000; const onW: number[] = [];
  for (const s of samples) if ((s.t >= evT0 - bctx && s.t < evT0) || (s.t > evT1 && s.t <= evT1 + bctx)) onW.push(vertAccelMs2(s));
  const aBias = onW.length ? onW.reduce((p, c) => p + c, 0) / onW.length : 0;

  // ── plot grid + sparse baro ANCHORS (the real 0.34 Hz absolute observations) ──
  const step = 1000 / 10;
  const gT: number[] = [], gBaro: number[] = [], gAms2: number[] = [], gVa: number[] = [], gGy: number[] = [], gSp: (number | null)[] = [];
  let si = 0;
  for (let t = lo; t <= hi; t += step) {
    while (si + 1 < n && samples[si + 1]!.t <= t) si++;
    const s = samples[si]!;
    gT.push(t);
    gBaro.push(Math.max(0, alt[si] ?? 0));
    gAms2.push(vertAccelMs2(s) - aBias);
    gVa.push(vertAccelG(s));
    gGy.push(s.gM ?? Math.hypot(s.gx ?? 0, s.gy ?? 0, s.gz ?? 0));
    gSp.push(s.spd != null ? Math.round(s.spd * 3.6) : null);
  }

  // ── RED — the PURE accel DISTANCE, NO barometer: DOUBLE-integrate the vertical accel
  //    (accel → velocity → POSITION), ZUPT (v=0,z=0 at take-off & landing). This is the
  //    vertical DISTANCE risen/fallen at each instant (a height, so clamped ≥0 — never
  //    negative). It should be a ≥0 hump; that it stays ≈0 shows the accel can't size
  //    the rise without a drift-correcting reference (the whole point). ──
  const disp = accelDoubleIntegral(gT, gAms2, evT0, evT1);
  const red = gT.map((t, k) => (t <= evT0 || t >= evT1 ? 0 : Math.max(0, disp[k]!)));

  // ── GREEN — explicit PHYSICAL jump ARC: an ASYMMETRIC hump pinned to 0 at take-off &
  //    landing, peaking at the near-apex baro reading (`peak`), with the rise (take-off→
  //    apex) and fall (apex→landing) widths taken from the airtime. Two parabola halves,
  //    each with a smooth (zero-slope) top, meeting at the apex — the kite up-fast /
  //    down-slow shape. This FILLS the sparse-baro gaps with physics, not interpolation. ──
  const peak = jump.jumpHeightM;
  const riseW = Math.max(1, apexMs - evT0), fallW = Math.max(1, evT1 - apexMs);
  const green = gT.map((t) => {
    if (t <= evT0 || t >= evT1) return 0;
    const u = t <= apexMs ? (apexMs - t) / riseW : (t - apexMs) / fallW; // 0 at apex, 1 at the edge
    return Math.max(0, Math.round(peak * (1 - u * u) * 100) / 100);
  });

  const points: JumpTrajectoryPoint[] = gT.map((t, i) => ({
    tSec: Math.round(((t - evT0) / 1000) * 100) / 100,          // 0 = TAKE-OFF
    baroAltM: Math.round(gBaro[i]! * 100) / 100,
    reconAltM: Math.round(green[i]! * 100) / 100,
    accelAltM: Math.round(red[i]! * 100) / 100,
    vertAccelG: Math.round(gVa[i]! * 100) / 100,
    gyroMag: Math.round(gGy[i]! * 100) / 100,
    speedKmh: gSp[i]!,
  }));
  const apexSec = Math.round(((apexMs - evT0) / 1000) * 100) / 100;
  return {
    maxHeightM: jump.jumpHeightM,
    airtimeSec: Math.round(((evT1 - evT0) / 1000) * 100) / 100,
    markersSec: [0, apexSec, Math.round(((evT1 - evT0) / 1000) * 100) / 100], // take-off / apex / landing
    peakSec: apexSec,
    apexMeasured, // true = apex time from the baro; false = 40/60 physical default
    confidence: jump.confidence,
    specForceQuieting: jump.specForceQuieting,
    driftSuspect: jump.driftSuspect,
    points,
  };
}

/** Double-integrate vertical accel over [t0,t1] with ZUPT (v=0, z=0 at both ends). */
function accelDoubleIntegral(gT: number[], aMs2: number[], t0: number, t1: number): number[] {
  const K = gT.length; const out = new Array<number>(K).fill(0);
  const idx: number[] = []; for (let k = 0; k < K; k++) if (gT[k]! >= t0 && gT[k]! <= t1) idx.push(k);
  const m = idx.length; if (m < 3) return out;
  const tot = gT[idx[m - 1]!]! - gT[idx[0]!]! || 1;
  const vel = new Array<number>(m).fill(0);
  for (let i = 1; i < m; i++) { const dt = (gT[idx[i]!]! - gT[idx[i - 1]!]!) / 1000; vel[i] = vel[i - 1]! + 0.5 * (aMs2[idx[i]!]! + aMs2[idx[i - 1]!]!) * dt; }
  const vEnd = vel[m - 1]!; for (let i = 0; i < m; i++) vel[i]! -= vEnd * ((gT[idx[i]!]! - gT[idx[0]!]!) / tot);
  const pos = new Array<number>(m).fill(0);
  for (let i = 1; i < m; i++) { const dt = (gT[idx[i]!]! - gT[idx[i - 1]!]!) / 1000; pos[i] = pos[i - 1]! + 0.5 * (vel[i]! + vel[i - 1]!) * dt; }
  const pEnd = pos[m - 1]!; for (let i = 0; i < m; i++) pos[i]! -= pEnd * ((gT[idx[i]!]! - gT[idx[0]!]!) / tot);
  for (let i = 0; i < m; i++) out[idx[i]!] = pos[i]!;
  return out;
}


/** Dense Gaussian elimination with partial pivoting (n small). */
function gaussSolve(A: number[][], b: number[]): number[] {
  const n = b.length;
  const M = A.map((row, i) => [...row, b[i]!]);
  for (let col = 0; col < n; col++) {
    let piv = col; for (let r = col + 1; r < n; r++) if (Math.abs(M[r]![col]!) > Math.abs(M[piv]![col]!)) piv = r;
    [M[col], M[piv]] = [M[piv]!, M[col]!];
    const d = M[col]![col]! || 1e-12;
    for (let r = 0; r < n; r++) {
      if (r === col) continue;
      const f = M[r]![col]! / d;
      if (f === 0) continue;
      for (let k = col; k <= n; k++) M[r]![k]! -= f * M[col]![k]!;
    }
  }
  return M.map((row, i) => row[n]! / (row[i]! || 1e-12));
}
