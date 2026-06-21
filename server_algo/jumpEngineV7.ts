/**
 * jumpEngineV7 — sensor-grounded kitesurf jump engine (TypeScript port of
 * KitesurfJumpEngine.swift / v7). This is the calibration-side mirror: the
 * WATCH CALIB panel runs it on uploaded real logs to tune `JumpEngineV7Params`
 * before they are shipped into the Swift detector.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * WHY v7 EXISTS (grounded in real watch logs, not the simulator)
 * ════════════════════════════════════════════════════════════════════════════
 *   1. The watch barometer CANNOT see a ≤4 m jump. Measured quantum ≈ 0.01 hPa
 *      ≈ 8 cm/step, held (ZOH) for ~0.3–0.5 s. A real 4 m throw produced NO
 *      measurable ΔP. So baro is NOT the primary height source — only trusted
 *      once ΔP clears the noise floor (≈0.06 hPa ≈ 50 cm, i.e. big kite jumps).
 *      Below that we use time-of-flight (kinematic).
 *
 *   2. userAcceleration has gravity REMOVED, so a still watch reads |a|≈0 g —
 *      identical to free-fall. "Airborne" therefore CANNOT be a low-g threshold
 *      (the legacy airborneMaxG=0.4 g is unreliable on a wrist). Detection is
 *      TRANSITION-based: adaptive release spike (+gyro) → ballistic → landing
 *      (impact spike | baro recovery | settle), with gyro as the discriminator.
 *
 * HEIGHT — adaptive hybrid:
 *      small jump → kinematic (g·t²/8); big jump → barometric (ΔP·8.43);
 *      between    → trust-weighted blend.
 *
 * UNITS (watch-native — see types.ts):
 *      accel g (gravity removed) · gyro rad/s · gravity g · baro hPa · t MILLISECONDS.
 */

import type { SensorSample, JumpEvent } from './types.ts';

const G = 9.80665;     // m/s²
const P2M = 8.43;      // hPa → m (sea level)
const TWO_PI = 2 * Math.PI;
const DEG2RAD = Math.PI / 180;

// ════════════════════════════════════════════════════════════════════════════
// Params (mirror Swift KitesurfJumpEngineV7.Config — the optimiser sweeps these)
// ════════════════════════════════════════════════════════════════════════════
export interface JumpEngineV7Params {
  // Baro pipeline
  baroMedianHalfWindow: number;
  baroLowPassAlpha1: number;
  baroLowPassAlpha2: number;
  // Baro significance (sensor-grounded — quantum ≈ 0.01 hPa)
  baroNoiseFloorHPa: number;   // below this baro is pure noise
  baroTrustLoHPa: number;      // baro starts to matter
  baroTrustHiHPa: number;      // baro fully trusted
  // Event detection (adaptive, kite-aware)
  releaseSigmaK: number;       // release = μ_ride + K·σ_ride …
  releaseFloorG: number;       // … never below this (g)
  releaseGyroMinRad: number;   // soft wrist-rotation confirmation
  landingSpikeG: number;       // hard-landing impact (g)
  landingSpikeGyro: number;    // hard-landing gyro floor (rad/s)
  // FIRST water-contact landing (kite jumps always touch down with a board slap
  // + wrist rotation). The accel slap can be modest but the gyro burst is large,
  // so the contact is detected by (aM ≥ landingContactG AND gyro ≥
  // landingContactGyro). This caps the airtime at the FIRST touchdown — so a
  // second jump is never chained into the same window (the cause of inflated
  // multi-second "jumps") while still allowing very long real hangtime.
  landingContactG: number;     // modest accel at water contact (g)
  landingContactGyro: number;  // wrist-rotation burst at water contact (rad/s)
  settleTolG: number;          // |a| within this of ride-mean = settled
  settleSamplesNeeded: number; // sustained calm samples → soft landing
  minAirTimeSec: number;
  hardLandingMinAirTimeSec: number;
  settleMinAirTimeSec: number;
  settleMinBaroDropHPa: number;
  maxAirTimeSec: number;       // kite-glide watchdog
  minJumpHeightM: number;      // gate (kinematic-capable → low)
  noiseRejectMaxDistanceM: number;
  noiseRejectMaxRotations: number;
  noiseRejectMaxDisplayedAirTimeSec: number;
  noiseRejectMaxHeightM: number;
  timeoutRecoveryMinBaroDropHPa: number;
  timeoutRecoveryMinPeakGyro: number;
  timeoutRecoveryMinTakeoffG: number;
  timeoutRecoveryMinHeightMeters: number;
  timeoutRecoveryMinBurstSamples: number;
  // Gyro
  gyroQualityThreshold: number; // rad/s — chaotic above
  gyroIsDegPerSec: boolean | null; // watch reports rad/s; null = auto
  // Kinematic calibration (compensates spike-clipped endpoints; tune from logs)
  kinematicCalibration: number;
  enableIMUBiasCorrection: boolean;
  // ── KITE-AWARE HEIGHT (asymmetric arc) ───────────────────────────
  // A kite holds the rider up → descent is LONGER than ascent, so airtime
  // OVER-estimates height via the symmetric g·t²/8. Real height comes from the
  // RISE time (take-off → apex): h = ½·g·t_rise². Below knobs gate/clamp this.
  //
  // Physical-consistency gate: reject a barometric reading that contradicts the
  // airtime envelope. A jump's height cannot exceed what its TOTAL airtime
  // allows even as a pure free-fall arc (g·t²/8). If baroH is more than this ×
  // tolerance, the baro is drift/spike noise, not height → fall back to rise-time.
  airtimeCeilingTolerance: number; // baroH may exceed sym-kin height by ≤ this ×
  // Absolute kitesurf sanity cap (m). Heights above this are non-physical.
  maxPlausibleHeightM: number;
  // Fraction of total airtime taken by the ASCENT for a symmetric arc (0.5).
  // Kite hangtime pushes the real ascent fraction below this; we estimate the
  // apex from baro/velocity and only fall back to this when no apex is found.
  // Fraction of total airtime taken by the ASCENT in a kite jump.
  // Symmetric free-fall = 0.5. Kite hangtime extends the descent → real ascent
  // fraction is lower (~0.30–0.40). Used when no valid baro apex is found AND
  // as a hard cap on the baro-derived apex position.
  symmetricAscentFraction: number;
  // Reference apps (Surfr) report a SHORTER airtime than the physical
  // spike-to-spike flight — they trim the tail of the kite glide. The internal
  // airTimeSec stays physical (it drives the height model); this scale is
  // applied only to the DISPLAYED airtime so the user-facing number matches the
  // reference. Calibrated to 0.73 from a Surfr session.
  displayedAirtimeScale: number;
}

export const DEFAULT_V7_PARAMS: JumpEngineV7Params = {
  baroMedianHalfWindow: 3,
  baroLowPassAlpha1: 0.45,
  baroLowPassAlpha2: 0.30,
  baroNoiseFloorHPa: 0.03,
  baroTrustLoHPa: 0.06,
  baroTrustHiHPa: 0.18,
  // Release/landing thresholds — grounded in real wrist logs (log1/log2,
  // build-46). The take-off pop reads ≈1.8–2.3 g at the wrist with only a WEAK
  // gyro (~0.3 rad/s), so the adaptive median+Kσ floor and a high gyro gate both
  // SUPPRESS real take-offs (riding chop inflates σ). We keep releaseSigmaK low
  // and lean on a fixed releaseFloorG instead (see detectJumpsV7).
  releaseSigmaK: 1.5,
  releaseFloorG: 1.70,
  releaseGyroMinRad: 0.30,
  landingSpikeG: 1.40,
  landingSpikeGyro: 1.0,
  landingContactG: 1.15,       // water slap can be modest …
  landingContactGyro: 2.0,     // … but the wrist-rotation burst is the tell
  settleTolG: 0.35,
  settleSamplesNeeded: 12,
  minAirTimeSec: 2.0,    // real kite big-airs run 4–6 s spike-to-spike; reject pops
  hardLandingMinAirTimeSec: 2.0,
  settleMinAirTimeSec: 3.80,
  settleMinBaroDropHPa: 0.06,
  // Watchdog. On the wrist a clean single-jump airtime tops out ~6.5 s; beyond
  // that is almost always two chained jumps or a glide, and because the rise-time
  // height grows with airtime² a longer window explodes the height (a 16 s window
  // → 27 m). A real 20 m+ Big Air with very long hangtime must therefore be read
  // from the BAROMETER (a jump that size moves it, and the pressure recovers on
  // landing — see the consistency gate), not from raw airtime.
  maxAirTimeSec: 6.5,
  minJumpHeightM: 1.0,   // report jumps >= 1 m; ignore sub-metre chop
  noiseRejectMaxDistanceM: 30.0,
  noiseRejectMaxRotations: 0,
  noiseRejectMaxDisplayedAirTimeSec: 3.0,
  noiseRejectMaxHeightM: 2.0,
  timeoutRecoveryMinBaroDropHPa: 0.35,
  timeoutRecoveryMinPeakGyro: 4.0,
  timeoutRecoveryMinTakeoffG: 2.0,
  timeoutRecoveryMinHeightMeters: 3.0,
  timeoutRecoveryMinBurstSamples: 14,
  gyroQualityThreshold: 8.0,
  gyroIsDegPerSec: false,
  kinematicCalibration: 1.25,
  enableIMUBiasCorrection: true,
  airtimeCeilingTolerance: 1.25, // baro may read up to 25% over the rise-time height
  // Absolute sanity cap — Big Air world records exceed 45 m, so this is a loose
  // last-resort guard, NOT the drift filter. The real defence against the 13 m
  // baro-drift readings is the rise-time consistency gate below (baroCeiling),
  // which rejects any baro height the time-of-flight cannot support. The cap is
  // kept generous so genuine Big Air jumps are never clipped.
  maxPlausibleHeightM: 50.0,
  // Reference-validated: solving ½·g·(f·airtime)² against a pro-app (Surfr)
  // session, paired by height, gives f = 0.139–0.146 across the three real
  // big-airs (the fourth pairing landed on a short barometric event, not a real
  // jump). f = 0.143 minimises the height error over the set. The kite holds the
  // rider up so the descent is ~86% of the flight — the ascent (take-off → apex)
  // is only ≈14% of the spike-to-spike airtime.
  symmetricAscentFraction: 0.143,
  displayedAirtimeScale: 0.73,
};

export type LandingKind = 'contact' | 'hardImpact' | 'baroRecovery' | 'settle' | 'timeout';
export type HeightSource = 'kinematic' | 'barometric' | 'blended';

/** Rich, diagnostic result for ONE jump (used by the calib workbench). */
export interface JumpResultV7 {
  jumpHeightM: number;        // fused (kinematic ⇄ baro, adaptive)
  baroHeightM: number;        // may be ~0
  kinematicHeightM: number;   // time-of-flight
  airTimeSec: number;
  apexTimeSec: number | null;
  rotations: number;          // full 360° spins (gyro integral)
  jumpDistanceM: number | null;     // GPS speed × airTime
  jumpDistanceGPSM: number | null;  // GPS position haversine
  maxSessionSpeedKnots: number;
  maxSessionSpeedKmh: number;
  confidence: number;         // 0…1
  landingKind: LandingKind;
  heightSource: HeightSource;
  // diagnostics
  deltaPressureHPa: number;
  peakTakeoffG: number;
  peakGyro: number;
  avgGyroQuality: number;
  takeoffIdx: number;         // index into the buffer passed to process
  landingIdx: number;
  /** Absolute timestamps (ms, session-relative) of take-off / landing, when
   *  derivable from the buffer. Populated by detectJumpsV7; may be null for a
   *  bare processJumpBuffer call. */
  takeoffTimeMs?: number | null;
  landingTimeMs?: number | null;
}

// ════════════════════════════════════════════════════════════════════════════
// DSP primitives (match Swift DSP)
// ════════════════════════════════════════════════════════════════════════════
function median(a: number[]): number {
  if (!a.length) return 0;
  const s = [...a].sort((x, y) => x - y);
  const m = s.length >> 1;
  return s.length % 2 ? s[m]! : (s[m - 1]! + s[m]!) / 2;
}
function mean(a: number[]): number {
  return a.length ? a.reduce((x, v) => x + v, 0) / a.length : 0;
}
function std(a: number[]): number {
  if (a.length < 2) return 0;
  const m = mean(a);
  return Math.sqrt(a.reduce((x, v) => x + (v - m) * (v - m), 0) / a.length);
}
function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}
function medianFilter(data: number[], hw: number, causal = false): number[] {
  if (!data.length) return [];
  const w = Math.max(1, hw);
  return data.map((_, i) => {
    const lo = causal ? Math.max(0, i - 2 * w) : Math.max(0, i - w);
    const hi = causal ? i : Math.min(data.length - 1, i + w);
    const slice = data.slice(lo, hi + 1).sort((x, y) => x - y);
    const m = slice.length >> 1;
    return slice.length % 2 ? slice[m]! : (slice[m - 1]! + slice[m]!) / 2;
  });
}
function lowPass(data: number[], alpha: number): number[] {
  if (!data.length) return [];
  const a = clamp(alpha, 0.001, 1);
  const out = [data[0]!];
  for (let i = 1; i < data.length; i++) out.push(a * data[i]! + (1 - a) * out[i - 1]!);
  return out;
}
function normalize3(x: number, y: number, z: number): [number, number, number] {
  const m = Math.sqrt(x * x + y * y + z * z);
  return m > 0.001 ? [x / m, y / m, z / m] : [0, 0, -1];
}
function dot3(ax: number, ay: number, az: number, bx: number, by: number, bz: number): number {
  return ax * bx + ay * by + az * bz;
}
function haversineM(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const r = 6_371_000;
  const p1 = lat1 * DEG2RAD, p2 = lat2 * DEG2RAD;
  const dp = (lat2 - lat1) * DEG2RAD, dl = (lon2 - lon1) * DEG2RAD;
  const a = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
  return r * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// ── sample accessors (watch-native units; t in ms) ──────────────────────────
function accMagG(s: SensorSample): number {
  if (s.aM != null) return s.aM;
  return Math.sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az);
}
function gyroMag(s: SensorSample): number {
  if (s.gM != null) return s.gM;
  return Math.sqrt((s.gx ?? 0) ** 2 + (s.gy ?? 0) ** 2 + (s.gz ?? 0) ** 2);
}

// ════════════════════════════════════════════════════════════════════════════
// Single-jump processor — mirrors KitesurfJumpEngineV7.process()
//   `samples` = a captured jump buffer (pre-tail … post-landing tail).
//   `t0Hint`  = optional take-off index (the streaming trigger knows it).
// ════════════════════════════════════════════════════════════════════════════
export function processJumpBuffer(
  samplesIn: SensorSample[],
  maxSessionSpeedMS: number,
  params: JumpEngineV7Params = DEFAULT_V7_PARAMS,
  t0Hint?: number,
  landingHint?: number,
  landingKindHint?: LandingKind,
): JumpResultV7 | null {
  // Drop non-advancing timestamps. Real watch logs occasionally emit duplicate
  // rows (and a streaming feed can stutter); a zero/negative dt corrupts the
  // air-time integration. Remap an incoming hint to the deduped indices.
  const { samples, indexMap } = dedupeByTime(samplesIn);
  const t0HintMapped = t0Hint != null ? (indexMap[t0Hint] ?? undefined) : undefined;
  const landingHintMapped = landingHint != null ? (indexMap[landingHint] ?? undefined) : undefined;
  const n = samples.length;
  if (n < 12) return null;
  const dtMs = estimateDtMs(samples);
  const dt = dtMs / 1000; // seconds

  const haveBaro = samples.some((s) => s.baro != null);

  // ── BARO PIPELINE (median → LP1 → LP2). May be flat/absent. ──
  let baroSmooth: number[];
  if (haveBaro) {
    const filled = fillForward(samples.map((s) => (s.baro != null ? s.baro : NaN)));
    const m = medianFilter(filled, params.baroMedianHalfWindow);
    const p1 = lowPass(m, params.baroLowPassAlpha1);
    baroSmooth = lowPass(p1, params.baroLowPassAlpha2);
  } else {
    baroSmooth = new Array(n).fill(0);
  }

  const accMag = samples.map(accMagG);
  const gyroScale = resolveGyroScale(samples, params);
  const gyroOmega = samples.map((s) => gyroMag(s) * gyroScale);

  // ── RIDE BASELINE (pre-takeoff tail = first 25%) ──
  const baseWindow = Math.max(4, Math.floor(n / 4));
  const rideMeanA = median(accMag.slice(0, baseWindow));
  const rideStdA = std(accMag.slice(0, baseWindow));
  const baselineP = haveBaro ? median(baroSmooth.slice(0, baseWindow)) : 0;

  // ── TAKEOFF: adaptive release spike + airborne confirmation ──
  const releaseThr = Math.max(params.releaseFloorG, rideMeanA + params.releaseSigmaK * Math.max(rideStdA, 0.05));
  let t0 = -1;
  if (t0HintMapped != null && t0HintMapped > 1 && t0HintMapped < n - 4) {
    t0 = t0HintMapped;
  } else {
    for (let i = 2; i < n - 4; i++) {
      if (accMag[i]! < releaseThr) continue;
      const gyroAhead = Math.max(...gyroOmega.slice(i, Math.min(n, i + 7)));
      if (gyroAhead >= params.releaseGyroMinRad ||
          (haveBaro && willBaroDrop(baroSmooth, i, baselineP, params, dt))) {
        t0 = i; break;
      }
    }
  }
  if (t0 === -1) return null;

  // ── LANDING: impact (spike + gyro burst) | baro recovery | watchdog ──
  const minAS = Math.floor(params.minAirTimeSec / dt);
  const hardMinAS = Math.max(minAS, Math.floor(params.hardLandingMinAirTimeSec / dt));
  const settleMinAS = Math.max(minAS, Math.floor(params.settleMinAirTimeSec / dt));
  const maxAS = Math.floor(params.maxAirTimeSec / dt);
  let tl = -1;
  let landingKind: LandingKind = 'timeout';
  let jumpMinP = haveBaro ? baselineP : 0;

  if (landingHintMapped != null &&
      landingHintMapped > t0 &&
      landingHintMapped < n &&
      landingHintMapped - t0 >= minAS &&
      landingHintMapped - t0 <= maxAS) {
    tl = landingHintMapped;
    landingKind = landingKindHint ?? 'contact';
    if (haveBaro) {
      for (let k = t0 + 1; k <= tl; k++) jumpMinP = Math.min(jumpMinP, baroSmooth[k]!);
    }
  } else {
    let softLandingIndex = -1;
    let softLandingKind: LandingKind = 'timeout';
    let settleRun = 0;

    for (let i = t0 + 1; i < n && i - t0 <= maxAS; i++) {
      if (haveBaro) jumpMinP = Math.min(jumpMinP, baroSmooth[i]!);
      const air = (i - t0) * dt;
      if (air < params.minAirTimeSec) continue;

      // Strong landings close immediately. Soft baro/settle landings stay
      // pending so a later first-contact slap can still win.
      if (accMag[i]! >= params.landingContactG && gyroOmega[i]! >= params.landingContactGyro) {
        tl = i; landingKind = 'contact'; break;
      }
      if (i - t0 >= hardMinAS &&
          accMag[i]! >= params.landingSpikeG &&
          gyroOmega[i]! >= params.landingSpikeGyro) {
        tl = i; landingKind = 'hardImpact'; break;
      }
      if (i - t0 >= hardMinAS && haveBaro) {
        const drop = baselineP - jumpMinP;
        if (drop > params.baroNoiseFloorHPa) {
          const recover = Math.max(drop * 0.08, params.baroNoiseFloorHPa);
          if (baroSmooth[i]! >= baselineP - recover && softLandingIndex === -1) {
            softLandingIndex = i;
            softLandingKind = 'baroRecovery';
          }
        }
      }

      const settleBaroOK = haveBaro && (baselineP - jumpMinP) >= params.settleMinBaroDropHPa;
      if (settleBaroOK &&
          i - t0 >= settleMinAS &&
          Math.abs(accMag[i]! - rideMeanA) < params.settleTolG &&
          gyroOmega[i]! < params.gyroQualityThreshold) {
        settleRun += 1;
        if (settleRun >= params.settleSamplesNeeded && i - t0 > minAS && softLandingIndex === -1) {
          softLandingIndex = i;
          softLandingKind = 'settle';
        }
      } else {
        settleRun = 0;
      }
    }

    if (tl === -1 && softLandingIndex !== -1) {
      tl = softLandingIndex;
      landingKind = softLandingKind;
    }
  }
  if (tl === -1) { tl = Math.min(n - 1, t0 + maxAS); landingKind = 'timeout'; }
  if (tl <= t0) return null;

  const airTimeSec = (tl - t0) * dt;

  // GPS great-circle displacement during the jump (null when the log carries no
  // position, which is the common watch case — only `spd` is present).
  const jumpDistGPS = distanceGPS(samples, t0, tl);

  // ── BIG-AIR BARO EXTENSION ─────────────────────────────────────────
  // A 20 m+ Big Air has ~15 s of hangtime, far beyond the kinematic watchdog
  // (6.5 s), so the landing loop times out mid-flight before the pressure apex.
  // The kinematic height MUST stay capped (rise-time on a long airtime explodes),
  // but the BAROMETER sees the whole arc. So on a timeout WITH a significant,
  // still-developing dip, scan further (baro only) for the true pressure minimum
  // and its recovery — without extending the kinematic airTimeSec. This is how
  // the high range is measured: a real Big Air moves the baro by 1.8–3.6 hPa.
  let baroApexIdx = tl;
  let baroLandIdx = tl;
  if (haveBaro && landingKind === 'timeout') {
    const baroHorizon = Math.min(n - 1, t0 + Math.floor(30 / dt)); // up to 30 s
    let mp = Infinity;
    for (let i = t0; i <= baroHorizon; i++) {
      jumpMinP = Math.min(jumpMinP, baroSmooth[i]!);
      if (baroSmooth[i]! < mp) { mp = baroSmooth[i]!; baroApexIdx = i; }
    }
    // landing = pressure climbs back near baseline after the apex
    const dipE = baselineP - mp;
    if (dipE > params.baroNoiseFloorHPa) {
      const recover = Math.max(dipE * 0.5, params.baroNoiseFloorHPa);
      for (let i = baroApexIdx; i <= baroHorizon; i++) {
        if (baroSmooth[i]! >= baselineP - recover) { baroLandIdx = i; break; }
      }
    }
  }

  // ── BAROMETRIC HEIGHT (raw drop; may be drift/spike noise) ──
  const dP = haveBaro ? Math.max(0, baselineP - jumpMinP) : 0;
  const baroH = dP > params.baroNoiseFloorHPa ? dP * P2M : 0;

  // ── KINEMATIC HEIGHTS (two flavours, KITE-AWARE) ───────────────────
  // (1) Symmetric ceiling: the MOST height a free-fall arc of this airtime
  //     could reach (apex at the midpoint). Real kite jumps sit BELOW this
  //     because the kite extends the descent — so it is a physical UPPER BOUND.
  const symCeilingH = G * airTimeSec * airTimeSec / 8;
  // (2) Rise-time height: h = ½·g·t_rise² using the apex from the baro minimum
  //     (preferred — pressure low-point is the true top). Falls back to the
  //     symmetric ascent fraction when no usable baro apex exists.
  let tRise = airTimeSec * params.symmetricAscentFraction;
  let apexFromBaro = false;
  if (haveBaro && dP > params.baroNoiseFloorHPa) {
    // index of minimum smoothed pressure within [t0, tl]
    let minIdx = t0, mp = Infinity;
    for (let i = t0; i <= tl; i++) { if (baroSmooth[i]! < mp) { mp = baroSmooth[i]!; minIdx = i; } }
    const tr = (minIdx - t0) * dt;
    // In kite, the kite continues to lift AFTER the apex, pulling the baro
    // minimum late (>50% of airtime). Clamp to the symmetric ascent boundary
    // so we never "find" an apex that is physically in the descent.
    const trClamped = Math.min(tr, airTimeSec * params.symmetricAscentFraction);
    if (tr > 0.1 && tr < airTimeSec - 0.05) { tRise = trClamped; apexFromBaro = true; }
  }
  const riseH = params.kinematicCalibration * 0.5 * G * tRise * tRise;

  // ── PHYSICAL CONSISTENCY GATE (drift-rejecting, Big-Air-safe) ──────
  // A barometric height is only believable if BOTH hold:
  //   (1) AIRTIME SUPPORTS IT. A real jump of height h needs a total flight of
  //       at least the symmetric free-fall time 2·√(2h/g) (a kite jump needs
  //       even longer). So baroH may not exceed the symmetric ceiling g·t²/8.
  //       This admits genuine Big Air (45 m needs ~6 s, which real jumps have)
  //       while rejecting a big dP on a short airtime.
  //   (2) PRESSURE RECOVERS. A jump dips the pressure then RETURNS to baseline
  //       on landing; a slow drift ramps and never comes back. We require the
  //       post-apex pressure to climb back near the take-off baseline within the
  //       captured window — this is what rejects the 13 m drift that (1) alone
  //       let through (its airtime was long enough, but its pressure never
  //       recovered because the dip was drift, not a jump).
  // The baro height is bounded by the free-fall ceiling of the FLIGHT TIME the
  // baro actually saw (t0 → baro landing), not the watchdog-capped kinematic
  // airtime — otherwise a real Big Air whose airtime was cut would be clipped.
  const baroFlightSec = (baroLandIdx - t0) * dt;
  const symCeiling = (G * baroFlightSec * baroFlightSec / 8) * params.airtimeCeilingTolerance;
  // A real jump's pressure traces a VALLEY: it falls to a minimum (apex) then
  // climbs back. Drift RAMPS monotonically and never turns around. We accept the
  // baro when the valley turns within the captured/extended window — the minimum
  // is not at the very end and the pressure has begun climbing back from it.
  // This rejects a monotone drift (whose minimum sits at the window's end).
  let baroRecovers = true;
  if (haveBaro && dP > params.baroNoiseFloorHPa) {
    const endP = baroSmooth[baroLandIdx]!;
    const recovered = endP - jumpMinP;                 // climb-back from the dip
    const valleyTurned = baroApexIdx < baroLandIdx - Math.round(0.2 / dt);
    baroRecovers = recovered >= 0.5 * dP || (valleyTurned && recovered >= 0.15 * dP);
  }
  const baroConsistent = baroH > 0 && baroH <= symCeiling && baroRecovers;

  // ── HEIGHT SELECTION ───────────────────────────────────────────────
  let heightM: number;
  let source: HeightSource;
  if (baroConsistent) {
    // Trust baro proportionally to its SNR, but never above the airtime ceiling.
    const baroTrust = clamp((dP - params.baroTrustLoHPa) / (params.baroTrustHiHPa - params.baroTrustLoHPa), 0, 1);
    const baroClamped = Math.min(baroH, symCeiling);
    heightM = baroTrust * baroClamped + (1 - baroTrust) * riseH;
    source = baroTrust >= 0.85 ? 'barometric' : baroTrust <= 0.15 ? 'kinematic' : 'blended';
  } else {
    // Baro contradicts the time-of-flight (drift/spike) or is absent → rise-time
    // kinematic only. This is what stops the 13 m baro-drift readings.
    heightM = riseH;
    source = 'kinematic';
  }
  // Absolute kitesurf sanity cap — a wrist jump above this is non-physical.
  const fusedH = Math.min(heightM, params.maxPlausibleHeightM);
  void apexFromBaro; // (kept for diagnostics / future tuning)

  if (fusedH < params.minJumpHeightM) return null;

  // ── HORIZONTAL JUMP DISTANCE ───────────────────────────────────────
  // GPS displacement when the log has position; otherwise project from the
  // take-off speed. The kite glide does NOT add proportional horizontal travel
  // (the rider is pulled UP, decelerating horizontally), so distance is
  // projected over the BALLISTIC flight time implied by the measured height
  // (t_flight = 2·√(2h/g) — rise + symmetric fall), capped by the real airtime.
  // Using the full spike-to-spike airtime here over-reads distance ~2–3×.
  const ballisticFlightSec = Math.min(airTimeSec, 2 * Math.sqrt(2 * fusedH / G));
  const jumpDistSpeedTime = jumpDistGPS ?? distanceSpeedTime(samples, t0, ballisticFlightSec);

  // ── APEX (integrate gravity-projected vertical accel) ──
  const apex = integrateApex(samples, t0, tl, dt, params);

  // ── ROTATIONS (gyro integral) ──
  let totalRad = 0;
  for (let k = t0 + 1; k <= tl; k++) totalRad += gyroOmega[k]! * dt;
  const rotations = Math.floor(totalRad / TWO_PI);
  const displayedAirTimeSec = airTimeSec * params.displayedAirtimeScale;
  if (
    jumpDistSpeedTime != null &&
    jumpDistSpeedTime < params.noiseRejectMaxDistanceM &&
    rotations <= params.noiseRejectMaxRotations &&
    displayedAirTimeSec < params.noiseRejectMaxDisplayedAirTimeSec &&
    fusedH < params.noiseRejectMaxHeightM
  ) {
    return null;
  }

  // ── GYRO QUALITY / peaks ──
  const gyroQ = gyroOmega.map((w) => Math.max(0, 1 - w / (params.gyroQualityThreshold * 2.5)));
  const avgGyroQ = mean(gyroQ.slice(t0, tl + 1));
  const peakGyro = Math.max(...gyroOmega.slice(t0, tl + 1));
  const peakTakeoffG = Math.max(...accMag.slice(Math.max(0, t0 - 2), Math.min(n, t0 + 5)));
  let timeoutBurstRun = 0;
  let timeoutMaxBurstRun = 0;
  for (let k = t0; k <= tl; k++) {
    if (accMag[k]! >= releaseThr && gyroOmega[k]! >= params.releaseGyroMinRad) {
      timeoutBurstRun += 1;
      timeoutMaxBurstRun = Math.max(timeoutMaxBurstRun, timeoutBurstRun);
    } else {
      timeoutBurstRun = 0;
    }
  }

  if (landingKind === 'timeout') {
    const baroTimeoutRecovered =
      dP >= params.timeoutRecoveryMinBaroDropHPa &&
      fusedH >= params.timeoutRecoveryMinHeightMeters &&
      peakGyro >= params.timeoutRecoveryMinPeakGyro &&
      peakTakeoffG >= params.timeoutRecoveryMinTakeoffG;
    const inertialTimeoutRecovered =
      dP < params.baroNoiseFloorHPa &&
      fusedH >= params.timeoutRecoveryMinHeightMeters &&
      peakGyro >= params.timeoutRecoveryMinPeakGyro &&
      peakTakeoffG >= params.timeoutRecoveryMinTakeoffG &&
      timeoutMaxBurstRun >= params.timeoutRecoveryMinBurstSamples;
    if (!baroTimeoutRecovered && !inertialTimeoutRecovered) return null;
  }

  // ── CONFIDENCE (physics-linked) ──
  let conf = 0.55;
  // baro & rise-time kinematic agree → strong evidence of a real, sized jump.
  if (baroConsistent && Math.abs(baroH - riseH) / Math.max(baroH, riseH, 0.1) < 0.4) conf += 0.20;
  if (peakTakeoffG >= releaseThr * 1.3) conf += 0.15;
  else if (peakTakeoffG >= releaseThr) conf += 0.08;
  conf += 0.10;
  if (airTimeSec >= 1.0) conf += 0.05;
  if (landingKind === 'timeout') conf -= 0.20;
  if (peakGyro > params.gyroQualityThreshold * 2.5) conf -= 0.15;
  // baro present but PHYSICALLY INCONSISTENT with airtime → likely drift/spike.
  if (haveBaro && baroH > 0 && !baroConsistent) conf -= 0.15;
  conf -= (1 - avgGyroQ) * 0.10;
  conf = clamp(conf, 0, 1);

  const r2 = (v: number) => Math.round(v * 100) / 100;
  const r1 = (v: number) => Math.round(v * 10) / 10;

  return {
    jumpHeightM: r2(clamp(fusedH, 0, params.maxPlausibleHeightM)),
    baroHeightM: r2(baroH),
    kinematicHeightM: r2(riseH),
    airTimeSec: r2(airTimeSec),
    apexTimeSec: apex != null ? r2(apex) : null,
    rotations,
    jumpDistanceM: jumpDistSpeedTime,
    jumpDistanceGPSM: jumpDistGPS,
    maxSessionSpeedKnots: r1(maxSessionSpeedMS * 1.94384),
    maxSessionSpeedKmh: r1(maxSessionSpeedMS * 3.6),
    confidence: Math.round(conf * 1000) / 1000,
    landingKind,
    heightSource: source,
    deltaPressureHPa: Math.round(dP * 10000) / 10000,
    peakTakeoffG: r2(peakTakeoffG),
    peakGyro: r2(peakGyro),
    avgGyroQuality: Math.round(avgGyroQ * 1000) / 1000,
    takeoffIdx: t0,
    landingIdx: tl,
    takeoffTimeMs: samples[t0]?.t ?? null,
    landingTimeMs: samples[tl]?.t ?? null,
  };
}

// ════════════════════════════════════════════════════════════════════════════
// Whole-session sweep — streaming trigger that hands each captured jump buffer
// to processJumpBuffer(). This is what the CalibWorkbench runs on a full log.
// Mirrors the KitesurfSession state machine (RIDING → AIRBORNE → analyse).
// ════════════════════════════════════════════════════════════════════════════
export function detectJumpsV7(
  samplesIn: SensorSample[],
  params: JumpEngineV7Params = DEFAULT_V7_PARAMS,
): JumpResultV7[] {
  const out: JumpResultV7[] = [];
  const { samples } = dedupeByTime(samplesIn);
  if (samples.length < 12) return out;

  const dtMs = estimateDtMs(samples);
  const dt = dtMs / 1000;
  const hz = 1 / dt;
  const preTailN = Math.max(1, Math.round(2.0 * hz));
  const postTailN = Math.max(1, Math.round(1.0 * hz));
  const rideWinN = Math.max(10, Math.round(1.5 * hz));
  const refractoryMs = 1000;

  // robust session max speed (median of top-3)
  const top3: number[] = [];
  for (const s of samples) {
    if (s.spd != null && isFinite(s.spd) && s.spd > 0) {
      top3.push(s.spd); top3.sort((a, b) => b - a); if (top3.length > 3) top3.pop();
    }
  }
  const maxSpeed = top3.length ? top3.reduce((a, v) => a + v, 0) / top3.length : 0;

  const rideWin: number[] = [];
  let state: 'riding' | 'airborne' = 'riding';
  let takeoffIdx = -1;
  let refractoryUntil = -Infinity;
  let baselineAtTakeoff = 0;
  let jumpMinPressure = Infinity;
  let softLandingIdx = -1;
  let softLandingKind: LandingKind = 'timeout';
  let settleRun = 0;

  for (let i = 0; i < samples.length; i++) {
    const s = samples[i]!;
    const a = accMagG(s);
    const w = gyroMag(s) * (params.gyroIsDegPerSec === true ? DEG2RAD : 1);

    if (state === 'riding') {
      rideWin.push(a); if (rideWin.length > rideWinN) rideWin.shift();
      if (s.t < refractoryUntil) continue;
      if (rideWin.length <= 10) continue;
      // Fixed-floor-dominated release threshold. On wrist logs the median+Kσ
      // term balloons during chop and hides real take-offs, so releaseSigmaK is
      // small and releaseFloorG carries the gate. The take-off pop has a real
      // accel spike but only a WEAK gyro — gate on a low gyro floor,
      // not the airborne-quality threshold.
      const thr = Math.max(params.releaseFloorG, median(rideWin) + params.releaseSigmaK * Math.max(std(rideWin), 0.05));
      if (a >= thr && w >= params.releaseGyroMinRad) {
        state = 'airborne';
        takeoffIdx = i;
        baselineAtTakeoff = s.baro ?? 0;
        jumpMinPressure = s.baro ?? Infinity;
        softLandingIdx = -1;
        softLandingKind = 'timeout';
        settleRun = 0;
      }
    } else {
      const air = (s.t - samples[takeoffIdx]!.t) / 1000;
      if (s.baro != null) jumpMinPressure = Math.min(jumpMinPressure, s.baro);
      // Landing = FIRST water contact: a board slap (modest accel) WITH a wrist-
      // rotation burst, after the minimum airtime. Stopping at the FIRST contact
      // (not the last spike) keeps two consecutive jumps from merging into one
      // over-long window. Soft baro/settle paths are pending fallbacks.
      let landed = false;
      let landingKind: LandingKind = 'timeout';
      let landingIdx = i;
      if (air >= params.minAirTimeSec) {
        if (a >= params.landingContactG && w >= params.landingContactGyro) {
          landed = true;
          landingKind = 'contact';
        } else if (air >= params.hardLandingMinAirTimeSec &&
                   a >= params.landingSpikeG &&
                   w >= params.landingSpikeGyro) {
          landed = true;
          landingKind = 'hardImpact';
        } else if (air >= params.hardLandingMinAirTimeSec &&
                   baselineAtTakeoff > 0 &&
                   Number.isFinite(jumpMinPressure)) {
          const drop = baselineAtTakeoff - jumpMinPressure;
          if (drop > params.baroNoiseFloorHPa) {
            const recover = Math.max(drop * 0.08, params.baroNoiseFloorHPa);
            if ((s.baro ?? -Infinity) >= baselineAtTakeoff - recover && softLandingIdx === -1) {
              softLandingIdx = i;
              softLandingKind = 'baroRecovery';
            }
          }
        }

        const settleBaroOK = baselineAtTakeoff > 0 &&
          Number.isFinite(jumpMinPressure) &&
          baselineAtTakeoff - jumpMinPressure >= params.settleMinBaroDropHPa;
        if (!landed &&
            air >= params.settleMinAirTimeSec &&
            settleBaroOK &&
            Math.abs(a - median(rideWin)) < params.settleTolG &&
            w < params.gyroQualityThreshold) {
          settleRun += 1;
          if (settleRun >= params.settleSamplesNeeded && softLandingIdx === -1) {
            softLandingIdx = i;
            softLandingKind = 'settle';
          }
        } else if (!landed) {
          settleRun = 0;
        }
      }
      if (!landed && air > params.maxAirTimeSec && softLandingIdx !== -1) {
        landed = true;
        landingKind = softLandingKind;
        landingIdx = softLandingIdx;
      }

      if (landed || air > params.maxAirTimeSec) {
        // capture buffer: preTail before takeoff … postTail after landing/current timeout
        const lo = Math.max(0, takeoffIdx - preTailN);
        const hi = Math.min(samples.length - 1, Math.max(i, landingIdx) + postTailN);
        const buf = samples.slice(lo, hi + 1);
        const hint = takeoffIdx - lo;
        const landingHint = landed ? landingIdx - lo : undefined;
        const r = processJumpBuffer(buf, maxSpeed, params, hint, landingHint, landingKind);
        if (r && r.confidence >= 0.40) out.push(r);
        state = 'riding';
        refractoryUntil = landed ? s.t + refractoryMs : s.t;
        rideWin.length = 0;
        takeoffIdx = -1;
        baselineAtTakeoff = 0;
        jumpMinPressure = Infinity;
        softLandingIdx = -1;
        softLandingKind = 'timeout';
        settleRun = 0;
      }
    }
  }
  return out;
}

/**
 * Detect which engine a Swift source / profile represents, so the dashboard can
 * route analysis to the matching TS engine instead of always using the legacy
 * default. Looks for explicit version markers in the Swift source text.
 *   → 'v8'  : v7 + ballistic-freefall gate (KitesurfJumpEngineV8.swift)
 *   → 'v7'  : the sensor-grounded adaptive-hybrid engine (KitesurfJumpEngine.swift)
 *   → 'v4'  : the legacy barometer-primary state machine (jumpDetect.swift)
 * v8 is checked first because a v8 source also contains "v7" lineage text.
 */
export type EngineVersion = 'v8' | 'v7' | 'v4';

export function detectEngineVersion(swiftSource: string | null | undefined): EngineVersion {
  if (!swiftSource) return 'v4';
  const s = swiftSource;
  if (/KitesurfJumpEngineV8|ALGORITHM v8|JumpEngineV8|v8 \(ballistic-gated\)/i.test(s)) return 'v8';
  if (/KitesurfJumpEngineV7|ALGORITHM v7|JumpEngineV7|v7 \(sensor-grounded\)/i.test(s)) return 'v7';
  return 'v4';
}

/**
 * Convert a v7 result to the compact app JumpEvent format (cm, tenths, km/h, dm).
 * `airtimeScale` trims the displayed airtime to match the reference app (Surfr),
 * which reports a shorter flight than the physical spike-to-spike window; the
 * height is unaffected (it is computed from the physical airtime upstream).
 */
export function toJumpEvent(
  r: JumpResultV7,
  takeoffSample: SensorSample,
  airtimeScale: number = DEFAULT_V7_PARAMS.displayedAirtimeScale,
): JumpEvent {
  return {
    t: Math.round(takeoffSample.t / 1000),
    h: Math.round(r.jumpHeightM * 100),
    a: Math.round(r.airTimeSec * airtimeScale * 10),
    s: Math.round(r.maxSessionSpeedKmh),
    d: r.jumpDistanceM != null ? Math.round(r.jumpDistanceM * 10) : 0,
    y: takeoffSample.lat != null ? Math.round(takeoffSample.lat * 1e4) : 0,
    x: takeoffSample.lng != null ? Math.round(takeoffSample.lng * 1e4) : 0,
  };
}

// ════════════════════════════════════════════════════════════════════════════
// Internals
// ════════════════════════════════════════════════════════════════════════════
function integrateApex(
  s: SensorSample[], t0: number, tl: number, dt: number, params: JumpEngineV7Params,
): number | null {
  const vert = s.map((smp) => {
    const [gx, gy, gz] = normalize3(smp.gvX ?? 0, smp.gvY ?? 0, smp.gvZ ?? -1);
    return -dot3(smp.ax, smp.ay, smp.az, gx, gy, gz); // g, along up axis
  });
  let bias = 0;
  if (params.enableIMUBiasCorrection && t0 > 3) bias = median(vert.slice(0, t0));
  let v = 0, prevV = 0, elapsed = 0, apex: number | null = null;
  for (let k = t0 + 1; k <= tl; k++) {
    const aMps2 = (vert[k]! - bias) * G;
    prevV = v; v += aMps2 * dt; elapsed += dt;
    if (apex == null && prevV > 0.05 && v <= 0.05) {
      const frac = clamp(prevV / (prevV - v + 1e-9), 0, 1);
      apex = elapsed - dt + frac * dt;
    }
  }
  return apex;
}

function distanceSpeedTime(s: SensorSample[], t0: number, airTimeSec: number): number | null {
  const tT = s[t0]!.t;
  let best: number | null = null, bestDt = Infinity;
  for (const smp of s) {
    if (smp.spd == null || !isFinite(smp.spd)) continue;
    const d = Math.abs(smp.t - tT);
    if (d < bestDt) { bestDt = d; best = smp.spd; }
  }
  if (best == null || bestDt > 3000) return null; // 3s in ms
  return Math.min(150, Math.round(best * airTimeSec * 10) / 10);
}

function distanceGPS(s: SensorSample[], t0: number, tl: number): number | null {
  const pts = s
    .map((x, i) => ({ i, t: x.t, lat: x.lat, lng: x.lng }))
    .filter((p): p is { i: number; t: number; lat: number; lng: number } =>
      p.lat != null && p.lng != null && isFinite(p.lat) && isFinite(p.lng));
  if (pts.length < 2) return null;
  const tT = s[t0]!.t, tL = s[tl]!.t;
  const near = (target: number) => pts.reduce((b, p) => (Math.abs(p.t - target) < Math.abs(b.t - target) ? p : b));
  const nT = near(tT);
  let nL = near(tL);
  if (nT.i === nL.i) {
    const others = pts.filter((p) => p.i !== nT.i);
    if (!others.length) return null;
    nL = others.reduce((b, p) => (Math.abs(p.t - tL) < Math.abs(b.t - tL) ? p : b));
  }
  return Math.round(haversineM(nT.lat, nT.lng, nL.lat, nL.lng) * 10) / 10;
}

function willBaroDrop(baro: number[], i: number, baseline: number, params: JumpEngineV7Params, dt: number): boolean {
  const end = Math.min(baro.length - 1, i + Math.round(2.0 / dt));
  if (end <= i) return false;
  const mn = Math.min(...baro.slice(i, end + 1));
  return baseline - mn > params.baroNoiseFloorHPa;
}

/** Forward-fill NaNs (sparse baro → step-held), then back-fill leading NaNs. */
function fillForward(a: number[]): number[] {
  const out = [...a];
  let last = a.find((v) => !Number.isNaN(v)) ?? 1013.25;
  for (let k = 0; k < out.length; k++) {
    if (Number.isNaN(out[k]!)) out[k] = last;
    else last = out[k]!;
  }
  return out;
}

function resolveGyroScale(s: SensorSample[], params: JumpEngineV7Params): number {
  if (params.gyroIsDegPerSec != null) return params.gyroIsDegPerSec ? DEG2RAD : 1;
  return median(s.map(gyroMag)) > 10 ? DEG2RAD : 1;
}

/**
 * Drop samples whose timestamp does not advance past the previous kept one.
 * Returns the cleaned series plus `indexMap[originalIdx] = newIdx | -1` so a
 * caller-supplied take-off hint can be remapped onto the deduped indices.
 */
function dedupeByTime(s: SensorSample[]): { samples: SensorSample[]; indexMap: number[] } {
  const out: SensorSample[] = [];
  const indexMap = new Array<number>(s.length).fill(-1);
  let lastT = -Infinity;
  for (let i = 0; i < s.length; i++) {
    if (s[i]!.t > lastT) {
      indexMap[i] = out.length;
      out.push(s[i]!);
      lastT = s[i]!.t;
    } else {
      // collapses onto the most recent kept sample
      indexMap[i] = out.length - 1;
    }
  }
  return { samples: out, indexMap };
}

/** Estimate sample period in MILLISECONDS (t is ms in TS). */
function estimateDtMs(s: SensorSample[]): number {
  if (s.length < 6) return 20;
  const diffs: number[] = [];
  for (let i = 1; i < Math.min(40, s.length); i++) {
    const d = s[i]!.t - s[i - 1]!.t;
    if (d > 5 && d < 500) diffs.push(d); // 5ms..500ms
  }
  return diffs.length > 3 ? median(diffs) : 20;
}
