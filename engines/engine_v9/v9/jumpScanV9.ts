/**
 * jumpScanV9 — the ON-WATCH detection ARCHITECTURE. NO real-time, NO state
 * machine. V9 = the V8 baro-centric ENGINE (`detectJumps`) driven by a cyclic
 * ring buffer + periodic backward scan. (V8 = the height algorithm; V9 = how the
 * watch runs it in the field. There is no separate "V9 engine" — same physics.)
 *
 * ════════════════════════════════════════════════════════════════════════════
 * THE ARCHITECTURE
 * ════════════════════════════════════════════════════════════════════════════
 * The watch does NOT classify jumps sample-by-sample. A single periodic batch
 * scan runs every `tickSec` and re-runs the FULL engine (`detectJumps`) over a
 * bounded look-back window — "scan the buffer backwards every few seconds".
 *
 * TWO-STAGE EMISSION (provisional → final) — solves the latency/accuracy split:
 *   • PROVISIONAL (≤5 s, ±~0.2 m): the instant a jump is detected AND has landed
 *     (now ≥ estLanding + provisionalSettleSec), emit the current measurement for
 *     the LIVE HUD. The baro's future side is still truncated, but the measurement
 *     is already ~0.2 m (the past + partial-future baseline carries it).
 *   • FINAL (~settleSec, ±~0.17 m): once the apex's full ±baseline future is in
 *     the window, emit the stable accurate value — the canonical session result.
 *
 * Each jump is tracked as ONE pending entry (a stable `id`), matched across ticks
 * by ARC OVERLAP (take-off→landing), so apex jitter on the truncated future does
 * NOT spawn duplicates (locking the identity is what makes a fast tick safe — a
 * single-stage low settle gave 19 jumps instead of 10). The HUD shows the
 * provisional, then UPDATES the same `id` to the final.
 *
 * Why a backward scan: a barometric jump height needs a BI-directional baseline
 * (±baselineHalfWinSec) + the post-apex parabola — a causal real-time detector
 * cannot see the future. Why a WINDOW: bounded memory/CPU (a 3-hour session costs
 * the same as a minute). TRAILING-EDGE GUARD: a jump's apex must be ≥
 * baselineHalfWinSec from the window's oldest edge, else its PAST baseline is
 * truncated → an inflated phantom.
 *
 * Native shell: `addSample(s)` per sample; `scan(now)` on a `tickSec` timer →
 * ScanEmissions (drive the HUD by `stage`+`id`); `flush(now)` once at session end.
 */

import type { SensorSample } from './types.ts';
import {
  detectJumps,
  DEFAULT_JUMP_PARAMS,
  type JumpEngineParams,
  type JumpResult,
} from './jumpEngine.ts';

/** Estimated landing (ms) = take-off + the height-derived airtime. Stable — the
 *  alt-bracket `landingTimeMs` is loose at sparse baro. Anchors ripeness/latency
 *  so timings are measured from the REAL landing. */
function estLandingMs(j: JumpResult): number {
  return (j.takeoffTimeMs ?? 0) + j.airTimeSec * 1000;
}
/** A jump's arc interval [take-off, estimated-landing] (ms) — the identity used
 *  to match the same jump across ticks (overlap = same jump). */
function jumpArc(j: JumpResult): { lo: number; hi: number } {
  return { lo: j.takeoffTimeMs ?? 0, hi: estLandingMs(j) };
}
function arcsOverlap(a: { lo: number; hi: number }, b: { lo: number; hi: number }, marginMs: number): boolean {
  return a.lo < b.hi + marginMs && b.lo < a.hi + marginMs;
}

export type ScanStage = 'provisional' | 'final';

export interface ScanConfigV9 {
  /** Scan cadence (s). A fast tick (2 s) gives a near-live provisional. */
  tickSec: number;
  /** Look-back window (s); bounds memory. ≥ maxAirTimeSec + 2·baselineHalfWinSec. */
  windowSec: number;
  /** FINAL is emitted `settleSec` after the estimated landing (the apex's full
   *  ±baseline future is then in-window → the accurate, stable number). */
  settleSec: number;
  /** PROVISIONAL is emitted `provisionalSettleSec` after the estimated landing —
   *  the fast live number (≤5 s). */
  provisionalSettleSec: number;
  /** Arc-overlap match margin (s) for tracking a jump across ticks / dedup. */
  dedupTolSec: number;
  /** An un-finalized pending not re-detected for this long is dropped (the full
   *  baseline rejected it — a truncated-edge false positive). Also gates which
   *  stale pendings `flush()` may still emit. */
  pendingDropGapSec: number;
  /** SAFETY: hard cap on buffered samples in case the native tick timer stalls
   *  and `scan()` (which evicts) stops running — prevents unbounded memory.
   *  Sized for windowSec at a generous IMU rate. 0 = off. */
  maxBufferedSamples: number;
  /** EARLY-FINALIZE GATE: >0 lets a jump whose drift-absence is PROVEN
   *  (`jump.cleanNoDrift` — return-to-zero + past slope + real float + clean
   *  landing bracket) emit its FINAL this many seconds after landing instead of
   *  waiting the full settleSec. ~90% of jumps are drift-free (LOG2: 10/11) and
   *  gain a ≤5 s accurate final; the rest keep the safe 16 s path. 0 = off. */
  earlyFinalizeSec: number;
}

export const DEFAULT_SCAN_CONFIG: ScanConfigV9 = {
  tickSec: 2, // fast → live provisional within ~4 s of landing
  windowSec: 75,
  settleSec: 16, // accurate FINAL (≥ baselineHalfWinSec so the future baseline is in-window)
  provisionalSettleSec: 2, // fast PROVISIONAL (just-landed) for the HUD
  dedupTolSec: 1.0, // arc-overlap margin (jumps are ≥ jumpSepSec apart, so arcs don't overlap)
  pendingDropGapSec: 8, // ≥ a few ticks — a real jump is re-detected every tick
  maxBufferedSamples: 60_000, // 75 s @ up to ~500 Hz + margin (normal 50 Hz peak ≈ 4 k)
  earlyFinalizeSec: 0, // OFF (legacy). Recommended 4 after golden validation.
};

/** One emission for the HUD: a jump at a stage, with its stable id + latency. */
export interface ScanEmission {
  jump: JumpResult;
  stage: ScanStage;
  /** Stable across the provisional→final pair of the SAME jump (HUD updates it). */
  id: number;
  emittedAtMs: number;
  /** delay from the (estimated) landing to this emission (s). */
  emitLatencySec: number;
  /** caught only by the session-end flush (never ripened during the ride). */
  viaFlush: boolean;
  /** FINAL emitted via the Early-Finalize gate (cleanNoDrift proven) before settleSec. */
  early: boolean;
}

interface PendingJump {
  id: number;
  jump: JumpResult; // latest (most-refined) measurement
  seenAtMs: number;   // last tick this jump was (re-)detected
  provisionalEmitted: boolean;
  finalEmitted: boolean;
}

/**
 * Stateful periodic scanner. One instance per session. Feed every sample, call
 * `scan(now)` on the tick timer, `flush(now)` once at the end.
 */
export class JumpScannerV9 {
  private buf: SensorSample[] = [];
  private pending: PendingJump[] = [];
  /** Arcs already FINALIZED — dedup across eviction (a straddling re-detection of
   *  a finalized jump is ignored). O(jumps), kept for the session. */
  private finalizedArcs: { lo: number; hi: number }[] = [];
  private nextId = 1;
  private readonly params: JumpEngineParams;
  private readonly cfg: ScanConfigV9;
  private lastTickMs = -Infinity;

  constructor(
    params: JumpEngineParams = DEFAULT_JUMP_PARAMS,
    cfg: ScanConfigV9 = DEFAULT_SCAN_CONFIG,
  ) {
    this.params = params;
    this.cfg = cfg;
    // ── INVARIANT VALIDATION (ALGORITHM_V9 §1.1) — these are NOT free knobs. ──
    // Violating them silently produces phantoms (historically: 29 jumps / a 4.6 m
    // phantom). Warn loudly instead of throwing so a live session still runs.
    if (cfg.settleSec < params.baselineHalfWinSec) {
      console.warn(
        `[JumpScannerV9] settleSec (${cfg.settleSec}) < baselineHalfWinSec ` +
        `(${params.baselineHalfWinSec}) — FINALs will use a truncated future ` +
        `baseline → inflated heights. Raise settleSec.`);
    }
    const minWindow = cfg.settleSec + 2 * params.baselineHalfWinSec + params.maxAirTimeSec;
    if (cfg.windowSec < minWindow) {
      console.warn(
        `[JumpScannerV9] windowSec (${cfg.windowSec}) < settle + 2·baseHalf + ` +
        `maxAir (${minWindow}) — the stable interior band collapses → truncated ` +
        `PAST baselines → phantom jumps. Raise windowSec.`);
    }
    if (cfg.provisionalSettleSec > cfg.settleSec) {
      console.warn(`[JumpScannerV9] provisionalSettleSec > settleSec — provisionals would never precede finals.`);
    }
    if (cfg.earlyFinalizeSec >= cfg.settleSec && cfg.earlyFinalizeSec > 0) {
      console.warn(`[JumpScannerV9] earlyFinalizeSec (${cfg.earlyFinalizeSec}) ≥ settleSec (${cfg.settleSec}) — the early gate can never fire.`);
    }
  }

  /** Append one raw sample (assumed monotonic in `t`). */
  addSample(s: SensorSample): void {
    this.buf.push(s);
    // SAFETY: if the native tick timer stalls, scan() (which evicts) stops running;
    // cap the buffer so a stalled session cannot grow memory unboundedly.
    const cap = this.cfg.maxBufferedSamples;
    if (cap > 0 && this.buf.length > cap) this.buf.splice(0, this.buf.length - cap);
  }

  get bufferedSamples(): number {
    return this.buf.length;
  }

  due(nowMs: number): boolean {
    return nowMs - this.lastTickMs >= this.cfg.tickSec * 1000;
  }

  /**
   * Run ONE backward scan. Detects jumps in the window, tracks each as a pending
   * (matched by arc overlap), and returns the emissions newly produced this tick:
   * a PROVISIONAL the moment a jump has landed, then a FINAL once it ripens.
   */
  scan(nowMs: number): ScanEmission[] {
    this.lastTickMs = nowMs;
    // cheap no-op: nothing buffered and nothing pending → skip the engine entirely
    // (long sample gaps / replay fast-forward hit this path every tick).
    if (this.buf.length === 0 && this.pending.length === 0) return [];
    const winLo = nowMs - this.cfg.windowSec * 1000;
    const lo = this.track(nowMs);

    // EMIT provisional / final per pending. A pending is only finalized while it
    // is STILL detected by the (now full-baseline) scan this tick — a pending
    // created on the truncated leading-edge baseline that the full baseline later
    // rejects is dropped, never finalized (this is what keeps FINALs clean: ~the
    // whole-log count, not the inflated truncated-baseline count).
    const out: ScanEmission[] = [];
    const provMs = this.cfg.provisionalSettleSec * 1000;
    const finMs = this.cfg.settleSec * 1000;
    const earlyMs = this.cfg.earlyFinalizeSec * 1000;
    const dropGapMs = this.cfg.pendingDropGapSec * 1000; // full baseline rejected it
    for (const p of this.pending) {
      const seenNow = p.seenAtMs === nowMs;
      const age = nowMs - estLandingMs(p.jump);
      if (seenNow && !p.provisionalEmitted && age >= provMs) {
        p.provisionalEmitted = true;
        out.push(this.emit(p, 'provisional', nowMs, false));
      }
      // FINAL — the normal settle path, OR the Early-Finalize gate: a jump whose
      // drift-absence is PROVEN (cleanNoDrift) needs no future baseline (the only
      // thing the settle waits for is the net drift — here it is measured ≈0), so
      // its current measurement IS the stable value. A failed proof just waits.
      const earlyOk = earlyMs > 0 && age >= earlyMs && p.jump.cleanNoDrift === true;
      if (seenNow && !p.finalEmitted && (age >= finMs || earlyOk)) {
        p.provisionalEmitted = true; // the final supersedes any pending provisional
        p.finalEmitted = true;
        this.finalizedArcs.push(jumpArc(p.jump));
        out.push(this.emit(p, 'final', nowMs, false, age < finMs));
      }
    }

    // drop: finalized pendings that left the window, OR un-finalized ones the full
    // baseline stopped detecting (truncated-edge false positives). Evict samples.
    this.pending = this.pending.filter((p) =>
      p.finalEmitted ? jumpArc(p.jump).hi >= winLo : nowMs - p.seenAtMs <= dropGapMs);
    if (lo > 0) this.buf = this.buf.slice(lo);
    return out;
  }

  /** Session end: run a last detection pass (to catch a jump detected only at the
   *  very end), then emit a FINAL for every pending not yet finalized (best-effort
   *  with whatever future exists), plus a provisional if it never landed in time.
   *  STALE pendings — ones the full-baseline scan stopped re-detecting for
   *  `pendingDropGapSec` — are dropped, NOT emitted: they are the truncated-edge
   *  false positives the next scan tick would have discarded anyway. */
  flush(nowMs: number): ScanEmission[] {
    this.track(nowMs);
    const dropGapMs = this.cfg.pendingDropGapSec * 1000;
    const out: ScanEmission[] = [];
    for (const p of this.pending) {
      if (nowMs - p.seenAtMs > dropGapMs) continue; // full baseline rejected it
      if (!p.provisionalEmitted) { p.provisionalEmitted = true; out.push(this.emit(p, 'provisional', nowMs, true)); }
      if (!p.finalEmitted) { p.finalEmitted = true; this.finalizedArcs.push(jumpArc(p.jump)); out.push(this.emit(p, 'final', nowMs, true)); }
    }
    return out;
  }

  // ── internals ──────────────────────────────────────────────────────────────

  /** Detect jumps in the current window and track each as a pending (matched by
   *  arc overlap; latest measurement wins until finalized). Returns the evict
   *  index `lo` of the window so the caller can drop older samples. */
  private track(nowMs: number): number {
    const winLo = nowMs - this.cfg.windowSec * 1000;
    const stableLo = winLo + this.params.baselineHalfWinSec * 1000;
    const marginMs = this.cfg.dedupTolSec * 1000;
    const { window, lo } = this.windowSince(winLo);
    for (const j of detectJumps(window, this.params)) {
      if (j.takeoffTimeMs == null) continue;
      const apexMs = j.takeoffTimeMs + j.apexTimeSec * 1000;
      if (apexMs < stableLo) continue; // trailing-edge guard (incomplete past baseline)
      const arc = jumpArc(j);
      if (this.finalizedArcs.some((f) => arcsOverlap(f, arc, marginMs))) continue; // already final
      const p = this.pending.find((q) => arcsOverlap(jumpArc(q.jump), arc, marginMs));
      if (p) { if (!p.finalEmitted) p.jump = j; p.seenAtMs = nowMs; } // refine + mark seen
      else this.pending.push({ id: this.nextId++, jump: j, seenAtMs: nowMs, provisionalEmitted: false, finalEmitted: false });
    }
    return lo;
  }

  private windowSince(winLo: number): { window: SensorSample[]; lo: number } {
    let lo = 0;
    while (lo < this.buf.length && this.buf[lo]!.t < winLo) lo++;
    return { window: lo > 0 ? this.buf.slice(lo) : this.buf, lo };
  }

  private emit(p: PendingJump, stage: ScanStage, nowMs: number, viaFlush: boolean, early = false): ScanEmission {
    return {
      jump: p.jump,
      stage,
      id: p.id,
      emittedAtMs: nowMs,
      emitLatencySec: Math.round(((nowMs - estLandingMs(p.jump)) / 1000) * 10) / 10,
      viaFlush,
      early,
    };
  }
}

// ════════════════════════════════════════════════════════════════════════════
// REPLAY — drive a recorded log through the scanner EXACTLY as the watch would
// (cyclic buffer, fixed-grid ticks, provisional + final). Offline tools (the
// admin WATCH CALIB panel) use this to see the log "as the watch sees it".
// ════════════════════════════════════════════════════════════════════════════

export interface ReplayScanResult {
  /** ALL emissions (provisional + final). Use `finals` for the canonical jumps. */
  emissions: ScanEmission[];
  /** FINAL emissions only — the canonical, stable session result. */
  finals: ScanEmission[];
  ticks: number;
  peakBufferedSamples: number;
  config: ScanConfigV9;
}

export function replayScan(
  samples: SensorSample[],
  params: JumpEngineParams = DEFAULT_JUMP_PARAMS,
  cfg: ScanConfigV9 = DEFAULT_SCAN_CONFIG,
): ReplayScanResult {
  const scanner = new JumpScannerV9(params, cfg);
  const emissions: ScanEmission[] = [];
  const tickMs = cfg.tickSec * 1000;
  let ticks = 0, peak = 0;
  if (!samples.length) return { emissions: [], finals: [], ticks: 0, peakBufferedSamples: 0, config: cfg };

  let nextTick = samples[0]!.t + tickMs;
  for (const s of samples) {
    while (s.t >= nextTick) {
      ticks++;
      emissions.push(...scanner.scan(nextTick));
      nextTick += tickMs;
    }
    scanner.addSample(s);
    if (scanner.bufferedSamples > peak) peak = scanner.bufferedSamples;
  }
  emissions.push(...scanner.flush(samples[samples.length - 1]!.t));

  return {
    emissions,
    finals: emissions.filter((e) => e.stage === 'final'),
    ticks,
    peakBufferedSamples: peak,
    config: cfg,
  };
}
