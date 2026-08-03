import Foundation

struct CLIOptions {
    var inputs: [URL] = []
    var format: SensorFormat? = nil
    var engine: String = "v7"          // "v7"/"v10" streaming, "v8" batch, or "v9" direct session
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
    var requireSurfrReference: Bool = false
    var allowSurfrExtraJumps: Bool = false
    var surfrTimeToleranceSec: Double = 3.0
    var surfrHeightToleranceM: Double = 0.75
    var surfrAirtimeToleranceSec: Double = 0.50
    var surfrDistanceToleranceM: Double = 10.0
    var noGPS: Bool = false
    var noThrows: Bool = false         // v8: disable the ballistic throw path
    var compareEngines: Bool = false   // run v10 + v11 and emit a diff report
    var compareBaseline: String = "v10"
    var compareCandidate: String = "v11"
    var v11SelfTest: Bool = false      // run v11 unit assertions and exit
    var engineE2ESelfTest: Bool = false // run watch-adapter E2E assertions and exit
    var v11Debug: Bool = false         // write v11 accepted/rejected segment debug JSON
    var dumpSamples: String? = nil     // write decoded per-sample CSV and exit
    var dumpEvents: String? = nil      // write decoded event records CSV and exit
    var dumpV13Audit: String? = nil    // write structured V13 audit JSON and exit
    var evaluateLabels: String? = nil  // Surfr ground-truth JSON → evaluation harness
    var evalTolerance: String = "normal" // strict|normal|loose
    var evalOffsetSec: Double = 0      // shift ground-truth times to align with the log
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
        case "--engine":
            i += 1
            o.engine = argv[i].lowercased()
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
        case "--require-surfr-reference":
            o.surfr = true
            o.requireSurfrReference = true
        case "--allow-surfr-extra-jumps":
            o.allowSurfrExtraJumps = true
        case "--surfr-time-tolerance":
            i += 1
            o.surfrTimeToleranceSec = Double(argv[i]) ?? o.surfrTimeToleranceSec
        case "--surfr-height-tolerance":
            i += 1
            o.surfrHeightToleranceM = Double(argv[i]) ?? o.surfrHeightToleranceM
        case "--surfr-airtime-tolerance":
            i += 1
            o.surfrAirtimeToleranceSec = Double(argv[i]) ?? o.surfrAirtimeToleranceSec
        case "--surfr-distance-tolerance":
            i += 1
            o.surfrDistanceToleranceM = Double(argv[i]) ?? o.surfrDistanceToleranceM
        case "--no-gps":
            o.noGPS = true
        case "--no-throws":
            o.noThrows = true
        case "--compare-engines":
            o.compareEngines = true
        case "--compare-baseline":
            i += 1
            o.compareBaseline = argv[i].lowercased()
        case "--compare-candidate":
            i += 1
            o.compareCandidate = argv[i].lowercased()
        case "--v11-selftest":
            o.v11SelfTest = true
        case "--engine-e2e-selftest":
            o.engineE2ESelfTest = true
        case "--v11-debug":
            o.v11Debug = true
        case "--dump-samples":
            i += 1
            o.dumpSamples = argv[i]
        case "--dump-events":
            i += 1
            o.dumpEvents = argv[i]
        case "--dump-v13-audit":
            i += 1
            o.dumpV13Audit = argv[i]
        case "--evaluate":
            i += 1
            o.evaluateLabels = argv[i]
        case "--eval-tolerance":
            i += 1
            o.evalTolerance = argv[i].lowercased()
        case "--eval-offset":
            i += 1
            o.evalOffsetSec = Double(argv[i]) ?? 0
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
    if o.inputs.isEmpty && !o.v11SelfTest && !o.engineE2ESelfTest {
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
      --engine <v7|v8|v10|v11|v12|v13|v14|v15|v16>  Jump engine (default: v7). v16 = isolated big-air world-Z lift shelf + fixed-window IMU matched filter; barometer ignored, GPS metrics only.
      --compare-engines               Run two engines (default v10 vs v11) over each log and emit a diff + quality report.
      --compare-baseline <eng>        Baseline engine for --compare-engines (default: v10).
      --compare-candidate <eng>       Candidate engine for --compare-engines (default: v11).
      --v11-debug                     Write v11 accepted/rejected segment debug JSON alongside the report.
      --v11-selftest                  Run v11 core-calculation unit tests and exit.
      --engine-e2e-selftest           Run exact watch-adapter E2E tests for v11, v12, v13 and v14 and exit.
      --mode <standard|conservative|sensitive|custom>  Detection mode (default: standard, v7 only)
      --speed <m/s>                   Mock GPS speed (default: 8.0)
      --output <dir>                  Output directory (default: ./output)
      --expected <dir>                Expected dir for comparison (default: ./expected)
      --bless                         Copy actual → expected after run
      --compare                       Compare actual to expected; exit 1 on mismatch
      --with-logger                   Enable SessionLogger CSV writes (default: silent)
      --surfr                         Print Surfr screenshot timing comparison
      --require-surfr-windows         Fail unless all 4 Surfr signal windows are present
      --require-surfr-reference       Fail unless accepted jumps match the 4 Surfr screenshot rows
      --allow-surfr-extra-jumps       Do not fail on accepted jumps outside Surfr reference times
      --surfr-time-tolerance <sec>    Surfr accepted jump time tolerance (default: 3.0)
      --surfr-height-tolerance <m>    Surfr height tolerance (default: 0.75)
      --surfr-airtime-tolerance <sec> Surfr airtime tolerance (default: 0.50)
      --surfr-distance-tolerance <m>  Surfr distance tolerance (default: 10.0)
      --no-gps                        Do not feed GPS/speed into the detector
      --dump-samples <path.csv>       Decode sensor streams to CSV and exit
      --dump-events <path.csv>        Decode event records to CSV and exit
      --dump-v13-audit <path.json>    Decode V13 calculation audit to JSON and exit
      -v, --verbose                   Print sample-level events
      -h, --help                      Show this help
    """
    print(usage)
}

func runOne(url: URL, opts: CLIOptions, stdout: inout StdoutStream) throws -> Bool {
        let log = try Loader.load(url, forceFormat: opts.format)

        // Build the report from the complete decoded timeline. On watchOS an
        // IMU source can stall while absolute altitude continues to the end.
        let durationSec = log.timelineDurationSec

        let replayJumps: [ReplayJump]
        if opts.engine == "v8" {
            replayJumps = detectV8(log: log, opts: opts)
        } else {
            // ── streaming engines ────────────────────────────────────────────
            let detector: JumpDetecting
            switch opts.engine {
            case "v7":
                detector = JumpDetector()
            case "v10":
                detector = JumpDetectorV10()
            case "v11", "v11-buffered":
                detector = JumpDetectorV11()
            case "v12", "v12-apple-sensor-fusion":
                detector = JumpDetectorV12()
            case "v13", "v13-pure":
                detector = JumpDetectorV13()
            case "v14", "v14-hybrid":
                detector = JumpDetectorV14()
            case "v15", "v15-clean":
                detector = JumpDetectorV15()
            case "v16", "v16-big-air":
                detector = JumpDetectorV16()
            default:
                fputs("unknown engine: \(opts.engine)\n", stderr)
                return false
            }
            // Offline replay has no run loop to drain DispatchQueue.main, so run the
            // streaming analysis inline and deliver callbacks synchronously.
            detector.synchronousAnalysis = true
            var capturedJumps: [(Jump, Date)] = []
            var richV11: [Double: JumpResultV11] = [:]
            if let v11 = detector as? JumpDetectorV11 {
                v11.onJumpResultV11 = { r in
                    richV11[round(r.takeoffTimeSeconds * 100) / 100] = r
                }
            }
            detector.onJumpDetected = { jump in
                capturedJumps.append((jump, log.samples.first?.timestamp ?? jump.startTime))
            }
            if let v12 = detector as? JumpDetectorV12 {
                v12.onJumpUpdated = { jump in
                    if let idx = capturedJumps.firstIndex(where: { $0.0.id == jump.id }) {
                        capturedJumps[idx] = (jump, capturedJumps[idx].1)
                    } else {
                        capturedJumps.append((jump, log.samples.first?.timestamp ?? jump.startTime))
                    }
                }
                v12.onJumpRetracted = { id in
                    capturedJumps.removeAll { $0.0.id == id }
                }
            }
            if opts.verbose, let v15 = detector as? JumpDetectorV15 {
                let debugBase = log.samples.first?.motionTimestamp ?? 0
                v15.onDebugEvent = { t, event in
                    print(String(format: "  [v15 %7.2fs] %@", t - debugBase, event))
                }
            }
            if opts.verbose, let v16 = detector as? JumpDetectorV16 {
                let debugBase = log.samples.first?.motionTimestamp ?? 0
                v16.onDebugEvent = { t, event in
                    print(String(format: "  [v16 %7.2fs] %@", t - debugBase, event))
                }
            }
            if opts.verbose, let v14 = detector as? JumpDetectorV14 {
                let debugBase = log.samples.first?.motionTimestamp ?? 0
                v14.onDebugEvent = { t, event in
                    print(String(format: "  [v14 %7.2fs] %@", t - debugBase, event))
                }
            }

            detector.reset(mode: opts.mode)

            // A log that contains ABSALT records was captured with a live direct
            // absolute-altitude stream. Say so up-front, so the opening seconds
            // are not fed through the ZOH row fallback that the watch never uses
            // (see markDirectAbsoluteStreamAvailable).
            if !log.absoluteAltitudes.isEmpty, let v15 = detector as? JumpDetectorV15 {
                v15.markDirectAbsoluteStreamAvailable()
            }

            // Prefer the on-device CSV speed column when present. Falling back to
            // MockGPS keeps older synthetic logs usable.
            let hasLogSpeeds = !opts.noGPS && log.speeds.contains { ($0 ?? 0) > 0 }

            // Mock GPS that fires before each new sample — keeps state in RIDING.
            let gps = MockGPS(speed: opts.speed, detector: detector)
            let absoluteAltitudes = log.absoluteAltitudes.sorted { $0.sensorT < $1.sensorT }
            let firstAbsoluteAltitudeT = absoluteAltitudes.first?.sensorT
            let receivedBaseT = log.samples.first?.motionTimestamp
                ?? firstAbsoluteAltitudeT
                ?? ProcessInfo.processInfo.systemUptime
            var nextAbsoluteAltitudeIndex = 0

            // V14 samples the absolute altimeter on demand: the stream is
            // physically off until the engine opens a jump window. Emulate that
            // by dropping samples while the window is closed, and — matching
            // CMAltimeter's immediate first callback on start — replaying the
            // most recent sample the moment the window opens.
            var lastSeenAbsolute: LoadedAbsoluteAltitude?
            var v14WindowWasOpen = false

            func deliverAbsoluteAltitude(_ event: LoadedAbsoluteAltitude) {
                let receivedT: TimeInterval
                if let firstAbsoluteAltitudeT {
                    receivedT = receivedBaseT + (event.sensorT - firstAbsoluteAltitudeT)
                } else {
                    receivedT = event.sensorT
                }
                detector.processAbsoluteAltitude(
                    sensorT: event.sensorT,
                    receivedT: receivedT,
                    altitudeM: event.altitudeM,
                    accuracyM: event.accuracyM,
                    precisionM: event.precisionM
                )
            }

            func feedAbsoluteAltitude(_ event: LoadedAbsoluteAltitude) {
                if let v14 = detector as? JumpDetectorV14 {
                    lastSeenAbsolute = event
                    guard v14.isAbsoluteWindowOpen else { return }
                }
                deliverAbsoluteAltitude(event)
            }

            func emulateV14WindowTransition() {
                guard let v14 = detector as? JumpDetectorV14 else { return }
                let open = v14.isAbsoluteWindowOpen
                if open, !v14WindowWasOpen, let last = lastSeenAbsolute {
                    deliverAbsoluteAltitude(last)
                }
                v14WindowWasOpen = open
            }

            func feedAbsoluteAltitudes(upTo sampleT: TimeInterval) {
                while nextAbsoluteAltitudeIndex < absoluteAltitudes.count,
                      absoluteAltitudes[nextAbsoluteAltitudeIndex].sensorT <= sampleT {
                    feedAbsoluteAltitude(absoluteAltitudes[nextAbsoluteAltitudeIndex])
                    nextAbsoluteAltitudeIndex += 1
                }
            }

            // Drive samples through detector
            for (idx, sample) in log.samples.enumerated() {
                feedAbsoluteAltitudes(upTo: sample.motionTimestamp ?? sample.timestamp.timeIntervalSince1970)
                if hasLogSpeeds, idx < log.speeds.count, let spd = log.speeds[idx] {
                    detector.updateGPS(speed: spd, altitude: 0, latitude: 0, longitude: 0, course: -1, horizontalAccuracy: nil, timestamp: sample.timestamp)
                } else if !opts.noGPS {
                    gps.tickIfNeeded(at: sample.timestamp)
                }
                detector.processSample(sample)
                emulateV14WindowTransition()
            }
            while nextAbsoluteAltitudeIndex < absoluteAltitudes.count {
                feedAbsoluteAltitude(absoluteAltitudes[nextAbsoluteAltitudeIndex])
                nextAbsoluteAltitudeIndex += 1
            }

            // Buffered/refined engines need a final flush so the closing seconds
            // are analysed and V12's delayed refinement is delivered. V13 hands
            // back jumps still settling at the end of the log.
            if opts.engine.hasPrefix("v11") || opts.engine.hasPrefix("v12") || opts.engine.hasPrefix("v13") || opts.engine.hasPrefix("v14") || opts.engine.hasPrefix("v15") {
                let late = detector.endSession()
                for jump in late {
                    capturedJumps.append((jump, log.samples.first?.timestamp ?? jump.startTime))
                }
            }

            // v11 segment-level debug JSON (accepted + rejected, with reason codes).
            if opts.v11Debug, let v11 = detector as? JumpDetectorV11 {
                let debugURL = opts.outputDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).v11debug.json")
                try? FileManager.default.createDirectory(at: opts.outputDir, withIntermediateDirectories: true)
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? enc.encode(v11.debugSegments) {
                    try? data.write(to: debugURL)
                    print("→ wrote \(debugURL.path) (\(v11.debugSegments.count) segments)", to: &stdout)
                }
            }

            replayJumps = capturedJumps.enumerated().map { (i, pair) -> ReplayJump in
                let (j, base) = pair
                let takeoff = j.startTime.timeIntervalSince(base)
                let rich = richV11[round(takeoff * 100) / 100]
                let accepted: Bool
                if opts.engine.hasPrefix("v15") {
                    accepted = j.gpsVerified != false
                } else if opts.engine.hasPrefix("v11") || opts.engine.hasPrefix("v12")
                            || opts.engine.hasPrefix("v13") || opts.engine.hasPrefix("v14") {
                    accepted = true
                } else {
                    accepted = j.confidence >= 50
                }
                return ReplayJump(
                    index: i,
                    takeoffOffsetSec: takeoff,
                    airtime: j.airtime,
                    physicalAirtime: j.endTime.timeIntervalSince(j.startTime),
                    height: j.height,
                    heightSource: rich?.heightSource.rawValue ?? j.heightSource ?? "unknown",
                    apexTime: j.apexTime,
                    confidence: j.confidence,
                    rotations: j.rotations,
                    jumpDistance: j.jumpDistance,
                    gpsVerified: j.gpsVerified,
                    takeoffGroundSpeed: j.takeoffGroundSpeed,
                    accepted: accepted
                )
            }
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
            let ok = matches.count == SurfrReference.jumps.count && matches.allSatisfy(\.acceptedWithinTolerance)
            if ok {
                print("✓ Surfr accepted jumps within tolerance: \(matches.count)/\(SurfrReference.jumps.count)", to: &stdout)
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

        if opts.requireSurfrReference {
            let tolerances = SurfrReference.Tolerances(
                timeSec: opts.surfrTimeToleranceSec,
                heightM: opts.surfrHeightToleranceM,
                airtimeSec: opts.surfrAirtimeToleranceSec,
                distanceM: opts.surfrDistanceToleranceM
            )
            let result = SurfrReference.check(
                report: report,
                tolerances: tolerances,
                allowExtraJumps: opts.allowSurfrExtraJumps
            )
            print("Surfr reference check:", to: &stdout)
            for line in result.lines {
                print("  \(line)", to: &stdout)
            }
            if result.ok {
                print("✓ Surfr reference matched", to: &stdout)
            } else {
                print("✗ Surfr reference mismatch", to: &stdout)
                return false
            }
        }

        return true
}

// MARK: - Top-level entry

let opts = parseArgs()
var allOK = true
var stdout = StdoutStream()

// ── v11 core-calculation self-tests ──────────────────────────────────────
if opts.v11SelfTest {
    let ok = V11SelfTest.run(&stdout)
    exit(ok ? 0 : 1)
}

// ── exact watch-adapter E2E self-tests for v11/v12 ───────────────────────
if opts.engineE2ESelfTest {
    let ok = EngineE2ESelfTest.run(&stdout)
    exit(ok ? 0 : 1)
}

// ── structured V13 calculation audit dump ─────────────────────────────────
if let dumpPath = opts.dumpV13Audit, let url = opts.inputs.first {
    do {
        let log = try Loader.load(url, forceFormat: opts.format)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(log.v13AuditRecords)
        try data.write(to: URL(fileURLWithPath: dumpPath), options: .atomic)
        print("→ wrote \(dumpPath) (\(log.v13AuditRecords.count) V13 audit records)")
        exit(0)
    } catch {
        fputs("V13 audit dump error: \(error)\n", stderr); exit(1)
    }
}

// ── decoded per-sample CSV dump (for offline signal analysis) ─────────────
if let dumpPath = opts.dumpEvents, let url = opts.inputs.first {
    do {
        let log = try Loader.load(url, forceFormat: opts.format)
        let base = log.samples.first?.timestamp ?? Date()
        var out = "t,message\n"
        for e in log.events {
            let t = e.timestamp.timeIntervalSince(base)
            let msg = e.message.replacingOccurrences(of: "\"", with: "'")
            out += String(format: "%.3f,\"%@\"\n", t, msg)
        }
        try out.write(toFile: dumpPath, atomically: true, encoding: .utf8)
        print("→ wrote \(dumpPath) (\(log.events.count) events)")
        exit(0)
    } catch {
        fputs("dump error: \(error)\n", stderr); exit(1)
    }
}

if let dumpPath = opts.dumpSamples, let url = opts.inputs.first {
    do {
        let log = try Loader.load(url, forceFormat: opts.format)
        let base = log.samples.first?.timestamp ?? Date()
        let baseMotionT = log.samples.first?.motionTimestamp
        var out = "t,motionRel,baroRel,absAltRel,relAlt,absAlt,absAltAcc,absAltPrec,accelMag,vertG,signedLoadG,rotMag,gx,gy,gz,speed,baro\n"
        for (idx, s) in log.samples.enumerated() {
            let t = s.timestamp.timeIntervalSince(base)
            let motionRel = relativeTime(s.motionTimestamp, base: baseMotionT)
            let baroRel = relativeTime(s.barometerTimestamp, base: baseMotionT)
            let absAltRel = relativeTime(s.absoluteAltitudeTimestamp, base: baseMotionT)
            let relAlt = s.relativeAltitude.map { String($0) } ?? ""
            let absAlt = s.absoluteAltitude.map { String($0) } ?? ""
            let absAcc = s.absoluteAltitudeAccuracy.map { String($0) } ?? ""
            let absPrec = s.absoluteAltitudePrecision.map { String($0) } ?? ""
            let gx = s.gravity?.x ?? 0, gy = s.gravity?.y ?? 0, gz = s.gravity?.z ?? -1
            let gMag = (gx*gx + gy*gy + gz*gz).squareRoot()
            let signedLoad = gMag > 0.01 ? (s.accelerationX*gx + s.accelerationY*gy + s.accelerationZ*gz)/gMag + gMag : s.accelerationMagnitude
            let vert = abs(signedLoad)
            let spd = (idx < log.speeds.count ? log.speeds[idx] : nil).map { String($0) } ?? ""
            let baro = s.pressure.map { String($0) } ?? ""
            out += String(format: "%.3f,%@,%@,%@,%@,%@,%@,%@,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%@,%@\n",
                          t, motionRel, baroRel, absAltRel, relAlt, absAlt, absAcc, absPrec,
                          s.accelerationMagnitude, vert, signedLoad, s.rotationMagnitude,
                          s.rotationX, s.rotationY, s.rotationZ, spd, baro)
        }
        try out.write(toFile: dumpPath, atomically: true, encoding: .utf8)
        print("→ wrote \(dumpPath) (\(log.samples.count) samples)")
        exit(0)
    } catch {
        fputs("dump error: \(error)\n", stderr); exit(1)
    }
}

private func relativeTime(_ t: TimeInterval?, base: TimeInterval?) -> String {
    guard let t, let base else { return "" }
    return String(format: "%.3f", t - base)
}

// ── Surfr-calibrated evaluation harness ───────────────────────────────────
if let labelsPath = opts.evaluateLabels, let url = opts.inputs.first {
    let tol = JumpEvaluationHarness.Tolerance(rawValue: opts.evalTolerance) ?? .normal
    let ok = JumpEvaluationHarness.run(log: url, labelsURL: URL(fileURLWithPath: labelsPath),
                                       tolerance: tol, offsetSec: opts.evalOffsetSec,
                                       opts: opts, stdout: &stdout)
    exit(ok ? 0 : 1)
}

// ── v10-vs-v11 comparison runner ──────────────────────────────────────────
if opts.compareEngines {
    let ok = JumpComparisonRunner.run(opts: opts, stdout: &stdout)
    exit(ok ? 0 : 1)
}

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
            referenceHeightM: ref.height,
            referenceAirtimeSec: ref.airtime,
            nearestEventTimeSec: nearestEvent?.0,
            nearestEventDeltaSec: nearestEvent.map { $0.0 - ref.time },
            nearestEvent: nearestEvent?.1.message,
            nearestAcceptedTimeSec: nearestAccepted?.takeoffOffsetSec,
            nearestAcceptedDeltaSec: nearestAccepted.map { $0.takeoffOffsetSec - ref.time },
            nearestAcceptedHeightM: nearestAccepted?.height,
            nearestAcceptedHeightDeltaM: nearestAccepted.map { $0.height - ref.height },
            nearestAcceptedAirtimeSec: nearestAccepted?.airtime,
            nearestAcceptedAirtimeDeltaSec: nearestAccepted.map { $0.airtime - ref.airtime },
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

/// Runs the v8 (baro-centric) engine over the whole session — its validated mode.
/// Builds V8Samples from the loaded log (accel already in g, gyro rad/s, gravity
/// in g-units, baro hPa — see Loader.toIMUSample) and applies the same accept gate
/// the watch `JumpDetectorV8` uses (confidence ≥ 0.40).
private func detectV8(log: LoadedLog, opts: CLIOptions) -> [ReplayJump] {
    guard let first = log.samples.first?.timestamp else { return [] }
    let useSpeeds = !opts.noGPS
    var v8: [V8Sample] = []
    v8.reserveCapacity(log.samples.count)
    for (idx, s) in log.samples.enumerated() {
        let tMs = s.timestamp.timeIntervalSince(first) * 1000
        let gvX = s.gravity?.x ?? 0
        let gvY = s.gravity?.y ?? 0
        let gvZ = s.gravity?.z ?? -1
        let spd: Double? = (useSpeeds && idx < log.speeds.count) ? log.speeds[idx] : nil
        v8.append(V8Sample(
            t: tMs,
            ax: s.accelerationX, ay: s.accelerationY, az: s.accelerationZ,
            aM: s.accelerationMagnitude,
            gx: s.rotationX, gy: s.rotationY, gz: s.rotationZ,
            gM: s.rotationMagnitude,
            gvX: gvX, gvY: gvY, gvZ: gvZ,
            baro: s.pressure,
            spd: spd, lat: nil, lng: nil))
    }

    if opts.verbose {
        let baroCount = v8.filter { $0.baro != nil }.count
        let spds = v8.compactMap { $0.spd }.filter { $0 > 0 }
        let maxSpd = spds.max() ?? 0
        let baroVals = v8.compactMap { $0.baro }
        let baroSpread = (baroVals.max() ?? 0) - (baroVals.min() ?? 0)
        fputs(String(format: "  [v8 diag] baroSamples=%d/%d baroSpreadHPa=%.3f maxSpd=%.2f spdSamples=%d\n",
                     baroCount, v8.count, baroSpread, maxSpd, spds.count), stderr)
    }
    var params = JumpEngineV8Params.default
    if opts.noThrows { params.detectThrows = false }
    let results = KitesurfJumpEngineV8.detectJumps(v8, params)
    let accepted = results.filter { $0.confidence >= 0.40 }
    return accepted.enumerated().map { (i, r) -> ReplayJump in
        let toSec = (r.takeoffTimeMs ?? 0) / 1000
        let landSec = (r.landingTimeMs ?? 0) / 1000
        return ReplayJump(
            index: i,
            takeoffOffsetSec: toSec,
            airtime: r.airTimeSec,
            physicalAirtime: landSec - toSec,
            height: r.jumpHeightM,
            heightSource: r.heightSource.rawValue,   // "barometric" | "ballistic"
            apexTime: r.apexTimeSec,
            confidence: r.confidence * 100,
            rotations: 0,
            jumpDistance: r.jumpDistanceM ?? 0,
            gpsVerified: nil,
            takeoffGroundSpeed: nil,
            accepted: true
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
