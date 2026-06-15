import Foundation

struct ReplayJump: Codable {
    let index: Int
    let takeoffOffsetSec: Double  // seconds from first sample
    let airtime: Double
    let physicalAirtime: Double?
    let height: Double
    let heightSource: String  // "baro" or "kin"
    let apexTime: Double?
    let confidence: Double
    let rotations: Int
    let jumpDistance: Double
    let accepted: Bool
}

struct ReplayReport: Codable {
    let file: String
    let format: String
    let detectedRateHz: Double
    let sampleCount: Int
    let durationSec: Double
    let mockSpeedMps: Double
    let detectionMode: String
    let jumps: [ReplayJump]
}

enum Reporter {
    static func writeJSON(_ report: ReplayReport, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(report)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    static func readJSON(_ url: URL) throws -> ReplayReport {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ReplayReport.self, from: data)
    }

    static func printHuman<S: TextOutputStream>(_ report: ReplayReport, _ s: inout S) {
        print("════════════════════════════════════════════════", to: &s)
        print("File:    \(report.file)", to: &s)
        print("Format:  \(report.format)  rate=\(String(format: "%.1f", report.detectedRateHz)) Hz  samples=\(report.sampleCount)  dur=\(String(format: "%.1f", report.durationSec))s", to: &s)
        print("Mode:    \(report.detectionMode)  mockSpeed=\(String(format: "%.1f", report.mockSpeedMps)) m/s", to: &s)
        print("Jumps:   \(report.jumps.count) (accepted=\(report.jumps.filter { $0.accepted }.count))", to: &s)
        if report.jumps.isEmpty {
            print("  (no jumps detected)", to: &s)
        } else {
            for j in report.jumps {
                let apex = j.apexTime.map { String(format: "%.2f", $0) } ?? "-"
                let mark = j.accepted ? "✓" : "✗"
                print(String(format: "  [%@] #%d  t=%.2fs  air=%.2fs phys=%.2fs  h=%.2fm(%@)  apex=%@s  conf=%d  rot=%d",
                             mark, j.index, j.takeoffOffsetSec, j.airtime, j.physicalAirtime ?? j.airtime,
                             j.height, j.heightSource, apex, Int(j.confidence), j.rotations), to: &s)
            }
        }
        print("════════════════════════════════════════════════", to: &s)
    }

    /// Compare actual vs expected. Returns (passed, failureReasons).
    struct Tolerance {
        let airtimeAbs: Double = 0.2
        let heightRel: Double = 0.15
        let apexAbs: Double = 0.3
    }

    static func compare(actual: ReplayReport, expected: ReplayReport,
                        tol: Tolerance = .init()) -> (Bool, [String]) {
        var fails: [String] = []
        if actual.jumps.count != expected.jumps.count {
            fails.append("jump count: actual=\(actual.jumps.count) expected=\(expected.jumps.count)")
        }
        for (i, e) in expected.jumps.enumerated() {
            guard i < actual.jumps.count else { break }
            let a = actual.jumps[i]
            if abs(a.airtime - e.airtime) > tol.airtimeAbs {
                fails.append("jump#\(i) airtime: \(a.airtime) vs \(e.airtime) (±\(tol.airtimeAbs))")
            }
            if e.height > 0 {
                let rel = abs(a.height - e.height) / e.height
                if rel > tol.heightRel {
                    fails.append("jump#\(i) height: \(a.height) vs \(e.height) (±\(Int(tol.heightRel*100))%)")
                }
            }
            if let ea = e.apexTime, let aa = a.apexTime {
                if abs(aa - ea) > tol.apexAbs {
                    fails.append("jump#\(i) apex: \(aa) vs \(ea) (±\(tol.apexAbs))")
                }
            }
            if a.accepted != e.accepted {
                fails.append("jump#\(i) acceptance: \(a.accepted) vs \(e.accepted)")
            }
        }
        return (fails.isEmpty, fails)
    }
}

enum SurfrReference {
    struct Ref {
        let index: Int
        let time: Double
        let height: Double
        let airtime: Double
        let distance: Double
    }

    static let jumps: [Ref] = [
        Ref(index: 1, time: 558, height: 3.17, airtime: 4.59, distance: 7),
        Ref(index: 2, time: 735, height: 3.45, airtime: 4.12, distance: 24),
        Ref(index: 3, time: 958, height: 3.14, airtime: 4.37, distance: 10),
        Ref(index: 4, time: 1333, height: 3.77, airtime: 4.33, distance: 20),
    ]

    static func printComparison<S: TextOutputStream>(_ report: ReplayReport, _ s: inout S) {
        let accepted = report.jumps.filter(\.accepted)
        print("Surfr reference timing:", to: &s)
        guard !accepted.isEmpty else {
            print("  no accepted jumps to compare", to: &s)
            return
        }
        var matched = Set<Int>()
        var residuals: [Double] = []
        for ref in jumps {
            let candidates = accepted.enumerated().filter { !matched.contains($0.offset) }
            guard let best = candidates.min(by: {
                abs($0.element.takeoffOffsetSec - ref.time) < abs($1.element.takeoffOffsetSec - ref.time)
            }) else { continue }
            matched.insert(best.offset)
            let j = best.element
            let dt = j.takeoffOffsetSec - ref.time
            residuals.append(abs(dt))
            print(String(format: "  #%d Surfr %.0fs -> ours %.2fs  dt=%+.2fs  h=%.2f/%.2fm  air=%.2f/%.2fs",
                         ref.index, ref.time, j.takeoffOffsetSec, dt,
                         ref.height, j.height, ref.airtime, j.airtime), to: &s)
        }
        let extras = max(0, accepted.count - jumps.count)
        let pass = accepted.count == jumps.count && residuals.count == jumps.count && residuals.allSatisfy { $0 <= 3.0 }
        print("  result: \(pass ? "PASS" : "FAIL")  accepted=\(accepted.count) extras=\(extras) maxAbsDt=\(String(format: "%.2f", residuals.max() ?? 0))s", to: &s)
    }
}

struct StderrStream: TextOutputStream {
    mutating func write(_ s: String) {
        FileHandle.standardError.write(s.data(using: .utf8) ?? Data())
    }
}

struct StdoutStream: TextOutputStream {
    mutating func write(_ s: String) {
        FileHandle.standardOutput.write(s.data(using: .utf8) ?? Data())
    }
}
