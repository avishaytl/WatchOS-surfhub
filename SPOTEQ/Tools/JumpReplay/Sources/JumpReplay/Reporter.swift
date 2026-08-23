import Foundation

struct ReplayJump: Codable {
    let index: Int
    let takeoffOffsetSec: Double  // seconds from first sample
    let airtime: Double?
    let physicalAirtime: Double?
    let height: Double
    let heightSource: String  // "baro" or "kin"
    let apexTime: Double?
    let confidence: Double
    let rotations: Int
    let jumpDistance: Double?
    let gpsVerified: Bool?
    let takeoffGroundSpeed: Double?
    let accepted: Bool
}

struct ReplayReport: Codable {
    let file: String
    let format: String
    let engineVersion: String?
    let detectedRateHz: Double
    let sampleCount: Int
    let durationSec: Double
    let mockSpeedMps: Double
    let detectionMode: String
    let jumps: [ReplayJump]
    let surfrWindowMatches: [SurfrWindowMatch]?
}

struct SurfrWindowMatch: Codable {
    let index: Int
    let referenceTimeSec: Double
    let referenceHeightM: Double
    let referenceAirtimeSec: Double
    let nearestEventTimeSec: Double?
    let nearestEventDeltaSec: Double?
    let nearestEvent: String?
    let nearestAcceptedTimeSec: Double?
    let nearestAcceptedDeltaSec: Double?
    let nearestAcceptedHeightM: Double?
    let nearestAcceptedHeightDeltaM: Double?
    let nearestAcceptedAirtimeSec: Double?
    let nearestAcceptedAirtimeDeltaSec: Double?
    let acceptedWithinTolerance: Bool
    let windowSignalAccepted: Bool
    let rawMaxAccelG: Double
    let rawMaxGyro: Double
    let rawMedianSpeedMS: Double
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
        if let engineVersion = report.engineVersion {
            print("Engine:  \(engineVersion)", to: &s)
        }
        print("Format:  \(report.format)  rate=\(String(format: "%.1f", report.detectedRateHz)) Hz  samples=\(report.sampleCount)  dur=\(String(format: "%.1f", report.durationSec))s", to: &s)
        print("Mode:    \(report.detectionMode)  mockSpeed=\(String(format: "%.1f", report.mockSpeedMps)) m/s", to: &s)
        print("Jumps:   \(report.jumps.count) (accepted=\(report.jumps.filter { $0.accepted }.count))", to: &s)
        if report.jumps.isEmpty {
            print("  (no jumps detected)", to: &s)
        } else {
            for j in report.jumps {
                let apex = j.apexTime.map { String(format: "%.2fs", $0) } ?? "—"
                let mark = j.accepted ? "✓" : "✗"
                let airtime = j.airtime.map { String(format: "%.2fs", $0) } ?? "—"
                let physicalAirtime = j.physicalAirtime.map { String(format: "%.2fs", $0) } ?? "—"
                let distance = j.jumpDistance.map { String(format: "%.1fm", $0) } ?? "—"
                let gps: String
                if let verified = j.gpsVerified {
                    let speed = j.takeoffGroundSpeed
                        .map { String(format: "%.2fm/s", $0) } ?? "no-fix"
                    gps = " gps=\(verified ? "✓" : "✗")(\(speed))"
                } else {
                    gps = ""
                }
                let summary = String(format: "  [%@] #%d  t=%.2fs  air=%@ phys=%@  h=%.2fm(%@)  dist=%@  apex=%@  conf=%d  rot=%d",
                                     mark, j.index, j.takeoffOffsetSec, airtime, physicalAirtime,
                                     j.height, j.heightSource, distance, apex, Int(j.confidence), j.rotations)
                print(summary + gps, to: &s)
            }
        }
        if let matches = report.surfrWindowMatches, !matches.isEmpty {
            print("Surfr windows:", to: &s)
            for m in matches {
                let event = m.nearestEventTimeSec.map { String(format: "%.2fs", $0) } ?? "-"
                let accepted = m.nearestAcceptedTimeSec.map { String(format: "%.2fs", $0) } ?? "-"
                let acceptedDt = m.nearestAcceptedDeltaSec.map { String(format: "%+.2fs", $0) } ?? "-"
                let mark = m.windowSignalAccepted ? "✓" : "✗"
                let v7 = m.acceptedWithinTolerance ? "v7✓" : "v7✗"
                let height = m.nearestAcceptedHeightM.map { String(format: "%.2f/%.2fm", m.referenceHeightM, $0) } ?? "-"
                let heightDt = m.nearestAcceptedHeightDeltaM.map { String(format: "%+.2fm", $0) } ?? "-"
                let airtime = m.nearestAcceptedAirtimeSec.map { String(format: "%.2f/%.2fs", m.referenceAirtimeSec, $0) } ?? "-"
                print(String(format: "  [%@] #%d ref=%.0fs event=%@ accepted=%@ dt=%@ %@ h=%@ dh=%@ air=%@ rawA=%.2fg rawG=%.2f spd=%.2f",
                             mark, m.index, m.referenceTimeSec, event, accepted, acceptedDt,
                             v7, height, heightDt, airtime, m.rawMaxAccelG, m.rawMaxGyro, m.rawMedianSpeedMS), to: &s)
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
            switch (a.airtime, e.airtime) {
            case let (actual?, expected?):
                if abs(actual - expected) > tol.airtimeAbs {
                    fails.append("jump#\(i) airtime: \(actual) vs \(expected) (±\(tol.airtimeAbs))")
                }
            case (nil, nil):
                break
            default:
                fails.append("jump#\(i) airtime availability: \(String(describing: a.airtime)) vs \(String(describing: e.airtime))")
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
        print("Surfr reference comparison:", to: &s)
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
            let dh = j.height - ref.height
            let da = j.airtime.map { $0 - ref.airtime }
            let dd = j.jumpDistance.map { $0 - ref.distance }
            let airtime = j.airtime.map { String(format: "%.2fs", $0) } ?? "—"
            let airtimeDelta = da.map { String(format: "%+.2fs", $0) } ?? "—"
            let distance = j.jumpDistance.map { String(format: "%.1fm", $0) } ?? "—"
            let distanceDelta = dd.map { String(format: "%+.1fm", $0) } ?? "—"
            residuals.append(abs(dt))
            let prefix = String(format: "  #%d Surfr %.0fs -> ours %.2fs  dt=%+.2fs  h=%.2f/%.2fm dh=%+.2fm",
                         ref.index, ref.time, j.takeoffOffsetSec, dt,
                         ref.height, j.height, dh)
            print(prefix + "  air=\(String(format: "%.2fs", ref.airtime))/\(airtime) da=\(airtimeDelta)"
                + "  dist=\(String(format: "%.0fm", ref.distance))/\(distance) dd=\(distanceDelta)", to: &s)
        }
        let extras = max(0, accepted.count - jumps.count)
        let pass = residuals.count == jumps.count && residuals.allSatisfy { $0 <= 3.0 }
        print("  timing: \(pass ? "PASS" : "FAIL")  accepted=\(accepted.count) extras=\(extras) maxAbsDt=\(String(format: "%.2f", residuals.max() ?? 0))s", to: &s)
    }

    struct Tolerances {
        let timeSec: Double
        let heightM: Double
        let airtimeSec: Double
        let distanceM: Double
    }

    struct CheckResult {
        let ok: Bool
        let lines: [String]
    }

    static func check(report: ReplayReport, tolerances: Tolerances, allowExtraJumps: Bool) -> CheckResult {
        let accepted = report.jumps.filter(\.accepted)
        var lines: [String] = [
            String(format: "tolerances: time=±%.2fs height=±%.2fm airtime=±%.2fs distance=±%.1fm",
                   tolerances.timeSec,
                   tolerances.heightM,
                   tolerances.airtimeSec,
                   tolerances.distanceM)
        ]
        guard !accepted.isEmpty else {
            return CheckResult(ok: false, lines: lines + ["FAIL no accepted jumps"])
        }

        var ok = true
        var usedAcceptedIndexes = Set<Int>()

        for ref in jumps {
            let candidates = accepted.enumerated().filter { !usedAcceptedIndexes.contains($0.offset) }
            guard let best = candidates.min(by: {
                abs($0.element.takeoffOffsetSec - ref.time) < abs($1.element.takeoffOffsetSec - ref.time)
            }) else {
                lines.append(String(format: "FAIL #%d missing accepted jump near %.0fs", ref.index, ref.time))
                ok = false
                continue
            }

            usedAcceptedIndexes.insert(best.offset)
            let j = best.element
            let dt = j.takeoffOffsetSec - ref.time
            let dh = j.height - ref.height
            let da = j.airtime.map { $0 - ref.airtime }
            let dd = j.jumpDistance.map { $0 - ref.distance }
            var failures: [String] = []

            if abs(dt) > tolerances.timeSec {
                failures.append(String(format: "dt=%+.2fs", dt))
            }
            if abs(dh) > tolerances.heightM {
                failures.append(String(format: "dh=%+.2fm", dh))
            }
            if let da {
                if abs(da) > tolerances.airtimeSec {
                    failures.append(String(format: "da=%+.2fs", da))
                }
            } else {
                failures.append("air=n/a")
            }
            if let dd {
                if abs(dd) > tolerances.distanceM {
                    failures.append(String(format: "dd=%+.1fm", dd))
                }
            } else {
                failures.append("dist=n/a")
            }

            let prefix = failures.isEmpty ? "PASS" : "FAIL"
            if !failures.isEmpty { ok = false }
            let actualAir = j.airtime.map { String(format: "%.2fs", $0) } ?? "—"
            let actualDistance = j.jumpDistance.map { String(format: "%.1fm", $0) } ?? "—"
            lines.append(String(format: "%@ #%d ref t=%.0fs h=%.2fm air=%.2fs dist=%.0fm -> actual t=%.2fs h=%.2fm air=%@ dist=%@%@",
                                prefix,
                                ref.index,
                                ref.time,
                                ref.height,
                                ref.airtime,
                                ref.distance,
                                j.takeoffOffsetSec,
                                j.height,
                                actualAir,
                                actualDistance,
                                failures.isEmpty ? "" : " (" + failures.joined(separator: ", ") + ")"))
        }

        let extraJumps = accepted.filter { jump in
            jumps.allSatisfy { ref in
                abs(jump.takeoffOffsetSec - ref.time) > tolerances.timeSec
            }
        }
        if !allowExtraJumps && !extraJumps.isEmpty {
            ok = false
            let extras = extraJumps.map {
                String(format: "#%d@%.2fs", $0.index, $0.takeoffOffsetSec)
            }.joined(separator: ", ")
            lines.append("FAIL extra accepted jumps: \(extras)")
        } else if allowExtraJumps && !extraJumps.isEmpty {
            let extras = extraJumps.map {
                String(format: "#%d@%.2fs", $0.index, $0.takeoffOffsetSec)
            }.joined(separator: ", ")
            lines.append("INFO extra accepted jumps ignored: \(extras)")
        }

        return CheckResult(ok: ok, lines: lines)
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
