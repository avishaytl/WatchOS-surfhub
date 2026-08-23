// ============================================================================
//  KitesurfJumpEngineV9.swift
//  Apple Watch S9 / Ultra · Kitesurf Jump — v9 (cyclic-buffer scan, provisional→final)
//
//  ALGORITHM v9 — single source of truth is engine_v9/v9/jumpScanV9.ts (TypeScript).
//  This Swift file is a LINE-FOR-LINE port; keep the two in sync.
//
//  WHAT v9 IS: NOT a new height algorithm — it REUSES the v8 baro-centric engine
//  (KitesurfJumpEngineV8.detectJumps). v9 is the on-watch ARCHITECTURE: a cyclic
//  ring buffer fed every sample, scanned backwards every `tickSec`, re-running the
//  FULL v8 engine over a bounded window. TWO-STAGE emission:
//    • PROVISIONAL — the moment a jump lands (≤ a few s): live HUD number.
//    • FINAL — once the apex's ±baseline future is in-window (~settleSec): accurate.
//  Each jump is ONE tracked pending (stable `id`), matched across ticks by ARC
//  OVERLAP so apex jitter on the truncated edge does NOT spawn duplicates; a
//  pending the full baseline later rejects is dropped, never finalized.
//
//  NATIVE WIRING (see JumpDetectorV9): feed every CoreMotion/GPS sample to
//  addSample(); call scan(now) on a `tickSec` cadence → the caller emits jumps
//  when a pending reaches its FINAL stage; call flush(now) once at session end.
//
//  UNITS: accel g (gravity removed) · gyro rad/s · gravity g · baro hPa · t MS.
//  NOTE: v9 reuses the v8 sample/result/param types (V8Sample, JumpResultV8,
//  JumpEngineV8Params) — the TS source names them JumpSample/JumpResult/JumpEngineParams.
// ============================================================================

import Foundation

enum ScanStageV9: String {
    case provisional
    case final_ = "final"
    case retracted   // a provisional-emitted pending the full baseline later rejected → remove it
}

struct ScanConfigV9 {
    var tickSec: Double = 2          // fast → live provisional within ~4 s of landing
    var windowSec: Double = 75       // look-back window (bounds memory)
    var settleSec: Double = 16       // FINAL: ≥ baselineHalfWinSec so the future baseline is in-window
    var provisionalSettleSec: Double = 2  // PROVISIONAL: fast (just-landed) for the HUD
    var dedupTolSec: Double = 1.0    // arc-overlap match margin
    static let `default` = ScanConfigV9()
}

struct ScanEmissionV9 {
    var jump: JumpResultV8
    var stage: ScanStageV9
    var id: Int                      // stable across the provisional→final pair (HUD updates it)
    var emittedAtMs: Double
    var emitLatencySec: Double       // delay from the (estimated) landing to this emission
    var viaFlush: Bool
}

/// Estimated landing (ms) = take-off + the height-derived airtime. Stable — the
/// alt-bracket landingTimeMs is loose at sparse baro. Anchors ripeness + latency.
private func estLandingMsV9(_ j: JumpResultV8) -> Double {
    (j.takeoffTimeMs ?? 0) + j.airTimeSec * 1000
}
private func jumpArcLoV9(_ j: JumpResultV8) -> Double { j.takeoffTimeMs ?? 0 }
private func jumpArcHiV9(_ j: JumpResultV8) -> Double { estLandingMsV9(j) }
private func arcsOverlapV9(_ aLo: Double, _ aHi: Double, _ bLo: Double, _ bHi: Double, _ margin: Double) -> Bool {
    aLo < bHi + margin && bLo < aHi + margin
}

private final class PendingJumpV9 {
    var id: Int
    var jump: JumpResultV8
    var seenAtMs: Double
    var provisionalEmitted = false
    var finalEmitted = false
    init(id: Int, jump: JumpResultV8, seenAtMs: Double) { self.id = id; self.jump = jump; self.seenAtMs = seenAtMs }
}

/// Stateful periodic scanner. One instance per session.
final class JumpScannerV9 {
    private var buf: [V8Sample] = []
    private var pending: [PendingJumpV9] = []
    private var finalizedArcs: [(lo: Double, hi: Double)] = []  // dedup across eviction
    private var nextId = 1
    private let params: JumpEngineV8Params
    private let cfg: ScanConfigV9
    private var lastTickMs = -Double.infinity

    init(_ params: JumpEngineV8Params = .default, _ cfg: ScanConfigV9 = .default) {
        self.params = params
        self.cfg = cfg
    }

    func addSample(_ s: V8Sample) { buf.append(s) }
    var bufferedSamples: Int { buf.count }
    func due(_ nowMs: Double) -> Bool { nowMs - lastTickMs >= cfg.tickSec * 1000 }

    /// Run ONE backward scan; returns this tick's emissions (provisional + final).
    func scan(_ nowMs: Double) -> [ScanEmissionV9] {
        lastTickMs = nowMs
        let winLo = nowMs - cfg.windowSec * 1000
        let lo = track(nowMs)

        var out: [ScanEmissionV9] = []
        let provMs = cfg.provisionalSettleSec * 1000
        let finMs = cfg.settleSec * 1000
        let dropGapMs = 8000.0
        for p in pending {
            let seenNow = p.seenAtMs == nowMs
            let age = nowMs - estLandingMsV9(p.jump)
            if seenNow && !p.provisionalEmitted && age >= provMs {
                p.provisionalEmitted = true
                out.append(emit(p, .provisional, nowMs, false))
            }
            if seenNow && !p.finalEmitted && age >= finMs {
                p.finalEmitted = true
                finalizedArcs.append((jumpArcLoV9(p.jump), jumpArcHiV9(p.jump)))
                out.append(emit(p, .final_, nowMs, false))
            }
        }
        // A pending about to be dropped that showed a PROVISIONAL but never
        // finalized is a truncated-edge false positive → tell the caller to
        // RETRACT the live jump it surfaced (before we drop it below).
        for p in pending where !p.finalEmitted && p.provisionalEmitted && nowMs - p.seenAtMs > dropGapMs {
            out.append(emit(p, .retracted, nowMs, false))
        }
        // drop: finalized pendings that left the window, OR un-finalized ones the
        // full baseline stopped detecting (truncated-edge false positives).
        pending = pending.filter { p in p.finalEmitted ? jumpArcHiV9(p.jump) >= winLo : nowMs - p.seenAtMs <= dropGapMs }
        if lo > 0 { buf.removeFirst(lo) }
        return out
    }

    /// Session end: a last detection pass, then emit a FINAL for every pending not
    /// yet finalized (best-effort), plus a provisional if it never landed in time.
    func flush(_ nowMs: Double) -> [ScanEmissionV9] {
        _ = track(nowMs)
        var out: [ScanEmissionV9] = []
        for p in pending {
            if !p.provisionalEmitted { p.provisionalEmitted = true; out.append(emit(p, .provisional, nowMs, true)) }
            if !p.finalEmitted { p.finalEmitted = true; finalizedArcs.append((jumpArcLoV9(p.jump), jumpArcHiV9(p.jump))); out.append(emit(p, .final_, nowMs, true)) }
        }
        return out
    }

    // ── internals ──────────────────────────────────────────────────────────────

    /// Detect jumps in the current window and track each as a pending (matched by
    /// arc overlap; latest measurement wins until finalized). Returns evict index.
    private func track(_ nowMs: Double) -> Int {
        let winLo = nowMs - cfg.windowSec * 1000
        let stableLo = winLo + params.baselineHalfWinSec * 1000
        let marginMs = cfg.dedupTolSec * 1000
        let (window, lo) = windowSince(winLo)
        for j in KitesurfJumpEngineV8.detectJumps(window, params) {
            guard let t0 = j.takeoffTimeMs else { continue }
            let apexMs = t0 + j.apexTimeSec * 1000
            if apexMs < stableLo { continue } // trailing-edge guard
            let aLo = jumpArcLoV9(j), aHi = jumpArcHiV9(j)
            if finalizedArcs.contains(where: { arcsOverlapV9($0.lo, $0.hi, aLo, aHi, marginMs) }) { continue }
            if let p = pending.first(where: { arcsOverlapV9(jumpArcLoV9($0.jump), jumpArcHiV9($0.jump), aLo, aHi, marginMs) }) {
                if !p.finalEmitted { p.jump = j }
                p.seenAtMs = nowMs
            } else {
                pending.append(PendingJumpV9(id: nextId, jump: j, seenAtMs: nowMs)); nextId += 1
            }
        }
        return lo
    }

    private func windowSince(_ winLo: Double) -> ([V8Sample], Int) {
        var lo = 0
        while lo < buf.count && buf[lo].t < winLo { lo += 1 }
        return (lo > 0 ? Array(buf[lo...]) : buf, lo)
    }

    private func emit(_ p: PendingJumpV9, _ stage: ScanStageV9, _ nowMs: Double, _ viaFlush: Bool) -> ScanEmissionV9 {
        ScanEmissionV9(jump: p.jump, stage: stage, id: p.id, emittedAtMs: nowMs,
                       emitLatencySec: ((nowMs - estLandingMsV9(p.jump)) / 1000 * 10).rounded() / 10, viaFlush: viaFlush)
    }
}
