/**
 * jumpDetect — professional kitesurf jump detection + height estimation.
 *
 * Models a real kite jump the way WOO / Surfr-class devices do, NOT as a naive
 * symmetric ballistic arc:
 *
 *   • TAKEOFF: the rider edges hard and the kite yanks them up → a sharp
 *     acceleration spike as the board leaves the water.
 *   • AIRBORNE: under kite lift the linear-acceleration magnitude collapses
 *     toward (but not to) ~0 g. The lowest-g instant is the APEX.
 *   • HANGTIME: the kite holds the rider up, so the descent is LONGER than the
 *     ascent — the arc is asymmetric. Height therefore comes from the *rise*
 *     time (takeoff→apex), h = ½·g·t_rise², not from g·airtime²/8.
 *   • LANDING: a second spike when the board hits the water.
 *
 * Robustness (the watch is on a wrist that moves freely + chop + noise):
 *   • Orientation-independent: we work on |a| magnitude, never a single axis.
 *   • Low-pass smoothing removes wrist jitter / wave chop before detection.
 *   • Hysteresis + refractory + min-height gate reject small hops & noise.
 *
 * Everything tunable lives in JumpDetectParams so the calibration app (and an
 * auto/manual optimiser) can fit the model to ground-truth heights without
 * touching detection structure.
 */

import type { SensorSample, JumpEvent } from './types';

const G = 9.80665; // m/s²

export interface JumpDetectParams {
  /** Moving-average half-window (samples) for low-pass on |a|. 0 = off. */
  smoothingWindow: number;
  /** Below this |a| (g) the rider is considered airborne. */
  airborneMaxG: number;
  /** A takeoff/landing spike must exceed this |a| (g). */
  spikeMinG: number;
  /** Minimum airborne window (ms) — rejects chop / small hops. */
  minAirborneMs: number;
  /** Maximum plausible airborne window (ms) — rejects sensor dropouts. */
  maxAirborneMs: number;
  /** A takeoff spike must occur within this window before airborne start (ms). */
  preSpikeWindowMs: number;
  /** Minimum gap between two jumps (ms) — debounce. */
  refractoryMs: number;
  /**
   * Height-model blend ∈ [0,1] between the two physical estimators:
   *   • INTEGRATION: double-integrate vertical acceleration over the airborne
   *     window (∫∫a_vert) with drift correction → physical trajectory height.
   *   • KINEMATIC: rise-time ballistics (½·g·t_rise²) from takeoff→apex.
   * 1 = trust the integration fully; 0 = trust the kinematic estimate.
   * The integration captures kite lift directly (no symmetry assumption); the
   * kinematic term is a robust fallback when the IMU integral is noisy.
   */
  integrationBlend: number;
  /**
   * Drift-correction strength ∈ [0,1] for the velocity integral. The IMU has a
   * bias that integrates into linear velocity drift; we subtract a baseline so
   * vertical velocity is ~0 at takeoff and landing. 1 = full linear detrend.
   */
  driftCorrection: number;
  /**
   * Fraction of g the airborne vertical accel is offset by (kite lift bias).
   * Removed before integration so the residual integrates to true displacement.
   */
  liftBiasG: number;
  /** Reject detected jumps whose estimated height is below this (m). */
  minJumpHeightM: number;
}

/**
 * Defaults tuned for kitesurf. The optimiser fits the PHYSICAL knobs
 * (thresholds, smoothing, integrationBlend, driftCorrection, liftBiasG) — there
 * is no linear height fudge factor.
 */
export const DEFAULT_PARAMS: JumpDetectParams = {
  smoothingWindow: 1,
  airborneMaxG: 0.3625,
  spikeMinG: 1.5,
  minAirborneMs: 400,
  maxAirborneMs: 6500,
  preSpikeWindowMs: 700,
  refractoryMs: 1000,
  integrationBlend: 0.57421875,
  driftCorrection: 1.0769531249999995,
  liftBiasG: -0.22617187499999997,
  minJumpHeightM: 0.3,
};

/**
 * Acceleration magnitude in g for a sample.
 * ax/ay/az are in g (userAcceleration, gravity removed) — no conversion needed.
 * Uses pre-computed aM from the watch CSV when available (saves sqrt).
 */
function magG(s: SensorSample): number {
  if (s.aM != null) return s.aM;
  return Math.sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az);
}

/** Pre-compute a low-pass-smoothed |a| (g) series — orientation independent. */
function smoothedMagG(samples: SensorSample[], halfWin: number): number[] {
  const raw = samples.map(magG);
  if (halfWin <= 0) return raw;
  const out = new Array<number>(raw.length);
  for (let i = 0; i < raw.length; i++) {
    let sum = 0;
    let n = 0;
    for (let k = i - halfWin; k <= i + halfWin; k++) {
      if (k >= 0 && k < raw.length) {
        sum += raw[k]!;
        n++;
      }
    }
    out[i] = sum / n;
  }
  return out;
}

function nearestGps(samples: SensorSample[], idx: number): { lat?: number; lng?: number; spd?: number } {
  for (let i = idx; i >= 0; i--) {
    const s = samples[i];
    if (s && s.lat != null && s.lng != null) return { lat: s.lat, lng: s.lng, spd: s.spd };
  }
  return {};
}

/**
 * Run detection over a full raw sample stream and emit JumpEvents in the
 * compact app format (cm, tenths-of-second, km/h, dm, lat/lng*1e4).
 */
export function detectJumpsV4(
  samples: SensorSample[],
  params: JumpDetectParams = DEFAULT_PARAMS,
): JumpEvent[] {
  const jumps: JumpEvent[] = [];
  if (samples.length < 3) return jumps;

  const gmag = smoothedMagG(samples, params.smoothingWindow);

  let lastJumpEnd = -Infinity;
  let airborneStart = -1;
  let sawPreSpike = false;
  let preSpikeAt = -Infinity;
  let peakSpeedDuringAir = 0;

  for (let i = 0; i < samples.length; i++) {
    const s = samples[i]!;
    const g = gmag[i]!;

    if (g >= params.spikeMinG) {
      sawPreSpike = true;
      preSpikeAt = s.t;
    }

    const airborne = g <= params.airborneMaxG;

    if (airborne && airborneStart < 0) {
      const hadRecentSpike = sawPreSpike && s.t - preSpikeAt <= params.preSpikeWindowMs;
      if (hadRecentSpike && s.t - lastJumpEnd >= params.refractoryMs) {
        airborneStart = i;
        peakSpeedDuringAir = s.spd ?? 0;
      }
    } else if (airborneStart >= 0) {
      if (s.spd != null) peakSpeedDuringAir = Math.max(peakSpeedDuringAir, s.spd);

      const landed = g >= params.spikeMinG || g > 1.2;
      if (landed) {
        const start = samples[airborneStart]!;
        const airMs = s.t - start.t;
        if (airMs >= params.minAirborneMs && airMs <= params.maxAirborneMs) {
          const jump = buildJump(samples, gmag, airborneStart, i, peakSpeedDuringAir, params);
          if (jump.h / 100 >= params.minJumpHeightM) jumps.push(jump);
          lastJumpEnd = s.t;
        }
        airborneStart = -1;
        sawPreSpike = false;
      }
    }
  }

  return jumps;
}

/**
 * Estimate the "up" unit vector from the takeoff pop. The launch spike points
 * along the kite-pull / board-pop direction, which is the rider's up axis at
 * takeoff. Orientation-independent (the watch may be in any pose).
 */
function takeoffUpVector(
  samples: SensorSample[],
  startIdx: number,
): { ux: number; uy: number; uz: number } {
  // Average the few samples just before airborne (the pop).
  let sx = 0, sy = 0, sz = 0;
  const from = Math.max(0, startIdx - 4);
  for (let k = from; k < startIdx; k++) {
    const s = samples[k]!;
    sx += s.ax; sy += s.ay; sz += s.az;
  }
  const mag = Math.hypot(sx, sy, sz) || 1;
  return { ux: sx / mag, uy: sy / mag, uz: sz / mag };
}

/**
 * Physical height from DOUBLE INTEGRATION of vertical acceleration over the
 * airborne window, with linear drift correction — captures kite lift directly
 * (no symmetric-arc / free-fall assumption). Blended with the rise-time
 * kinematic estimate for robustness. NO linear scale factor.
 */
function integratedHeight(
  samples: SensorSample[],
  startIdx: number,
  endIdx: number,
  apexIdx: number,
  params: JumpDetectParams,
): number {
  const up = takeoffUpVector(samples, startIdx);

  // 1. Vertical specific acceleration (g) along the up axis, lift bias removed.
  //    ax/ay/az are in g, so the projection is also in g.
  const aVert: { t: number; a: number }[] = [];
  for (let k = startIdx; k <= endIdx; k++) {
    const s = samples[k]!;
    const aUp = s.ax * up.ux + s.ay * up.uy + s.az * up.uz; // g along up
    aVert.push({ t: s.t / 1000, a: aUp - params.liftBiasG });
  }
  if (aVert.length < 3) return 0;

  // 2. Integrate accel (g) → velocity (g·s) — trapezoidal.
  const vel: number[] = [0];
  for (let i = 1; i < aVert.length; i++) {
    const dt = aVert[i]!.t - aVert[i - 1]!.t;
    vel.push(vel[i - 1]! + ((aVert[i]!.a + aVert[i - 1]!.a) / 2) * dt);
  }

  // 3. Drift correction: subtract linear ramp so v(start)≈0 and v(end)≈0.
  const n = vel.length;
  const vEnd = vel[n - 1]!;
  for (let i = 0; i < n; i++) {
    vel[i] = vel[i]! - params.driftCorrection * (vEnd * (i / (n - 1)));
  }

  // 4. Integrate velocity (g·s) → displacement (g·s²); peak × G → metres.
  let disp = 0;
  let peak = 0;
  for (let i = 1; i < n; i++) {
    const dt = aVert[i]!.t - aVert[i - 1]!.t;
    disp += ((vel[i]! + vel[i - 1]!) / 2) * dt;
    if (disp > peak) peak = disp;
  }
  return Math.max(0, peak * G); // g·s² × m/s² per g = metres
}

/**
 * Build a JumpEvent. Height blends two PHYSICAL estimators (no linear scale):
 *  - INTEGRATION: ∫∫ vertical accel over the airborne window (drift-corrected).
 *  - KINEMATIC:   rise-time ballistics ½·g·t_rise² (apex = min |a|).
 *  h = blend·h_integ + (1−blend)·h_kin
 */
function buildJump(
  samples: SensorSample[],
  gmag: number[],
  startIdx: number,
  endIdx: number,
  topSpeedMs: number,
  params: JumpDetectParams,
): JumpEvent {
  const start = samples[startIdx]!;
  const end = samples[endIdx]!;
  const tAirSec = (end.t - start.t) / 1000;

  // Apex = minimum |a| within the airborne window.
  let apexIdx = startIdx;
  let apexG = Infinity;
  for (let k = startIdx; k <= endIdx; k++) {
    if (gmag[k]! < apexG) {
      apexG = gmag[k]!;
      apexIdx = k;
    }
  }
  const tRiseSec = Math.max(0.05, (samples[apexIdx]!.t - start.t) / 1000);

  const hKin = 0.5 * G * tRiseSec * tRiseSec;
  const hInteg = integratedHeight(samples, startIdx, endIdx, apexIdx, params);
  const heightM = params.integrationBlend * hInteg + (1 - params.integrationBlend) * hKin;

  const topSpeedKmh = topSpeedMs * 3.6;
  const distM = topSpeedMs * tAirSec;
  const gps = nearestGps(samples, startIdx);

  return {
    t: Math.round(start.t / 1000),
    h: Math.round(heightM * 100),     // cm
    a: Math.round(tAirSec * 10),      // tenths of a second
    s: Math.round(topSpeedKmh),       // km/h
    d: Math.round(distM * 10),        // dm
    y: gps.lat != null ? Math.round(gps.lat * 1e4) : 0,
    x: gps.lng != null ? Math.round(gps.lng * 1e4) : 0,
  };
}

/** Summary stats for a detected set — handy for the live UI + end-of-session. */
export function summarise(jumps: JumpEvent[]): {
  jcnt: number;
  jmaxM: number;
  airMaxS: number;
  topSpeedKmh: number;
} {
  let jmax = 0, airMax = 0, top = 0;
  for (const j of jumps) {
    jmax = Math.max(jmax, j.h);
    airMax = Math.max(airMax, j.a);
    top = Math.max(top, j.s);
  }
  return { jcnt: jumps.length, jmaxM: jmax / 100, airMaxS: airMax / 10, topSpeedKmh: top };
}
