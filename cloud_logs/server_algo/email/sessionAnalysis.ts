/**
 * sessionAnalysis — derive the full set of session metrics from a raw sensor
 * stream. This is the single source of truth used by BOTH the watch (to produce
 * the end-of-session result) and surfhub-admin's WATCH CALIB panel (to re-run
 * detection on uploaded logs while tuning the algorithm).
 *
 * Produces everything the product cares about for a kitesurf session:
 *   - jumps          (via jumpDetect)
 *   - air time        max + per-jump (from jumpDetect)
 *   - riding speed    top + average (GPS)
 *   - riding distance total (GPS great-circle integration)
 *   - riding track    sampled GPS polyline (compact TrackPoint[])
 *   - duration        session length
 */

import type { SensorSample, JumpEvent, TrackPoint } from './types.ts';
import {
  detectJumps,
  summarise,
  DEFAULT_PARAMS,
  type JumpDetectParams,
} from './jumpDetect.ts';
import {
  detectJumpsV7,
  toJumpEvent,
  DEFAULT_V7_PARAMS,
  type JumpEngineV7Params,
  type JumpResultV7,
} from './jumpEngineV7.ts';
import {
  detectJumpsV8,
  toJumpEventV8,
  DEFAULT_V8_PARAMS,
  type JumpEngineV8Params,
  type JumpResultV8,
} from './jumpEngineV8.ts';

export interface SessionMetrics {
  /** Session duration in minutes. */
  durationMin: number;
  /** Detected jumps (compact app format). */
  jumps: JumpEvent[];
  jumpCount: number;
  /** Max jump height in metres. */
  maxJumpM: number;
  /** Max air time in seconds. */
  maxAirS: number;
  /** Top riding speed km/h (GPS). */
  topSpeedKmh: number;
  /** Average moving speed km/h (GPS, excludes near-stationary). */
  avgSpeedKmh: number;
  /** Total ridden distance in km (GPS). */
  distanceKm: number;
  /** Compact GPS polyline [lat*1e4, lng*1e4], decimated. */
  track: TrackPoint[];
  /** Number of raw samples analysed. */
  sampleCount: number;
}

/** Speeds below this (m/s ≈ 1.8 km/h) are treated as stationary for avg speed. */
const MOVING_THRESHOLD_MS = 0.5;
/** Min metres between retained track points (decimation). */
const TRACK_MIN_DIST_M = 8;

const EARTH_R = 6_371_000; // m

function haversineM(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(bLat - aLat);
  const dLng = toRad(bLng - aLng);
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(aLat)) * Math.cos(toRad(bLat)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_R * Math.asin(Math.min(1, Math.sqrt(s)));
}

/**
 * Analyse a full raw sample stream into session metrics. `params` lets the
 * calibration UI sweep detection thresholds without changing this code.
 */
export function analyseSession(
  samples: SensorSample[],
  params: JumpDetectParams = DEFAULT_PARAMS,
): SessionMetrics {
  const jumps = detectJumps(samples, params);
  const js = summarise(jumps);

  let distM = 0;
  let topSpeedMs = 0;
  let movingSpeedSum = 0;
  let movingCount = 0;
  const track: TrackPoint[] = [];

  let prevLat: number | undefined;
  let prevLng: number | undefined;
  let lastTrackLat: number | undefined;
  let lastTrackLng: number | undefined;

  for (const s of samples) {
    // Speed (prefer GPS-reported speed; fall back below if absent).
    if (s.spd != null) {
      topSpeedMs = Math.max(topSpeedMs, s.spd);
      if (s.spd >= MOVING_THRESHOLD_MS) {
        movingSpeedSum += s.spd;
        movingCount++;
      }
    }

    if (s.lat == null || s.lng == null) continue;

    // Distance via consecutive GPS fixes.
    if (prevLat != null && prevLng != null) {
      const d = haversineM(prevLat, prevLng, s.lat, s.lng);
      // Guard against GPS jitter spikes (>50 m between ~adjacent fixes).
      if (d < 50) distM += d;
    }
    prevLat = s.lat;
    prevLng = s.lng;

    // Decimated track.
    if (
      lastTrackLat == null ||
      haversineM(lastTrackLat, lastTrackLng!, s.lat, s.lng) >= TRACK_MIN_DIST_M
    ) {
      track.push([Math.round(s.lat * 1e4), Math.round(s.lng * 1e4)]);
      lastTrackLat = s.lat;
      lastTrackLng = s.lng;
    }
  }

  const durationMin = samples.length
    ? (samples[samples.length - 1]!.t - samples[0]!.t) / 1000 / 60
    : 0;

  return {
    durationMin: round(durationMin, 1),
    jumps,
    jumpCount: js.jcnt,
    maxJumpM: round(js.jmaxM, 2),
    maxAirS: round(js.airMaxS, 1),
    topSpeedKmh: round(topSpeedMs * 3.6, 1),
    avgSpeedKmh: movingCount ? round((movingSpeedSum / movingCount) * 3.6, 1) : 0,
    distanceKm: round(distM / 1000, 2),
    track,
    sampleCount: samples.length,
  };
}

function round(n: number, dp: number): number {
  const f = 10 ** dp;
  return Math.round(n * f) / f;
}

/** GPS-derived session figures shared by both engines (speed/distance/track). */
function gpsMetrics(samples: SensorSample[]): {
  distanceKm: number;
  topSpeedKmh: number;
  avgSpeedKmh: number;
  track: TrackPoint[];
} {
  let distM = 0;
  let topSpeedMs = 0;
  let movingSpeedSum = 0;
  let movingCount = 0;
  const track: TrackPoint[] = [];
  let prevLat: number | undefined;
  let prevLng: number | undefined;
  let lastTrackLat: number | undefined;
  let lastTrackLng: number | undefined;

  for (const s of samples) {
    if (s.spd != null) {
      topSpeedMs = Math.max(topSpeedMs, s.spd);
      if (s.spd >= MOVING_THRESHOLD_MS) {
        movingSpeedSum += s.spd;
        movingCount++;
      }
    }
    if (s.lat == null || s.lng == null) continue;
    if (prevLat != null && prevLng != null) {
      const d = haversineM(prevLat, prevLng, s.lat, s.lng);
      if (d < 50) distM += d;
    }
    prevLat = s.lat;
    prevLng = s.lng;
    if (lastTrackLat == null || haversineM(lastTrackLat, lastTrackLng!, s.lat, s.lng) >= TRACK_MIN_DIST_M) {
      track.push([Math.round(s.lat * 1e4), Math.round(s.lng * 1e4)]);
      lastTrackLat = s.lat;
      lastTrackLng = s.lng;
    }
  }
  return {
    distanceKm: round(distM / 1000, 2),
    topSpeedKmh: round(topSpeedMs * 3.6, 1),
    avgSpeedKmh: movingCount ? round((movingSpeedSum / movingCount) * 3.6, 1) : 0,
    track,
  };
}

/**
 * v7 session metrics — runs the sensor-grounded adaptive-hybrid engine
 * (KitesurfJumpEngineV7) instead of the legacy v4 detector. Returns the same
 * SessionMetrics shape so the dashboard renders identically, PLUS the rich
 * per-jump v7 results (height source, rotations, confidence, landing kind).
 *
 * Use this when the selected "Swift algorithm (from Mac)" is v7.
 */
export function analyseSessionV7(
  samples: SensorSample[],
  params: JumpEngineV7Params = DEFAULT_V7_PARAMS,
): SessionMetrics & { v7: JumpResultV7[] } {
  const v7 = detectJumpsV7(samples, params);

  // Map each v7 result to a compact JumpEvent using the take-off sample's
  // GPS/time (the v7 result carries indices into a per-jump buffer, so we
  // approximate t/position from the nearest session sample by air time).
  const jumps: JumpEvent[] = v7.map((r) => {
    // Anchor the jump at the session sample nearest its absolute take-off time,
    // so t (and the nearest GPS fix) are accurate in the dashboard table.
    const tMs = r.takeoffTimeMs ?? null;
    let anchor = samples[0]!;
    if (tMs != null) {
      let best = Infinity;
      for (const s of samples) {
        const d = Math.abs(s.t - tMs);
        if (d < best) { best = d; anchor = s; }
      }
    }
    return toJumpEvent(r, anchor, params.displayedAirtimeScale);
  });

  const js = summarise(jumps);
  const gps = gpsMetrics(samples);
  const durationMin = samples.length
    ? (samples[samples.length - 1]!.t - samples[0]!.t) / 1000 / 60
    : 0;

  return {
    durationMin: round(durationMin, 1),
    jumps,
    jumpCount: js.jcnt,
    maxJumpM: round(js.jmaxM, 2),
    maxAirS: round(js.airMaxS, 1),
    topSpeedKmh: gps.topSpeedKmh,
    avgSpeedKmh: gps.avgSpeedKmh,
    distanceKm: gps.distanceKm,
    track: gps.track,
    sampleCount: samples.length,
    v7,
  };
}

/**
 * v8 session metrics — runs v7 PLUS the ballistic-freefall gate
 * (KitesurfJumpEngineV8). Same SessionMetrics shape as v7, with the rich
 * per-jump results exposed under both `v7` (for the existing dashboard
 * diagnostics column, which is version-agnostic) and `v8`.
 *
 * Use this when the selected "Swift algorithm (from Mac)" is v8.
 */
export function analyseSessionV8(
  samples: SensorSample[],
  params: JumpEngineV8Params = DEFAULT_V8_PARAMS,
): SessionMetrics & { v7: JumpResultV8[]; v8: JumpResultV8[] } {
  const v8 = detectJumpsV8(samples, params);

  const jumps: JumpEvent[] = v8.map((r) => {
    const tMs = r.takeoffTimeMs ?? null;
    let anchor = samples[0]!;
    if (tMs != null) {
      let best = Infinity;
      for (const s of samples) {
        const d = Math.abs(s.t - tMs);
        if (d < best) { best = d; anchor = s; }
      }
    }
    return toJumpEventV8(r, anchor);
  });

  const js = summarise(jumps);
  const gps = gpsMetrics(samples);
  const durationMin = samples.length
    ? (samples[samples.length - 1]!.t - samples[0]!.t) / 1000 / 60
    : 0;

  return {
    durationMin: round(durationMin, 1),
    jumps,
    jumpCount: js.jcnt,
    maxJumpM: round(js.jmaxM, 2),
    maxAirS: round(js.airMaxS, 1),
    topSpeedKmh: gps.topSpeedKmh,
    avgSpeedKmh: gps.avgSpeedKmh,
    distanceKm: gps.distanceKm,
    track: gps.track,
    sampleCount: samples.length,
    v7: v8,  // version-agnostic diagnostics column reads `v7`
    v8,
  };
}
