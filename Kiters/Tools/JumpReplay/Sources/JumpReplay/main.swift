import Foundation

struct CLIOptions {
    var inputs: [URL] = []
    var format: SensorFormat? = nil
    var mode: DetectionMode = .standard
    var speed: Double = 8.0
    var bless: Bool = false
    var compare: Bool = false
    var outputDir: URL = URL(fileURLWithPath: "output", isDirectory: true)
    var expectedDir: URL = URL(fileURLWithPath: "expected", isDirectory: true)
    var verbose: Bool = false
    var silenceLogger: Bool = true
    var surfr: Bool = false
    var requireSurfrWindows: Bool = false
    var noGPS: Bool = false
}

func parseArgs() -> CLIOptions {
    var o = CLIOptions()
    var i = 1
    let argv = CommandLine.arguments
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--format":
            i += 1
            o.format = SensorFormat(rawValue: argv[i])
        case "--mode":
            i += 1
            o.mode = DetectionMode(rawValue: argv[i]) ?? .standard
        case "--speed":
            i += 1
            o.speed = Double(argv[i]) ?? 8.0
        case "--bless":
            o.bless = true
        case "--compare":
            o.compare = true
        case "--output":
            i += 1
            o.outputDir = URL(fileURLWithPath: argv[i], isDirectory: true)
        case "--expected":
            i += 1
            o.expectedDir = URL(fileURLWithPath: argv[i], isDirectory: true)
        case "-v", "--verbose":
            o.verbose = true
        case "--with-logger":
            o.silenceLogger = false
        case "--surfr":
            o.surfr = true
        case "--require-surfr-windows":
            o.surfr = true
            o.requireSurfrWindows = true
        case "--no-gps":
            o.noGPS = true
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            if a.hasPrefix("-") {
                fputs("unknown flag: \(a)\n", stderr)
                exit(2)
            }
            o.inputs.append(URL(fileURLWithPath: a))
        }
        i += 1
    }
    if o.inputs.isEmpty {
        printUsage()
        exit(2)
    }
    return o
}

func printUsage() {
    let usage = """
    JumpReplay — replay sensor logs through JumpDetector

    Usage: replay [options] <file.csv|file.json>...

    Options:
      --format <coreMotion|android>   Force input format (default: auto)
      --mode <standard|conservative|sensitive|custom>  Detection mode (default: standard)
      --speed <m/s>                   Mock GPS speed (default: 8.0)
      --output <dir>                  Output directory (default: ./output)
      --expected <dir>                Expected dir for comparison (default: ./expected)
      --bless                         Copy actual → expected after run
      --compare                       Compare actual to expected; exit 1 on mismatch
      --with-logger                   Enable SessionLogger CSV writes (default: silent)
      --surfr                         Print Surfr screenshot timing comparison
      --require-surfr-windows         Fail unless all 4 Surfr signal windows are present
      --no-gps                        Do not feed GPS/speed into the detector
      -v, --verbose                   Print sample-level events
      -h, --help                      Show this help
    """
    print(usage)
}

func runOne(url: URL, opts: CLIOptions, stdout: inout StdoutStream) throws -> Bool {
        let log = try Loader.load(url, forceFormat: opts.format)

        // Build detector
        let detector = JumpDetector()
        // Offline replay has no run loop to drain DispatchQueue.main, so run the
        // v7 analysis inline and deliver callbacks synchronously.
        detector.synchronousAnalysis = true
        var capturedJumps: [(Jump, Date)] = []
        detector.onJumpDetected = { jump in
            capturedJumps.append((jump, log.samples.first?.timestamp ?? jump.startTime))
        }

        // Track all attempted jumps (accepted + rejected) by inspecting state changes
        // The detector only fires onJumpDetected for accepted jumps.
        // For rejected jumps we'd need to introspect logs — skip for now.

        detector.reset(mode: opts.mode)

        // Prefer the on-device CSV speed column when present. Falling back to
        // MockGPS keeps older synthetic logs usable.
        let hasLogSpeeds = !opts.noGPS && log.speeds.contains { ($0 ?? 0) > 0 }

        // Mock GPS that fires before each new sample — keeps state in RIDING.
        let gps = MockGPS(speed: opts.speed, detector: detector)

        // Drive samples through detector
        for (idx, sample) in log.samples.enumerated() {
            if hasLogSpeeds, idx < log.speeds.count, let spd = log.speeds[idx] {
                detector.updateGPS(speed: spd, altitude: 0, latitude: 0, longitude: 0, timestamp: sample.timestamp)
            } else if !opts.noGPS {
                gps.tickIfNeeded(at: sample.timestamp)
            }
            detector.processSample(sample)
        }

        // Build report
        let firstT = log.samples.first?.timestamp ?? Date()
        let lastT = log.samples.last?.timestamp ?? firstT
        let durationSec = lastT.timeIntervalSince(firstT)
        let replayJumps = capturedJumps.enumerated().map { (i, pair) -> ReplayJump in
            let (j, base) = pair
            let baroUsed = (j.imuSamples.last?.pressure != nil)  // best-effort
            return ReplayJump(
                index: i,
                takeoffOffsetSec: j.startTime.timeIntervalSince(base),
                airtime: j.airtime,
                physicalAirtime: j.endTime.timeIntervalSince(j.startTime),
                height: j.height,
                heightSource: baroUsed ? "baro" : "kin",
                apexTime: j.apexTime,
                confidence: j.confidence,
                rotations: j.rotations,
                jumpDistance: j.jumpDistance,
                accepted: j.confidence >= 50
            )
        }

        let report = ReplayReport(
            file: url.lastPathComponent,
            format: log.format.rawValue,
            detectedRateHz: log.detectedRate,
            sampleCount: log.samples.count,
            durationSec: durationSec,
            mockSpeedMps: opts.speed,
            detectionMode: opts.mode.rawValue,
            jumps: replayJumps,
            surfrWindowMatches: opts.surfr ? makeSurfrWindowMatches(log: log, jumps: replayJumps) : nil
        )

        // Print human-readable
        Reporter.printHuman(report, &stdout)
        if opts.surfr {
            SurfrReference.printComparison(report, &stdout)
        }

        // Write actual JSON
        let actualURL = opts.outputDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).actual.json")
        try Reporter.writeJSON(report, to: actualURL)
        print("→ wrote \(actualURL.path)", to: &stdout)

        // Bless
        if opts.bless {
            let expectedURL = opts.expectedDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).expected.json")
            try FileManager.default.createDirectory(at: opts.expectedDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: expectedURL)
            try FileManager.default.copyItem(at: actualURL, to: expectedURL)
            print("→ blessed → \(expectedURL.path)", to: &stdout)
        }

        // Compare
        if opts.compare {
            let expectedURL = opts.expectedDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).expected.json")
            guard FileManager.default.fileExists(atPath: expectedURL.path) else {
                fputs("⚠ no expected file: \(expectedURL.path)\n", stderr)
                return false
            }
            let expected = try Reporter.readJSON(expectedURL)
            let (ok, fails) = Reporter.compare(actual: report, expected: expected)
            if ok {
                print("✓ matches expected", to: &stdout)
            } else {
                print("✗ mismatch:", to: &stdout)
                for f in fails { print("    - \(f)", to: &stdout) }
                return false
            }
        }

        if opts.requireSurfrWindows {
            let matches = report.surfrWindowMatches ?? []
            let ok = matches.count == SurfrReference.jumps.count && matches.allSatisfy(\.windowSignalAccepted)
            if ok {
                print("✓ Surfr signal windows present: \(matches.count)/\(SurfrReference.jumps.count)", to: &stdout)
            } else {
                print("✗ Surfr signal windows missing:", to: &stdout)
                for m in matches where !m.windowSignalAccepted {
                    print(String(format: "    - #%d ref=%.0fs event=%@ rawA=%.2fg rawG=%.2f spd=%.2f",
                                 m.index, m.referenceTimeSec,
                                 m.nearestEventTimeSec.map { String(format: "%.2fs", $0) } ?? "-",
                                 m.rawMaxAccelG, m.rawMaxGyro, m.rawMedianSpeedMS), to: &stdout)
                }
                return false
            }
        }

        return true
}

// MARK: - Top-level entry

let opts = parseArgs()
var allOK = true
var stdout = StdoutStream()
for url in opts.inputs {
    do {
        let ok = try runOne(url: url, opts: opts, stdout: &stdout)
        if !ok { allOK = false }
    } catch {
        fputs("error processing \(url.lastPathComponent): \(error)\n", stderr)
        allOK = false
    }
}
exit(allOK ? 0 : 1)

private func makeSurfrWindowMatches(log: LoadedLog, jumps: [ReplayJump]) -> [SurfrWindowMatch] {
    guard let first = log.samples.first?.timestamp else { return [] }
    let accepted = jumps.filter(\.accepted)
    return SurfrReference.jumps.map { ref in
        let nearbyEvents = log.events
            .map { event -> (Double, LoadedLogEvent) in
                (event.timestamp.timeIntervalSince(first), event)
            }
            .filter { abs($0.0 - ref.time) <= 20.0 }
            .filter { $0.1.message.contains("AIRBORNE") || $0.1.message.contains("JUMP ACCEPTED") }
        let nearestEvent = nearbyEvents.min { abs($0.0 - ref.time) < abs($1.0 - ref.time) }
        let nearestAccepted = accepted.min { abs($0.takeoffOffsetSec - ref.time) < abs($1.takeoffOffsetSec - ref.time) }

        let samples = log.samples.filter { sample in
            let t = sample.timestamp.timeIntervalSince(first)
            return t >= ref.time - 8.0 && t <= ref.time + 12.0
        }
        let maxAccel = samples.map(\.accelerationMagnitude).max() ?? 0
        let maxGyro = samples.map(\.rotationMagnitude).max() ?? 0
        let speeds = log.samples.enumerated().compactMap { idx, sample -> Double? in
            let t = sample.timestamp.timeIntervalSince(first)
            guard t >= ref.time - 8.0 && t <= ref.time + 12.0,
                  idx < log.speeds.count else { return nil }
            return log.speeds[idx]
        }

        return SurfrWindowMatch(
            index: ref.index,
            referenceTimeSec: ref.time,
            nearestEventTimeSec: nearestEvent?.0,
            nearestEventDeltaSec: nearestEvent.map { $0.0 - ref.time },
            nearestEvent: nearestEvent?.1.message,
            nearestAcceptedTimeSec: nearestAccepted?.takeoffOffsetSec,
            nearestAcceptedDeltaSec: nearestAccepted.map { $0.takeoffOffsetSec - ref.time },
            acceptedWithinTolerance: nearestAccepted.map { abs($0.takeoffOffsetSec - ref.time) <= 3.0 && $0.height >= 1.0 } ?? false,
            windowSignalAccepted: nearestEvent.map { abs($0.0 - ref.time) <= 10.0 } ?? false
                && maxAccel >= 1.5
                && maxGyro >= 2.0,
            rawMaxAccelG: rounded(maxAccel, places: 3),
            rawMaxGyro: rounded(maxGyro, places: 3),
            rawMedianSpeedMS: rounded(median(speeds), places: 3)
        )
    }
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count % 2 == 0 {
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
}

private func rounded(_ value: Double, places: Int) -> Double {
    let factor = pow(10.0, Double(places))
    return (value * factor).rounded() / factor
}
