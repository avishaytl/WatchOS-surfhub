/**
 * surfhub-watch — shared data contracts.
 *
 * Two distinct data shapes flow off the watch:
 *
 *   1. RAW sensor stream  (this file: SensorSample, RawSessionLog)
 *      → uploaded as-is to the `calib-log` Edge Function for tuning the
 *        jump-detection algorithm during development. High volume, lossless.
 *
 *   2. PROCESSED session   (JumpEvent, TrackPoint — mirrors surfhub-app)
 *      → the compact, user-facing result written to `public.sessions.j_data`.
 *        These types MUST stay byte-compatible with surfhub-app/src/data/types.ts.
 */

// ─── 1. RAW sensor data (calibration) ────────────────────────────────────────

/**
 * One raw IMU + GPS sample off the watch. Units are SI / device-native so the
 * calibration analysis app sees exactly what the sensors reported — no lossy
 * pre-scaling here (that happens only when we emit JumpEvents).
 */
export interface SensorSample {
  /** ms since session start (monotonic). */
  t: number;
  /**
   * Linear acceleration in g, gravity removed (userAcceleration).
   * Converted from the watch CSV which reports in g natively.
   * The detection algorithm works in g — do NOT pre-multiply by 9.80665 here.
   */
  ax: number;
  ay: number;
  az: number;
  /** Pre-computed |a| magnitude in g (from the watch CSV `aM` column). */
  aM?: number;
  /** Rotation rate rad/s (gyroscope). */
  gx?: number;
  gy?: number;
  gz?: number;
  /** Pre-computed |ω| magnitude rad/s (from `gM` column). */
  gM?: number;
  /** Gravity vector in g (gvX/gvY/gvZ from the watch CSV). */
  gvX?: number;
  gvY?: number;
  gvZ?: number;
  /**
   * Barometric altitude in metres above sea level, derived from `baro` (hPa)
   * via the international barometric formula. Optional — absent when baro is
   * missing or has not yet been baseline-corrected.
   */
  alt?: number;
  /** Raw barometric pressure hPa (as reported by the watch). */
  baro?: number;
  /** Rolling baseline pressure hPa (watch-computed). */
  baseBaro?: number;
  /** GPS, optional (sampled far less often than IMU). */
  lat?: number;
  lng?: number;
  /** GPS horizontal speed m/s, optional. */
  spd?: number;
  /** GPS altitude (m, MSL) + its vertical accuracy (m), optional. DRIFT-FREE vertical
   *  reference — fused with the baro to cancel slow barometric drift (see gpsFusion). */
  gpsAlt?: number;
  gpsAltAcc?: number;
  /** GPS vertical velocity (m/s, up+; from Doppler or Δaltitude), optional. A real jump
   *  shows |vVel| ≫ noise; a pure baro-drift phantom shows ≈0 → used to reject phantoms. */
  gpsVertVel?: number;
  /** Consecutive low-g sample count (from watch `lowG` column). */
  lowG?: number;
  /** Watch state machine state (RIDING / AIRBORNE / COOLDOWN / IDLE …). */
  state?: string;
  /** Watch event string (TAKEOFF_SPIKE / JUMP_ACCEPTED / …). */
  evt?: string;
}

/** Platform/firmware metadata stored alongside a raw log, for calibration context. */
export interface DeviceMeta {
  platform: 'watchos' | 'wearos';
  /** Stable per-device id (NOT a user id) — folders calib logs per watch. */
  deviceId: string;
  /** Hardware model string, e.g. "Watch7,1" / "GW5". */
  model?: string;
  osVersion?: string;
  /** surfhub-watch build that produced the log. */
  appVersion: string;
  /** Nominal IMU sample rate Hz the firmware was configured to. */
  sampleRateHz?: number;
}

/**
 * The full RAW log uploaded to `calib-log`. This is the JSON the watch POSTs.
 * Deliberately verbose & self-describing — it is the source of truth the
 * algorithm is tuned against, not a space-optimised wire format.
 */
export interface RawSessionLog {
  schema: 'surfhub.calib.v1';
  device: DeviceMeta;
  /** ISO start time of the session. */
  startedAt: string;
  /** ISO end time. */
  endedAt: string;
  spot?: { name?: string; lat?: number; lng?: number };
  /** Every sensor sample captured during the session. */
  samples: SensorSample[];
  /**
   * The jumps the *current* on-device algorithm THINKS it detected, so the
   * analysis app can diff algorithm output against the raw signal and against
   * hand-labelled ground truth. May be empty while the detector is immature.
   */
  detected: JumpEvent[];
  /** Free-form notes / ground-truth labels added in the field. */
  notes?: string;
}

// ─── 2. PROCESSED session (mirrors surfhub-app — keep in sync!) ───────────────

/**
 * JumpEvent — one per jump, sent in the end-of-session JSON to `sessions.j_data`.
 *   t = seconds offset from session start
 *   h = height cm        (152 = 1.52m)
 *   a = air time tenths-of-second (48 = 4.8s)
 *   s = top speed km/h
 *   d = horizontal distance dm (21 = 2.1m)
 *   y = lat * 1e4        x = lng * 1e4
 * MUST match surfhub-app/src/data/types.ts.
 */
export interface JumpEvent {
  t: number;
  h: number;
  a: number;
  s: number;
  d: number;
  y: number;
  x: number;
}

/** TrackPoint — GPS route, [lat * 1e4, lng * 1e4]. Matches surfhub-app. */
export type TrackPoint = [number, number];
