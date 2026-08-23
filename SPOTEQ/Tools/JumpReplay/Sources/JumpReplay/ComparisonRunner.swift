//
//  ComparisonRunner.swift
//  JumpReplay
//
//  JumpComparisonRunner — replays each log through two engines (default
//  v10 vs v11) and emits a diff + quality report so we can compare the
//  current engine against the new offline-buffered engine on identical logs.
//
//  Prints a human summary and writes a machine-readable JSON report per log.
//

import Foundation

// MARK: - Report types (mirror the spec)

struct JumpSummaryReport: Codable {
    var startTime: Double
    var takeoffTime: Double
    var landingTime: Double
    var airTimeMs: Double
    var estimatedHeightMeters: Double?
    var distanceMeters: Double?
    var totalRotationDegrees: Double?
    var score: Double
    var confidence: Double
    var reasonCodes: [String]
}

struct ChangedJumpMetric: Codable {
    var takeoffTime: Double
    var metric: String
    var baseline: Double
    var candidate: Double
    var delta: Double
}

struct EngineJumpsReport: Codable {
    var engine: String
    var jumpCount: Int
    var jumps: [JumpSummaryReport]
}

struct QualityStatsReport: Codable {
    var averageScore: Double
    var weakCount: Int
    var validCount: Int
    var strongCount: Int
    var excellentCount: Int
}

struct JumpEngineComparisonReport: Codable {
    var logFileName: String
    var baseline: EngineJumpsReport
    var candidate: EngineJumpsReport
    var diff: Diff
    var qualityStats: QualityStatsReport
    var notes: [String]

    struct Diff: Codable {
        var addedByCandidate: [JumpSummaryReport]
        var removedByCandidate: [JumpSummaryReport]
        var changedMetrics: [ChangedJumpMetric]
    }
}

// MARK: - Runner

enum JumpComparisonRunner {

    /// Pairing tolerance (seconds) for matching baseline ↔ candidate jumps.
    static let pairToleranceSec = 3.0

    static func run(opts: CLIOptions, stdout: inout StdoutStream) -> Bool {
        var allOK = true
        var reports: [JumpEngineComparisonReport] = []

        for url in opts.inputs {
            do {
                let log = try Loader.load(url, forceFormat: opts.format)
                let baseline = runEngine(opts.compareBaseline, log: log, opts: opts)
                let candidate = runEngine(opts.compareCandidate, log: log, opts: opts)
                let report = buildReport(logName: url.lastPathComponent,
                                         baselineEngine: opts.compareBaseline,
                                         candidateEngine: opts.compareCandidate,
                                         baseline: baseline,
                                         candidate: candidate)
                reports.append(report)
                printSummary(report, &stdout)

                // Per-log JSON report.
                try FileManager.default.createDirectory(at: opts.outputDir, withIntermediateDirectories: true)
                let reportURL = opts.outputDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).compare.json")
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try enc.encode(report)
                try data.write(to: reportURL)
                print("→ wrote \(reportURL.path)", to: &stdout)
            } catch {
                fputs("error comparing \(url.lastPathComponent): \(error)\n", stderr)
                allOK = false
            }
        }

        // Aggregate JSON for all logs.
        if !reports.isEmpty {
            let aggURL = opts.outputDir.appendingPathComponent("engine_comparison_report.json")
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(reports) {
                try? data.write(to: aggURL)
                print("→ wrote \(aggURL.path) (\(reports.count) logs)", to: &stdout)
            }
        }
        return allOK
    }

    // MARK: Run one engine over one log

    private static func runEngine(_ engine: String, log: LoadedLog, opts: CLIOptions) -> [JumpSummaryReport] {
        let detector: JumpDetecting
        switch engine {
        case "v7":  detector = JumpDetector()
        case "v10": detector = JumpDetectorV10()
        case "v11", "v11-buffered": detector = JumpDetectorV11()
        case "v12", "v12-apple-sensor-fusion": detector = JumpDetectorV12()
        case "v13", "v13-pure": detector = JumpDetectorV13()
        default:
            fputs("unknown engine in comparison: \(engine)\n", stderr)
            return []
        }
        detector.synchronousAnalysis = true

        // Capture the rich v11 result when available so score/reasonCodes survive.
        var v11ByTakeoff: [Double: JumpResultV11] = [:]
        if let v11 = detector as? JumpDetectorV11 {
            v11.onJumpResultV11 = { r in
                if r.confidence >= 0.40 { v11ByTakeoff[round(r.takeoffTimeSeconds * 100) / 100] = r }
            }
        }

        var summaries: [JumpSummaryReport] = []
        var summaryIDs: [String] = []
        guard let base = log.samples.first?.timestamp else { return [] }
        func summary(for jump: Jump) -> JumpSummaryReport {
            let takeoff = jump.startTime.timeIntervalSince(base)
            let landing = jump.endTime.timeIntervalSince(base)
            let key = round(takeoff * 100) / 100
            let rich = v11ByTakeoff[key]
            return JumpSummaryReport(
                startTime: r3(takeoff),
                takeoffTime: r3(takeoff),
                landingTime: r3(landing),
                airTimeMs: r1(jump.airtime * 1000),
                estimatedHeightMeters: r2(jump.height),
                distanceMeters: r1(jump.jumpDistance),
                totalRotationDegrees: rich?.totalRotationDegrees ?? Double(jump.rotations) * 360,
                score: rich?.score ?? jump.confidence,
                confidence: r3(jump.confidence),
                reasonCodes: rich?.reasonCodes ?? []
            )
        }
        detector.onJumpDetected = { jump in
            summaries.append(summary(for: jump))
            summaryIDs.append(jump.id)
        }
        if let v12 = detector as? JumpDetectorV12 {
            v12.onJumpUpdated = { jump in
                if let idx = summaryIDs.firstIndex(of: jump.id) {
                    summaries[idx] = summary(for: jump)
                } else {
                    summaries.append(summary(for: jump))
                    summaryIDs.append(jump.id)
                }
            }
            v12.onJumpRetracted = { id in
                while let idx = summaryIDs.firstIndex(of: id) {
                    summaryIDs.remove(at: idx)
                    summaries.remove(at: idx)
                }
            }
        }

        detector.reset(mode: opts.mode)
        let hasLogSpeeds = !opts.noGPS && log.speeds.contains { ($0 ?? 0) > 0 }
        let gps = MockGPS(speed: opts.speed, detector: detector)
        for (idx, sample) in log.samples.enumerated() {
            if hasLogSpeeds, idx < log.speeds.count, let spd = log.speeds[idx] {
                detector.updateGPS(speed: spd, altitude: 0, latitude: 0, longitude: 0, course: -1, horizontalAccuracy: nil, timestamp: sample.timestamp)
            } else if !opts.noGPS {
                gps.tickIfNeeded(at: sample.timestamp)
            }
            detector.processSample(sample)
        }
        // Flush buffered/refined engines so the closing seconds are analysed.
        if engine.hasPrefix("v11") || engine.hasPrefix("v12") || engine.hasPrefix("v13") {
            for jump in detector.endSession() {
                summaries.append(summary(for: jump))
                summaryIDs.append(jump.id)
            }
        }
        return summaries.sorted { $0.takeoffTime < $1.takeoffTime }
    }

    // MARK: Build the diff report

    private static func buildReport(logName: String,
                                    baselineEngine: String,
                                    candidateEngine: String,
                                    baseline: [JumpSummaryReport],
                                    candidate: [JumpSummaryReport]) -> JumpEngineComparisonReport {
        // Greedy nearest-time pairing within tolerance.
        var candUsed = Array(repeating: false, count: candidate.count)
        var changed: [ChangedJumpMetric] = []
        var removed: [JumpSummaryReport] = []

        for b in baseline {
            var bestIdx = -1
            var bestDt = pairToleranceSec
            for (i, c) in candidate.enumerated() where !candUsed[i] {
                let dt = abs(c.takeoffTime - b.takeoffTime)
                if dt <= bestDt { bestDt = dt; bestIdx = i }
            }
            if bestIdx >= 0 {
                candUsed[bestIdx] = true
                let c = candidate[bestIdx]
                appendIfChanged(&changed, takeoff: c.takeoffTime, metric: "airTimeMs", b: b.airTimeMs, c: c.airTimeMs, eps: 50)
                appendIfChanged(&changed, takeoff: c.takeoffTime, metric: "heightMeters",
                                b: b.estimatedHeightMeters ?? 0, c: c.estimatedHeightMeters ?? 0, eps: 0.25)
                appendIfChanged(&changed, takeoff: c.takeoffTime, metric: "score", b: b.score, c: c.score, eps: 5)
            } else {
                removed.append(b)   // baseline had a jump the candidate dropped
            }
        }
        let added = candidate.enumerated().filter { !candUsed[$0.offset] }.map { $0.element }

        // Quality stats over the candidate jumps.
        let scores = candidate.map { $0.score }
        let avg = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
        let stats = QualityStatsReport(
            averageScore: r1(avg),
            weakCount: candidate.filter { $0.score < 60 }.count,
            validCount: candidate.filter { $0.score >= 60 && $0.score < 75 }.count,
            strongCount: candidate.filter { $0.score >= 75 && $0.score < 90 }.count,
            excellentCount: candidate.filter { $0.score >= 90 }.count
        )

        var notes: [String] = []
        if removed.count > 0 {
            notes.append("\(candidateEngine) removed \(removed.count) jump(s) the baseline accepted — likely false positives.")
        }
        if added.count > 0 {
            notes.append("\(candidateEngine) added \(added.count) jump(s) the baseline missed.")
        }
        if removed.isEmpty && added.isEmpty {
            notes.append("Both engines agree on jump count; see changedMetrics for metric drift.")
        }

        return JumpEngineComparisonReport(
            logFileName: logName,
            baseline: EngineJumpsReport(engine: baselineEngine, jumpCount: baseline.count, jumps: baseline),
            candidate: EngineJumpsReport(engine: candidateEngine, jumpCount: candidate.count, jumps: candidate),
            diff: .init(addedByCandidate: added, removedByCandidate: removed, changedMetrics: changed),
            qualityStats: stats,
            notes: notes
        )
    }

    private static func appendIfChanged(_ out: inout [ChangedJumpMetric], takeoff: Double, metric: String, b: Double, c: Double, eps: Double) {
        if abs(b - c) > eps {
            out.append(ChangedJumpMetric(takeoffTime: r3(takeoff), metric: metric, baseline: r2(b), candidate: r2(c), delta: r2(c - b)))
        }
    }

    private static func printSummary(_ r: JumpEngineComparisonReport, _ stdout: inout StdoutStream) {
        print("", to: &stdout)
        print("Log: \(r.logFileName)", to: &stdout)
        print("\(r.baseline.engine) jumps: \(r.baseline.jumpCount)", to: &stdout)
        print("\(r.candidate.engine) jumps: \(r.candidate.jumpCount)", to: &stdout)
        if !r.diff.removedByCandidate.isEmpty {
            print("Removed by \(r.candidate.engine): \(r.diff.removedByCandidate.count) likely false positive(s)", to: &stdout)
        }
        if !r.diff.addedByCandidate.isEmpty {
            print("Added by \(r.candidate.engine): \(r.diff.addedByCandidate.count) jump(s)", to: &stdout)
        }
        print(String(format: "Average %@ score: %.0f  (weak=%d valid=%d strong=%d excellent=%d)",
                     r.candidate.engine, r.qualityStats.averageScore,
                     r.qualityStats.weakCount, r.qualityStats.validCount,
                     r.qualityStats.strongCount, r.qualityStats.excellentCount), to: &stdout)
    }

    private static func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private static func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private static func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}
