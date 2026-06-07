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

        // Mock GPS that fires before each new sample — keeps state in RIDING.
        let gps = MockGPS(speed: opts.speed, detector: detector)

        // Drive samples through detector
        for sample in log.samples {
            gps.tickIfNeeded(at: sample.timestamp)
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
            jumps: replayJumps
        )

        // Print human-readable
        Reporter.printHuman(report, &stdout)

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
