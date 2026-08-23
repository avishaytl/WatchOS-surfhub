//
//  JumpEvaluationHarness.swift
//  JumpReplay
//
//  Evaluates v10 and v11 jump detection against Surfr/WOO ground-truth labels by
//  TIMESTAMP MATCHING (not jump count). Reports precision / recall / F1, error
//  statistics, candidates-per-real-jump, and a per-label forensic breakdown.
//
//  Usage:
//    JumpReplay --evaluate groundtruth/<log>.surfr.json --eval-tolerance normal <log.kslog>
//

import Foundation

// MARK: - Candidate model

struct EvalCandidate {
    let engine: String           // "v10" | "v11"
    let takeoffSec: Double
    let airtime: Double
    let height: Double
    let score: Double
    let accepted: Bool           // passed the engine's accept gate
    let reasonCodes: [String]
}

enum JumpEvaluationHarness {

    enum Tolerance: String {
        case strict, normal, loose
        var sec: Double { self == .strict ? 5 : (self == .normal ? 10 : 15) }
    }

    // MARK: - Entry

    static func run(log url: URL, labelsURL: URL, tolerance: Tolerance,
                    offsetSec: Double, opts: CLIOptions, stdout: inout StdoutStream) -> Bool {
        let labels: SurfrGroundTruthLabels
        do {
            labels = try SurfrGroundTruthLabelImporter.load(labelsURL, timeOffsetSec: offsetSec)
        } catch {
            fputs("could not load labels: \(error)\n", stderr); return false
        }
        let logged: LoadedLog
        do { logged = try Loader.load(url, forceFormat: opts.format) }
        catch { fputs("could not load log: \(error)\n", stderr); return false }

        // Run both engines.
        let v10 = runEngine("v10", log: logged, opts: opts)
        let (v11, v11raw, v11clusters) = runV11(log: logged, opts: opts)

        // Decoded samples for raw forensic windows.
        let samples = decode(logged)

        print("════════════════════════════════════════════════════════════", to: &stdout)
        print("Jump Evaluation — \(url.lastPathComponent)", to: &stdout)
        print("Ground truth: \(labels.jumps.count) labelled jumps  (sensorOnly=\(labels.sensorOnly))", to: &stdout)
        print("Tolerance: \(tolerance.rawValue) (±\(Int(tolerance.sec))s)   offset: \(Int(offsetSec))s", to: &stdout)
        print("Raw candidates: v10=\(v10.count)  v11(accepted)=\(v11.filter{$0.accepted}.count)  v11(raw)=\(v11raw.count)  v11(clusters)=\(v11clusters.count)", to: &stdout)
        print("════════════════════════════════════════════════════════════", to: &stdout)

        // Evaluate each engine's ACCEPTED detections.
        let m10 = evaluate(labels: labels.jumps, detections: v10.filter { $0.accepted }, tol: tolerance.sec)
        let m11 = evaluate(labels: labels.jumps, detections: v11.filter { $0.accepted }, tol: tolerance.sec)
        printMetrics("v10", m10, &stdout)
        printMetrics("v11", m11, &stdout)

        // Candidates per real jump (raw v11 candidates within tolerance of a label).
        let rawCands = v11raw.map { EvalCandidate(engine: "v11raw", takeoffSec: $0.takeoffTime,
                                                  airtime: $0.physics.airTimeSec, height: $0.physics.estimatedHeightMeters,
                                                  score: $0.score.total, accepted: $0.score.total >= 35,
                                                  reasonCodes: $0.score.reasonCodes) }
        let perJump = labels.jumps.map { lbl in rawCands.filter { abs($0.takeoffSec - lbl.elapsedSec) <= tolerance.sec }.count }
        let avgPerJump = perJump.isEmpty ? 0 : Double(perJump.reduce(0,+)) / Double(perJump.count)
        print(String(format: "v11 raw candidates per real jump: avg %.1f  (per label: %@)",
                     avgPerJump, perJump.map(String.init).joined(separator: ",")), to: &stdout)

        // Threshold sweep over v11 cluster winners (operating-point analysis).
        print("", to: &stdout)
        print("──────────── v11 ACCEPT-THRESHOLD SWEEP (cluster winners) ────────────", to: &stdout)
        print("score≥  TP FP FN  precision recall  F1", to: &stdout)
        var bestF1 = -1.0, bestThr = 0.0
        for thr in stride(from: 30.0, through: 70.0, by: 5.0) {
            let dets = v11clusters.filter { $0.winner.score.total >= thr }
                .map { EvalCandidate(engine: "v11", takeoffSec: $0.winner.takeoffTime,
                                     airtime: $0.winner.physics.airTimeSec, height: $0.winner.physics.estimatedHeightMeters,
                                     score: $0.winner.score.total, accepted: true, reasonCodes: []) }
            let m = evaluate(labels: labels.jumps, detections: dets, tol: tolerance.sec)
            if m.f1 > bestF1 { bestF1 = m.f1; bestThr = thr }
            print(String(format: "  %4.0f  %2d %2d %2d   %.2f    %.2f   %.2f%@",
                         thr, m.tp, m.fp, m.fn, m.precision, m.recall, m.f1,
                         (m.f1 == bestF1 ? "  ←" : "") as String), to: &stdout)
        }
        print(String(format: "best F1=%.2f at score≥%.0f", bestF1, bestThr), to: &stdout)

        // Forensic per-label report.
        print("", to: &stdout)
        print("──────────────── PER-LABEL FORENSICS ────────────────", to: &stdout)
        for lbl in labels.jumps {
            forensic(label: lbl, v10: v10, v11raw: v11raw, v11clusters: v11clusters,
                     samples: samples, tol: tolerance.sec, &stdout)
        }

        // Machine-readable JSON.
        writeJSON(url: url, labels: labels, m10: m10, m11: m11,
                  v11clusters: v11clusters, avgPerJump: avgPerJump, opts: opts, &stdout)

        return true
    }

    // MARK: - Metrics

    struct Metrics {
        var tp = 0, fp = 0, fn = 0
        var timeErr: [Double] = []
        var airErr: [Double] = []
        var heightErr: [Double] = []
        var precision: Double { tp + fp == 0 ? 0 : Double(tp) / Double(tp + fp) }
        var recall: Double { tp + fn == 0 ? 0 : Double(tp) / Double(tp + fn) }
        var f1: Double { precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall) }
    }

    private static func evaluate(labels: [SurfrLabel], detections: [EvalCandidate], tol: Double) -> Metrics {
        var m = Metrics()
        var used = Array(repeating: false, count: detections.count)
        for lbl in labels {
            var bestIdx = -1, bestDt = tol
            for (i, d) in detections.enumerated() where !used[i] {
                let dt = abs(d.takeoffSec - lbl.elapsedSec)
                if dt <= bestDt { bestDt = dt; bestIdx = i }
            }
            if bestIdx >= 0 {
                used[bestIdx] = true
                m.tp += 1
                m.timeErr.append(detections[bestIdx].takeoffSec - lbl.elapsedSec)
                if let a = lbl.airtime { m.airErr.append(detections[bestIdx].airtime - a) }
                if let h = lbl.height { m.heightErr.append(detections[bestIdx].height - h) }
            } else {
                m.fn += 1
            }
        }
        m.fp = used.filter { !$0 }.count
        return m
    }

    private static func printMetrics(_ name: String, _ m: Metrics, _ stdout: inout StdoutStream) {
        func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0,+)/Double(a.count) }
        func meanAbs(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.map{abs($0)}.reduce(0,+)/Double(a.count) }
        print(String(format: "%-4s  TP=%d FP=%d FN=%d  precision=%.2f recall=%.2f F1=%.2f",
                     (name as NSString).utf8String!, m.tp, m.fp, m.fn, m.precision, m.recall, m.f1), to: &stdout)
        print(String(format: "      avg timestamp err=%+.1fs (|%.1f|)  airtime err=%+.2fs  height err=%+.2fm",
                     mean(m.timeErr), meanAbs(m.timeErr), mean(m.airErr), mean(m.heightErr)), to: &stdout)
    }

    // MARK: - Forensics

    private static func forensic(label lbl: SurfrLabel, v10: [EvalCandidate],
                                 v11raw: [JumpRawCandidateV11], v11clusters: [JumpClusterV11],
                                 samples: [DecodedSample], tol: Double, _ stdout: inout StdoutStream) {
        let t = lbl.elapsedSec
        print(String(format: "\n● Surfr #%d  t=%.0fs  h=%.2fm air=%.2fs dist=%@m",
                     lbl.id, t, lbl.height ?? 0, lbl.airtime ?? 0,
                     lbl.distance.map { String(Int($0)) } ?? "-"), to: &stdout)

        // closest v10 within ±20s
        let near10 = v10.filter { abs($0.takeoffSec - t) <= 20 }.sorted { abs($0.takeoffSec-t) < abs($1.takeoffSec-t) }
        print("   v10 nearby: " + (near10.isEmpty ? "none" :
              near10.prefix(4).map { String(format: "t=%.0f(%+.0fs h%.1f)", $0.takeoffSec, $0.takeoffSec-t, $0.height) }.joined(separator: "  ")), to: &stdout)

        // closest v11 raw candidates within ±20s
        let near11 = v11raw.filter { abs($0.takeoffTime - t) <= 20 }.sorted { abs($0.takeoffTime-t) < abs($1.takeoffTime-t) }
        print("   v11 raw:    " + (near11.isEmpty ? "none" :
              near11.prefix(5).map {
                  String(format: "t=%.0f(%+.0f sc%.0f h%.2f %@ i%@ q%.2f)",
                         $0.takeoffTime, $0.takeoffTime-t, $0.score.total,
                         $0.physics.estimatedHeightMeters,
                         $0.physics.heightSource.rawValue,
                         $0.physics.inertialHeightMeters.map { String(format: "%.2f", $0) } ?? "nil",
                         $0.physics.inertialQuality)
              }.joined(separator: "  ")), to: &stdout)

        // cluster winner covering this label
        if let cl = v11clusters.filter({ abs($0.winner.takeoffTime - t) <= tol }).min(by: { abs($0.winner.takeoffTime-t) < abs($1.winner.takeoffTime-t) }) {
            let w = cl.winner
            let dec = w.score.total >= 35 ? "ACCEPTED" : "rejected"
            print(String(format: "   ✓ cluster winner t=%.0f(%+.0fs) score=%.0f %@  h=%.2fm(%@) air=%.2fs baroH=%@ bq=%.2f inertialH=%@ iq=%.2f",
                         w.takeoffTime, w.takeoffTime-t, w.score.total, dec,
                         w.physics.estimatedHeightMeters, w.physics.heightSource.rawValue,
                         w.physics.airTimeSec,
                         w.physics.baroHeightMeters.map { String(format:"%.2f", $0) } ?? "nil",
                         w.physics.baroQuality,
                         w.physics.inertialHeightMeters.map { String(format:"%.2f", $0) } ?? "nil",
                         w.physics.inertialQuality), to: &stdout)
            print("     reasons: " + w.score.reasonCodes.joined(separator: ","), to: &stdout)
            if !cl.suppressed.isEmpty {
                print("     suppressed: " + cl.suppressed.prefix(4).map { String(format:"t=%.0f(sc%.0f)", $0.takeoffTime, $0.score.total) }.joined(separator: "  "), to: &stdout)
            }
        } else {
            print("   ✗ no v11 cluster winner within ±\(Int(tol))s — MISSED", to: &stdout)
        }

        // raw sensor metrics in ±20s
        let win = samples.filter { abs($0.t - t) <= 20 }
        if let mr = rawWindowStats(win, baseline: samples.filter { $0.t >= t-25 && $0.t <= t-10 }) {
            print(String(format: "   raw ±20s: maxAccel=%.1fg maxRot=%.1f baroDrop=%.3fhPa(~%.2fm) speed=%.1f",
                         mr.maxAccel, mr.maxRot, mr.baroDrop, mr.baroDrop * 8.43, mr.maxSpeed), to: &stdout)
        }
    }

    private struct RawStats { let maxAccel, maxRot, baroDrop, maxSpeed: Double }
    private static func rawWindowStats(_ w: [DecodedSample], baseline: [DecodedSample]) -> RawStats? {
        guard !w.isEmpty else { return nil }
        let baseBaro = baseline.compactMap { $0.baro }.sorted()
        let base = baseBaro.isEmpty ? nil : baseBaro[baseBaro.count/2]
        let minBaro = w.compactMap { $0.baro }.min()
        let drop = (base != nil && minBaro != nil) ? max(0, base! - minBaro!) : 0
        return RawStats(maxAccel: w.map{$0.accel}.max() ?? 0,
                        maxRot: w.map{$0.rot}.max() ?? 0,
                        baroDrop: drop,
                        maxSpeed: w.map{$0.speed}.max() ?? 0)
    }

    // MARK: - Engine drivers

    private static func runEngine(_ engine: String, log: LoadedLog, opts: CLIOptions) -> [EvalCandidate] {
        let detector: JumpDetecting = engine == "v10" ? JumpDetectorV10() : JumpDetector()
        detector.synchronousAnalysis = true
        guard let base = log.samples.first?.timestamp else { return [] }
        var out: [EvalCandidate] = []
        detector.onJumpDetected = { j in
            out.append(EvalCandidate(engine: engine, takeoffSec: j.startTime.timeIntervalSince(base),
                                     airtime: j.airtime, height: j.height, score: j.confidence,
                                     accepted: j.confidence >= 50, reasonCodes: []))
        }
        drive(detector, log: log, opts: opts)
        return out.sorted { $0.takeoffSec < $1.takeoffSec }
    }

    private static func runV11(log: LoadedLog, opts: CLIOptions)
        -> ([EvalCandidate], [JumpRawCandidateV11], [JumpClusterV11]) {
        let d = JumpDetectorV11()
        d.synchronousAnalysis = true
        guard let base = log.samples.first?.timestamp else { return ([], [], []) }
        var out: [EvalCandidate] = []
        var rich: [Double: JumpResultV11] = [:]
        d.onJumpResultV11 = { r in rich[round(r.takeoffTimeSeconds*100)/100] = r }
        d.onJumpDetected = { j in
            let to = j.startTime.timeIntervalSince(base)
            let r = rich[round(to*100)/100]
            out.append(EvalCandidate(engine: "v11", takeoffSec: to, airtime: j.airtime, height: j.height,
                                     score: r?.score ?? j.confidence, accepted: true,
                                     reasonCodes: r?.reasonCodes ?? []))
        }
        drive(d, log: log, opts: opts)
        _ = d.endSession()
        // Shift raw-candidate / cluster times into elapsed-seconds-from-first-sample
        // (they are already monotonic from session start = first sample) → same base.
        return (out.sorted { $0.takeoffSec < $1.takeoffSec }, d.rawCandidates, d.clusters)
    }

    private static func drive(_ detector: JumpDetecting, log: LoadedLog, opts: CLIOptions) {
        detector.reset(mode: opts.mode)
        let hasLogSpeeds = !opts.noGPS && log.speeds.contains { ($0 ?? 0) > 0 }
        let gps = MockGPS(speed: opts.speed, detector: detector)
        for (idx, s) in log.samples.enumerated() {
            if hasLogSpeeds, idx < log.speeds.count, let spd = log.speeds[idx] {
                detector.updateGPS(speed: spd, altitude: 0, latitude: 0, longitude: 0, course: -1, horizontalAccuracy: nil, timestamp: s.timestamp)
            } else if !opts.noGPS {
                gps.tickIfNeeded(at: s.timestamp)
            }
            detector.processSample(s)
        }
    }

    // MARK: - Decoded samples (forensics)

    struct DecodedSample { let t, accel, rot, speed: Double; let baro: Double? }
    private static func decode(_ log: LoadedLog) -> [DecodedSample] {
        guard let base = log.samples.first?.timestamp else { return [] }
        return log.samples.enumerated().map { idx, s in
            DecodedSample(t: s.timestamp.timeIntervalSince(base),
                          accel: s.accelerationMagnitude, rot: s.rotationMagnitude,
                          speed: (idx < log.speeds.count ? log.speeds[idx] : nil) ?? 0,
                          baro: s.pressure)
        }
    }

    // MARK: - JSON report

    private static func writeJSON(url: URL, labels: SurfrGroundTruthLabels,
                                  m10: Metrics, m11: Metrics, v11clusters: [JumpClusterV11],
                                  avgPerJump: Double, opts: CLIOptions, _ stdout: inout StdoutStream) {
        struct EngineMetrics: Codable { var tp, fp, fn: Int; var precision, recall, f1: Double }
        struct Report: Codable {
            var log: String; var labels: Int
            var v10: EngineMetrics; var v11: EngineMetrics
            var v11Clusters: Int; var avgCandidatesPerJump: Double
        }
        func em(_ m: Metrics) -> EngineMetrics {
            EngineMetrics(tp: m.tp, fp: m.fp, fn: m.fn,
                          precision: (m.precision*100).rounded()/100,
                          recall: (m.recall*100).rounded()/100,
                          f1: (m.f1*100).rounded()/100)
        }
        let rep = Report(log: url.lastPathComponent, labels: labels.jumps.count,
                         v10: em(m10), v11: em(m11), v11Clusters: v11clusters.count,
                         avgCandidatesPerJump: (avgPerJump*10).rounded()/10)
        try? FileManager.default.createDirectory(at: opts.outputDir, withIntermediateDirectories: true)
        let out = opts.outputDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).eval.json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(rep) { try? data.write(to: out); print("\n→ wrote \(out.path)", to: &stdout) }
    }
}
