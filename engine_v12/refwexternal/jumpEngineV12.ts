/**
 * jumpEngineV12 — the INSTANT event-driven pipeline: height + airtime + distance
 * on the wrist ≤2 s after landing (the Surfr experience), Apple Watch Series 8+.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * WHY THIS ARCHITECTURE (both facts measured on LOG2/LOG4 vs Surfr goldens)
 * ════════════════════════════════════════════════════════════════════════════
 * 1. HEIGHT IS ONLY IN THE BAROMETER. A kite rise is canopy-borne — the wrist
 *    feels almost no vertical acceleration, and CoreMotion's attitude filter is
 *    corrupted during sustained maneuvers. Oracle-constrained double integration
 *    of the wrist IMU reads 0.4–2.0 m for real 3.1–3.8 m jumps (_v10imu.ts).
 * 2. TIMING IS ONLY IN THE IMU. The take-off yank and the landing contact are
 *    sharp |a| events; at 800 Hz (CMBatchedSensorManager, Series 8+) they give
 *    the airtime to ~10 ms — exactly the number Surfr shows.
 *
 * So V12 splits the roles cleanly and NEVER waits for future baseline:
 *
 *   accel 800 Hz ──► TAKE-OFF event ─────────── arc ───────────► LANDING event
 *                        │                                            │
 *                        ▼                                            ▼
 *          water-level anchor B =                        airtime = t_LD − t_TO
 *          median(last on-water baro                     (MEASURED, not derived)
 *          samples before the yank)                              │
 *                        │                                        ▼
 *                        └────► height = endpoint-anchored arc fit over the
 *                               baro points inside [t_TO, t_LD] (z=0 at both
 *                               ends — the wrist starts and ends at the water)
 *
 * The anchor spans only ~3–5 s of the past, where even LOG4's pathological
 * drift (≤0.05 hPa/s) contributes ±0.2–0.4 m — no 16 s settle, no future
 * window, no long-horizon machinery. A REFINEMENT pass ~3 s after landing
 * measures the return-to-zero (net drift across the arc) and corrects/flags.
 *
 * Sensor inputs (each stream keeps its own timestamps — never resampled):
 *   addAccel(t, |a|)          800 Hz batched accel (falls back to any rate ≥50)
 *   addBaro(t, relAltM)       ~1 Hz CMAltimeter.relativeAltitude (metres)
 *   addLocation(t, lat, lng, speedMs)   ~1 Hz GPS
 *   addSubmersion(t, bool)    OPTIONAL (Ultra) — never required
 *
 * Series 8 compatibility: CMAltimeter + CMBatchedSensorManager + GPS only.
 * The Swift twin is core/JumpEngineV12.swift — keep line-for-line in sync.
 */

const G = 9.80665;

// ─────────────────────────────────────────────────────────────────────────────
// config
// ─────────────────────────────────────────────────────────────────────────────
export interface V12Config {
  // ── event detection (accel, rotation-invariant |a| in g) ──
  yankG: number;            // take-off impulse floor (measured reals: 2.0–5.9 g)
  crashG: number;           // ≥ this = water impact, not a take-off (reals ≤4.2g at entry... crashes 8+g)
  landImpactG: number;      // landing contact impulse (soft landings need chop-resume instead)
  chopWinSec: number;       // causal chop RMS window
  chopResumeFrac: number;   // landing when chop ≥ this × pre-take-off chop, sustained
  chopResumeHoldSec: number;
  minAirSec: number;        // shorter = a wave hop / hand flick, not a jump
  maxAirSec: number;        // bracket cap (Big Air margin)
  // ── riding gate (GPS) ──
  planingSpeedMs: number;   // must be planing within planingWinSec before take-off
  planingWinSec: number;
  // ── baro / height ──
  anchorSamples: number;    // on-water baro samples in the pre-take-off anchor median
  anchorMaxAgeSec: number;  // anchor samples must be this fresh (drift bound)
  minJumpHeightM: number;   // display floor (Surfr filters < 1.5 m too)
  maxJumpHeightM: number;   // sanity cap
  kiteGlideFactor: number;  // airtime = glide · 2·√(2h/g); inverted when no arc baro exists
  // ── refinement (post-landing drift check) ──
  refineDelaySec: number;   // wait for ~2 on-water baro points after landing
  rtzCorrectM: number;      // |return-to-zero| above this → correct h by −rtz/2, flag drift
  // ── crash cooldown (wet baro port paints fake humps for ~30 s) ──
  crashCooldownSec: number;
}

export const DEFAULT_V12_CONFIG: V12Config = {
  yankG: 2.2,
  crashG: 6.0,
  landImpactG: 2.0,
  chopWinSec: 0.3,
  chopResumeFrac: 0.8,
  chopResumeHoldSec: 0.3,
  minAirSec: 1.2,
  maxAirSec: 8.0,
  planingSpeedMs: 0.56, // 2 km/h — low enough to TEST by running + throwing (a kite
                         // session is far above this; raise toward ~3.5 for kite-only
                         // production if standing false-positives ever appear).
  planingWinSec: 5.0,
  anchorSamples: 4,
  anchorMaxAgeSec: 8.0,
  minJumpHeightM: 1.5,
  maxJumpHeightM: 12.0,
  kiteGlideFactor: 2.63,
  refineDelaySec: 3.0,
  rtzCorrectM: 0.25,
  crashCooldownSec: 30,
};

// ─────────────────────────────────────────────────────────────────────────────
// output
// ─────────────────────────────────────────────────────────────────────────────
export interface V12Jump {
  heightM: number;          // apex above the water anchor (endpoint-anchored fit)
  airtimeSec: number;       // MEASURED take-off → landing (IMU)
  distanceM: number | null; // GPS displacement take-off → landing (fallback v·t)
  takeoffTMs: number;
  landingTMs: number;
  apexTMs: number;
  confidence: number;       // 0..1 multi-signal agreement
  arcBaroPoints: number;    // how many baro samples fell inside the arc (quality)
  refined: boolean;         // true on the second (drift-checked) emission
  driftSuspect: boolean;    // refinement measured a bad return-to-zero
  rtzM: number | null;      // measured net drift across the arc (refinement)
}

interface BaroPt { t: number; alt: number }
interface LocPt { t: number; lat: number; lng: number; spd: number }

type State = 'IDLE' | 'AIRBORNE';

// ─────────────────────────────────────────────────────────────────────────────
// pipeline
// ─────────────────────────────────────────────────────────────────────────────
export class JumpPipelineV12 {
  private readonly cfg: V12Config;
  /** fired ≤~0.5 s after the landing evidence — the on-wrist display number. */
  onJump: (j: V12Jump) => void = () => {};
  /** fired ~refineDelaySec later with the drift-checked (possibly corrected) jump. */
  onJumpRefined: (j: V12Jump) => void = () => {};
  /** state-machine trace (V12DebugSnapshot feed) — takeoffs, landings, aborts. */
  onDebug: (tMs: number, event: string) => void = () => {};

  // accel state (causal chop over a short ring)
  private accRing: { t: number; a: number }[] = [];
  private chop = 0;              // current causal |a| RMS-around-mean
  private preChop = 0;           // chop frozen at take-off (the run-up reference)
  private lastCrashT = -Infinity;

  // baro / location rings (short — anchor + arc only)
  private baro: BaroPt[] = [];
  private locs: LocPt[] = [];
  private submerged: boolean | null = null;

  // state machine
  private state: State = 'IDLE';
  private tTO = 0;               // take-off time (ms)
  private anchorB = 0;           // water level at take-off (m, relAlt frame)
  private anchorOk = false;
  private landEvidenceT = -1;    // first landing evidence (impact/chop-hold/submersion)
  private chopRunStart = -1;     // start of the current chop-resume run
  private pendingRefine: { j: V12Jump; dueT: number } | null = null;
  // arc-baro trackers (baro-aware landing): the chop channel alone cannot time a
  // soft landing when in-flight bar-work chop exceeds the glassy-water run-up
  // chop (measured on LOG4 J2) — the ~1 Hz baro bounds it instead.
  private arcLastBaroRel = Infinity; // last in-arc baro sample, relative to anchor
  private arcPrevBaroRel = Infinity; // the one before it (flatness test)
  private arcLastBaroT = -1;
  private arcMaxBaroRel = 0;
  private arcBaroSeen = false;

  /** "Back on the water" test for an in-arc baro sample: LOW relative to the arc
   *  (drift-tolerant: the water line may have shifted by up to ~30 % of the arc
   *  height during the jump — measured on LOG4) AND FLAT (the arc's slope is
   *  gone; two consecutive samples agree). A mid-flight sample fails both. */
  private baroOnWater(strict: boolean): boolean {
    if (!this.arcBaroSeen) return false;
    const lowBar = strict
      ? Math.max(0.35, 0.20 * this.arcMaxBaroRel)
      : Math.max(0.60, 0.30 * this.arcMaxBaroRel);
    const flat = this.arcPrevBaroRel === Infinity
      ? true
      : Math.abs(this.arcLastBaroRel - this.arcPrevBaroRel) <= 0.35;
    return this.arcLastBaroRel <= lowBar && flat;
  }

  constructor(cfg: V12Config = DEFAULT_V12_CONFIG) { this.cfg = cfg; }

  // ── inputs ────────────────────────────────────────────────────────────────
  /** |a| in g (rotation-invariant — no attitude needed), any rate ≥50 Hz. */
  addAccel(tMs: number, aMag: number): void {
    const c = this.cfg;
    // causal chop: RMS deviation over the trailing chopWinSec
    this.accRing.push({ t: tMs, a: aMag });
    const lo = tMs - c.chopWinSec * 1000;
    while (this.accRing.length && this.accRing[0]!.t < lo) this.accRing.shift();
    const n = this.accRing.length;
    if (n >= 4) {
      let s = 0; for (const r of this.accRing) s += r.a;
      const m = s / n;
      let q = 0; for (const r of this.accRing) q += (r.a - m) * (r.a - m);
      this.chop = Math.sqrt(q / n);
    }

    // CRASH marker (feeds the cooldown) ONLY while not airborne — a high-g event
    // DURING a jump is the landing impact (a hard touchdown / catch), not a slam,
    // and must not arm the cooldown that would block the next take-off.
    if (aMag >= c.crashG && this.state === 'IDLE') this.lastCrashT = tMs;

    if (this.state === 'IDLE') {
      // TAKE-OFF: a yank while planing, not a crash, not inside a crash cooldown
      if (aMag >= c.yankG && aMag < c.crashG
          && tMs - this.lastCrashT > c.crashCooldownSec * 1000
          && this.isPlaning(tMs)) {
        const anchor = this.waterAnchor(tMs);
        if (anchor != null) {
          this.state = 'AIRBORNE';
          this.tTO = tMs;
          this.anchorB = anchor;
          this.anchorOk = true;
          this.preChop = Math.max(this.chop, 0.02);
          this.landEvidenceT = -1; this.chopRunStart = -1;
          this.arcLastBaroRel = Infinity; this.arcPrevBaroRel = Infinity; this.arcLastBaroT = -1;
          this.arcMaxBaroRel = 0; this.arcBaroSeen = false;
          this.onDebug(tMs, `TAKEOFF yank=${aMag.toFixed(1)}g anchor=${anchor.toFixed(2)}`);
        }
      }
    } else {
      // AIRBORNE: find the landing
      const air = (tMs - this.tTO) / 1000;
      if (air > c.maxAirSec) { this.state = 'IDLE'; this.onDebug(tMs, 'ABORT maxAir'); return; }
      if (air < c.minAirSec * 0.5) return; // ignore the yank's own tail
      let landed = false;
      // A high-g event mid-flight is a crash ONLY if it is EARLY (before a real
      // airborne phase) or the arc never gained altitude — i.e. not a real jump.
      // Once a genuine altitude arc exists past minAirSec, a high-g is the LANDING
      // IMPACT (hard touchdown / catch) → fall through to the landing detector.
      const realArc = this.arcMaxBaroRel >= c.minJumpHeightM * 0.5;
      if (aMag >= c.crashG && (air < c.minAirSec || !realArc)) {
        this.state = 'IDLE'; this.onDebug(tMs, `ABORT crashMidArc ${aMag.toFixed(1)}g`); return;
      }
      // CANDIDATE RESTART: a fresh take-off-grade yank while the current arc has
      // shown NO baro elevation means the current candidate was a false start
      // (chop spike) that would otherwise OCCUPY the state machine and swallow
      // the real jump behind it (simulation: a stale candidate ate J2's 6.9 g
      // yank). A real jump cannot restart-loop: its arc elevates the baro within
      // ~1 s, closing this door.
      if (aMag >= c.yankG && air >= 1.0 && this.arcMaxBaroRel < 0.5
          && this.isPlaning(tMs)) {
        const anchor = this.waterAnchor(tMs);
        if (anchor != null) {
          this.tTO = tMs;
          this.anchorB = anchor;
          this.preChop = Math.max(this.chop, 0.02);
          this.landEvidenceT = -1; this.chopRunStart = -1;
          this.arcLastBaroRel = Infinity; this.arcPrevBaroRel = Infinity; this.arcLastBaroT = -1;
          this.arcMaxBaroRel = 0; this.arcBaroSeen = false;
          this.onDebug(tMs, `RESTART yank=${aMag.toFixed(1)}g anchor=${anchor.toFixed(2)}`);
          return;
        }
      }

      // ── TWO-STAGE LANDING: IMU gives the precise TIME (evidence), the baro
      //    CONFIRMS the water contact (the only sensor that truly knows "on
      //    water"). A mid-flight bar spike raises evidence too — but the baro
      //    stays high, the evidence goes stale after 2 s, and the arc continues
      //    (simulation: impact-only landing cut J1/J2 mid-flight). Evidence
      //    cannot precede minAirSec (the yank's own tail is not a landing). ──
      if (air >= c.minAirSec) {
        if (aMag >= c.landImpactG && this.landEvidenceT < 0) this.landEvidenceT = tMs; // impact
        if (this.chop >= this.preChop * c.chopResumeFrac) {                            // chop-resume
          if (this.chopRunStart < 0) this.chopRunStart = tMs;
          if ((tMs - this.chopRunStart) / 1000 >= c.chopResumeHoldSec && this.landEvidenceT < 0) {
            this.landEvidenceT = this.chopRunStart;
          }
        } else this.chopRunStart = -1;
        if (this.submerged === true && this.landEvidenceT < 0) this.landEvidenceT = tMs; // Ultra
        if (this.landEvidenceT > 0) {
          const baroSilent = this.arcLastBaroT < 0
            ? air > 2.5
            : (tMs - this.arcLastBaroT) / 1000 > 2.5;
          // the confirming baro sample must be CLOSE to the evidence (≤1.3 s ≈
          // one baro interval) — a later confirm belongs to a later landing,
          // and the evidence was a mid-flight spike (simulation: J2 cut to
          // 1.61 s exactly this way).
          const closeInTime = Math.abs(this.arcLastBaroT - this.landEvidenceT) <= 1300;
          const baroConfirms =
            (this.baroOnWater(false) && closeInTime)
            || this.submerged === true
            || baroSilent; // sensor gap → trust the IMU alone
          if (baroConfirms) { this.finishJump(this.landEvidenceT); return; }
          if ((tMs - this.landEvidenceT) / 1000 > 2.0) { // stale — a mid-flight spike
            this.landEvidenceT = -1; this.chopRunStart = -1;
          }
        }
      }
    }

    // due refinement?
    if (this.pendingRefine && tMs >= this.pendingRefine.dueT) this.refine(tMs);
  }

  /** CMAltimeter relativeAltitude in METRES, with its own timestamp (~1 Hz). */
  addBaro(tMs: number, relAltM: number): void {
    this.baro.push({ t: tMs, alt: relAltM });
    const lo = tMs - Math.max(this.cfg.anchorMaxAgeSec + this.cfg.maxAirSec + this.cfg.refineDelaySec, 30) * 1000;
    while (this.baro.length && this.baro[0]!.t < lo) this.baro.shift();
    // BARO-RETURN landing (third path): the arc's altitude came back to the
    // anchor. At ~1 Hz this times a soft landing to ±~1 s — decisive when the
    // impact is soft AND the chop reference is broken (glassy water + bar work).
    if (this.state === 'AIRBORNE') {
      const rel = relAltM - this.anchorB;
      this.arcPrevBaroRel = this.arcLastBaroRel === Infinity ? Infinity : this.arcLastBaroRel;
      this.arcLastBaroRel = rel; this.arcLastBaroT = tMs;
      if (rel > this.arcMaxBaroRel) this.arcMaxBaroRel = rel;
      this.arcBaroSeen = true;
      const air = (tMs - this.tTO) / 1000;
      // pending IMU evidence + this on-water sample close to it → CONFIRMED
      if (this.landEvidenceT > 0 && air >= this.cfg.minAirSec && this.baroOnWater(false)
          && Math.abs(tMs - this.landEvidenceT) <= 1300) {
        this.finishJump(this.landEvidenceT);
        return;
      }
      // BARO-RETURN (no IMU evidence — the soft glassy-water landing): the arc
      // was genuinely elevated and this sample is low AND flat → land at its time
      if (air >= this.cfg.minAirSec && this.arcMaxBaroRel >= 1.0 && this.baroOnWater(true)) {
        this.finishJump(tMs);
      }
    }
  }

  /** GPS fix (~1 Hz): position + speed (m/s). */
  addLocation(tMs: number, lat: number, lng: number, speedMs: number): void {
    this.locs.push({ t: tMs, lat, lng, spd: speedMs });
    const lo = tMs - 30_000;
    while (this.locs.length && this.locs[0]!.t < lo) this.locs.shift();
  }

  /** OPTIONAL (Ultra) — a direct out-of-water signal. Never required. */
  addSubmersion(_tMs: number, submerged: boolean): void { this.submerged = submerged; }

  /** Session end — flush a due refinement. */
  flush(tMs: number): void { if (this.pendingRefine) this.refine(tMs); }

  // ── internals ─────────────────────────────────────────────────────────────
  private isPlaning(tMs: number): boolean {
    // PERMISSIVE on missing GPS: the gate rejects a candidate only when GPS is
    // PRESENT and too slow. With no recent fix (GPS gap / cold start / garden
    // test) we can't DISPROVE planing, so we allow it — the real anti-false-
    // positive is the 1.5 m altitude-arc + airtime gate downstream, which hand
    // motion never clears. (A stale fix > planingWinSec is treated as absent.)
    const lo = tMs - this.cfg.planingWinSec * 1000;
    let sawFix = false;
    for (let i = this.locs.length - 1; i >= 0; i--) {
      const l = this.locs[i]!;
      if (l.t < lo) break;
      sawFix = true;
      if (l.spd >= this.cfg.planingSpeedMs) return true;
    }
    return !sawFix; // present+slow → false; absent → true
  }

  /** Water level anchor: median of the last anchorSamples baro points BEFORE the
   *  yank (all must be fresh) — the only "baseline" V12 ever needs. */
  private waterAnchor(tMs: number): number | null {
    const c = this.cfg;
    // BASE LEVEL over the anchor window (up to 0.3 s before the yank). A LOW
    // PERCENTILE (~25th) is the robust "water / hand-carry" level: the rider
    // spends the pre-jump window near it and only goes UP, so a low percentile
    // is immune to the exact yank timing and to a running-test candidate that
    // re-anchors on arm-swing noise (a median at a noisy yank moment drifted the
    // anchor up and collapsed the height to 0). Riding is unaffected (the water
    // IS the low point). Uses a wider window than `anchorSamples` for stability.
    const pts: number[] = [];
    for (let i = this.baro.length - 1; i >= 0; i--) {
      const b = this.baro[i]!;
      if (b.t > tMs - 300) continue;               // exclude the rise itself
      if (tMs - b.t > c.anchorMaxAgeSec * 1000) break;
      pts.push(b.alt);
    }
    if (pts.length < 2) return null;
    pts.sort((a, b) => a - b);
    return pts[Math.floor(pts.length * 0.25)]!;    // 25th percentile = base level
  }

  /** Height from the arc's baro points.
   *  ≥2 interior points → TAKE-OFF-ANCHORED FREE PARABOLA z = b·τ + c·τ²
   *  (constraint z(0)=0): the apex = the vertex, INDEPENDENT of the landing-time
   *  estimate — a soft landing detected ±1 s late cannot bias the height
   *  (simulation: the endpoint-anchored basis under-read 1 m for a +0.9 s
   *  landing error).
   *  1 point → endpoint-anchored 1-parameter basis (needs T, but one point
   *  cannot constrain two parameters).
   *  0 points (short hop) → glide model from the measured airtime. */
  private fitHeight(tLD: number): { h: number; apexT: number; arcPts: number } {
    const c = this.cfg;
    const T = (tLD - this.tTO) / 1000;
    const pts: { tau: number; z: number }[] = [];
    for (const b of this.baro) {
      if (b.t <= this.tTO + 200 || b.t >= tLD - 100) continue;
      pts.push({ tau: (b.t - this.tTO) / 1000, z: b.alt - this.anchorB });
    }
    const arcPts = pts.length;
    let h: number | null = null, apexT = this.tTO + (T / 2) * 1000;
    if (arcPts >= 2) {
      // LSQ for z = b·τ + c·τ²: normal equations over the arc points
      let s2 = 0, s3 = 0, s4 = 0, sz1 = 0, sz2 = 0;
      for (const p of pts) { const t2 = p.tau * p.tau; s2 += t2; s3 += t2 * p.tau; s4 += t2 * t2; sz1 += p.z * p.tau; sz2 += p.z * t2; }
      const det = s2 * s4 - s3 * s3;
      if (Math.abs(det) > 1e-9) {
        const bC = (sz1 * s4 - sz2 * s3) / det;
        const cC = (sz2 * s2 - sz1 * s3) / det;
        if (cC < -1e-6) {
          const tauApex = -bC / (2 * cC);
          if (tauApex > 0 && tauApex < T + 1.0) { // vertex physically inside the arc
            h = bC * tauApex + cC * tauApex * tauApex;
            apexT = this.tTO + tauApex * 1000;
          }
        }
      }
    }
    if (h == null && arcPts >= 1) {
      // endpoint-anchored 1-parameter basis φ(τ)=4τ(T−τ)/T²
      let num = 0, den = 0;
      for (const p of pts) { const phi = 4 * p.tau * (T - p.tau) / (T * T); num += p.z * phi; den += phi * phi; }
      if (den > 1e-9) h = num / den;
    }
    if (h == null) h = (G / 8) * (T / c.kiteGlideFactor) * (T / c.kiteGlideFactor); // glide model
    // FLOOR at the highest OBSERVED arc point (minus anchor): a parabola through a
    // real arc must recover the apex BETWEEN samples, i.e. ≥ the max sampled point;
    // if the concave fit failed (noisy/asymmetric arc — e.g. a running-test throw),
    // never report LESS than what the barometer actually saw.
    let maxObs = 0;
    for (const p of pts) if (p.z > maxObs) maxObs = p.z;
    if (maxObs > h) { h = maxObs; if (apexT === this.tTO + (T / 2) * 1000) apexT = this.tTO + (T / 2) * 1000; }
    h = Math.min(Math.max(h, 0), c.maxJumpHeightM);
    return { h, apexT, arcPts };
  }

  private distance(tLD: number): number | null {
    const at = (t: number): LocPt | null => {
      let best: LocPt | null = null, bd = Infinity;
      for (const l of this.locs) { const d = Math.abs(l.t - t); if (d < bd) { bd = d; best = l; } }
      return bd <= 2500 ? best : null;
    };
    const a = at(this.tTO), b = at(tLD);
    // lat=lng=0 means "speed-only fix" (some loggers have no position) → fall back
    if (a && b && (a.lat !== 0 || a.lng !== 0) && (b.lat !== 0 || b.lng !== 0)) {
      const R = 6_371_000, dLat = (b.lat - a.lat) * Math.PI / 180, dLng = (b.lng - a.lng) * Math.PI / 180;
      const q = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * Math.PI / 180) * Math.cos(b.lat * Math.PI / 180) * Math.sin(dLng / 2) ** 2;
      return Math.round(2 * R * Math.asin(Math.sqrt(q)) * 10) / 10;
    }
    if (a) return Math.round(a.spd * ((tLD - this.tTO) / 1000) * 10) / 10;
    return null;
  }

  private finishJump(tLD: number): void {
    this.state = 'IDLE';
    const c = this.cfg;
    if (!this.anchorOk) return;
    const T = (tLD - this.tTO) / 1000;
    if (T < c.minAirSec || T > c.maxAirSec) { this.onDebug(tLD, `REJECT airtime ${T.toFixed(2)}s`); return; }
    const { h, apexT, arcPts } = this.fitHeight(tLD);
    if (h < c.minJumpHeightM) { this.onDebug(tLD, `REJECT belowMinHeight ${h.toFixed(2)}m T=${T.toFixed(2)}s`); return; }
    let conf = 0.55;
    if (arcPts >= 1) conf += 0.15;
    if (arcPts >= 2) conf += 0.10;
    if (this.chop < this.preChop * 0.9) conf += 0.05;
    conf = Math.min(1, conf);
    const j: V12Jump = {
      heightM: Math.round(h * 100) / 100,
      airtimeSec: Math.round(T * 100) / 100,
      distanceM: this.distance(tLD),
      takeoffTMs: this.tTO,
      landingTMs: tLD,
      apexTMs: apexT,
      confidence: Math.round(conf * 100) / 100,
      arcBaroPoints: arcPts,
      refined: false,
      driftSuspect: false,
      rtzM: null,
    };
    this.onJump(j); // ← the ≤2 s wrist number
    this.pendingRefine = { j, dueT: tLD + c.refineDelaySec * 1000 };
  }

  /** REFINEMENT (the ≤5 s DISPLAY number): a TWO-SIDED anchored refit. The
   *  post-landing on-water baro samples give a REAR anchor; front + rear anchors
   *  measure the LINEAR drift rate across the arc, which is then removed from
   *  every arc point analytically before the endpoint-anchored refit — linear
   *  drift (the dominant wind/thermal component over 8–10 s) cancels exactly
   *  instead of being half-guessed (the old −rtz/2). Residual |rtz| after the
   *  linear model ⇒ non-linear drift ⇒ driftSuspect flag (never a rejection). */
  private refine(nowT: number): void {
    const p = this.pendingRefine!;
    this.pendingRefine = null;
    const c = this.cfg;
    // rear anchor: median + mean-time of the post-landing on-water samples
    const post: { t: number; alt: number }[] = [];
    for (const b of this.baro) if (b.t > p.j.landingTMs + 400 && b.t <= nowT) post.push(b);
    if (!post.length) { this.onJumpRefined({ ...p.j, refined: true }); return; }
    const vals = post.map((x) => x.alt).sort((a, b) => a - b);
    const B1 = vals[vals.length >> 1]!;
    const t1 = post.reduce((s, x) => s + x.t, 0) / post.length;
    // front anchor: the jump's own take-off anchor + its mean time
    const B0 = this.anchorBAt(p.j);
    const t0 = p.j.takeoffTMs - 2000; // ≈ centre of the 4-sample pre-take-off window
    const rtz = B1 - B0;
    const d = (t1 - t0) > 1000 ? rtz / (t1 - t0) : 0; // measured drift (m per ms)
    // MODEL SELECTION between (a) no-drift and (b) linear-drift-across-the-arc:
    // a splash-triggered drift turns on only AT the landing (measured on LOG4's
    // post-jump ramps) — model (b) then over-corrects the arc. Let the arc's own
    // residuals arbitrate: fit the take-off-anchored parabola under each model
    // and keep the one that explains the points better.
    const T = (p.j.landingTMs - p.j.takeoffTMs) / 1000;
    const fitModel = (drate: number): { h: number; sse: number; n: number } | null => {
      const pts: { tau: number; z: number }[] = [];
      for (const b of this.baro) {
        if (b.t <= p.j.takeoffTMs + 200 || b.t >= p.j.landingTMs - 100) continue;
        pts.push({ tau: (b.t - p.j.takeoffTMs) / 1000, z: b.alt - B0 - drate * (b.t - t0) });
      }
      if (pts.length < 1) return null;
      let s2 = 0, s3 = 0, s4 = 0, sz1 = 0, sz2 = 0;
      for (const q of pts) { const t2 = q.tau * q.tau; s2 += t2; s3 += t2 * q.tau; s4 += t2 * t2; sz1 += q.z * q.tau; sz2 += q.z * t2; }
      const det = s2 * s4 - s3 * s3;
      let h: number | null = null, bC = 0, cC = 0;
      if (pts.length >= 2 && Math.abs(det) > 1e-9) {
        bC = (sz1 * s4 - sz2 * s3) / det;
        cC = (sz2 * s2 - sz1 * s3) / det;
        if (cC < -1e-6) {
          const ta = -bC / (2 * cC);
          if (ta > 0 && ta < T + 1.0) h = bC * ta + cC * ta * ta;
        }
      }
      if (h == null) { // 1-parameter endpoint basis fallback
        let num = 0, den = 0;
        for (const q of pts) { const phi = 4 * q.tau * (T - q.tau) / (T * T); num += q.z * phi; den += phi * phi; }
        if (den <= 1e-9) return null;
        h = num / den;
        bC = 4 * h / T; cC = -4 * h / (T * T); // the basis as a parabola, for SSE
      }
      let sse = 0;
      for (const q of pts) { const e = q.z - (bC * q.tau + cC * q.tau * q.tau); sse += e * e; }
      return { h: Math.min(Math.max(h, 0), c.maxJumpHeightM), sse, n: pts.length };
    };
    const mA = fitModel(0), mB = fitModel(d);
    let h = p.j.heightM;
    if (mA && mB) h = (mB.sse < mA.sse ? mB : mA).h;
    else if (mA) h = mA.h;
    else if (mB) h = mB.h;
    const drift = Math.abs(rtz) > c.rtzCorrectM; // large net drift measured — flag it
    // RETRACTION: the drift-corrected refit fell below the display floor — the
    // instant emission was a drift artifact. Collapse the confidence so the
    // display layer (which shows the ≤5 s refined number) drops/greys it.
    const conf = h < c.minJumpHeightM ? Math.min(p.j.confidence, 0.3) : p.j.confidence;
    this.onJumpRefined({
      ...p.j,
      heightM: Math.round(h * 100) / 100,
      confidence: conf,
      refined: true,
      driftSuspect: drift,
      rtzM: Math.round(rtz * 100) / 100,
    });
  }

  // the anchor used for that jump (anchorB may have been overwritten by a newer
  // take-off before the refinement fires — recompute from the jump's own window)
  private anchorBAt(j: V12Jump): number {
    const pts: number[] = [];
    for (let i = this.baro.length - 1; i >= 0; i--) {
      const b = this.baro[i]!;
      if (b.t > j.takeoffTMs - 300) continue;
      if (j.takeoffTMs - b.t > this.cfg.anchorMaxAgeSec * 1000) break;
      pts.push(b.alt);
      if (pts.length >= this.cfg.anchorSamples) break;
    }
    if (!pts.length) return this.anchorB;
    pts.sort((a, b) => a - b);
    return pts[pts.length >> 1]!;
  }
}
