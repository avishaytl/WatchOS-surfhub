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
      --engine <v7|v8|v10>            Jump engine (default: v7). v8 = baro-centric batch; v10 = engine_v10 (sensor-grounded kite-aware) adapter.
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
      -v, --verbose                   Print sample-level events
      -h, --help                      Show this help
    """
    print(usage)
}

func runOne(url: URL, opts: CLIOptions, stdout: inout StdoutStream) throws -> Bool {
        let log = try Loader.load(url, forceFormat: opts.format)

        // Build report timeline
        let firstT = log.samples.first?.timestamp ?? Date()
        let lastT = log.samples.last?.timestamp ?? firstT
        let durationSec = lastT.timeIntervalSince(firstT)

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
            default:
                fputs("unknown engine: \(opts.engine)\n", stderr)
                return false
            }
            // Offline replay has no run loop to drain DispatchQueue.main, so run the
            // streaming analysis inline and deliver callbacks synchronously.
            detector.synchronousAnalysis = true
            var capturedJumps: [(Jump, Date)] = []
            detector.onJumpDetected = { jump in
                capturedJumps.append((jump, log.samples.first?.timestamp ?? jump.startTime))
            }

            detector.reset(mode: opts.mode)

            // Prefer the on-device CSV speed column when present. Falling back to
            // MockGPS keeps older synthetic logs usable.
            let hasLogSpeeds = !opts.noGPS && log.speeds.contains { ($0 ?? 0) > 0 }

            // Mock GPS that fires before each new sample — keeps state in RIDING.
            let gps = MockGPS(speed: opts.speed, detector: detector)

            // Drive samples through detector
            for (idx, sample) in log.samples.enumerated() {
                if hasLogSpeeds, idx < log.speeds.count, let spd = log.speeds[idx] {
                    detector.updateGPS(speed: spd, altitude: 0, latitude: 0, longitude: 0, course: -1, horizontalAccuracy: nil, timestamp: sample.timestamp)
                } else if !opts.noGPS {
                    gps.tickIfNeeded(at: sample.timestamp)
                }
                detector.processSample(sample)
            }

            replayJumps = capturedJumps.enumerated().map { (i, pair) -> ReplayJump in
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
