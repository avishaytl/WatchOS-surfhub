//
//  ReplaySessionController.swift
//  Kiters Watch App
//
//  Runs the production JumpDetecting adapter from ReplaySensorProvider events,
//  records tick telemetry, and produces deterministic regression reports.
//

import Foundation
import Combine

struct ReplayTelemetrySnapshot {
    var sourceTimestampNs: UInt64 = 0
    var timelineSeconds = 0.0
    var accelerationMagnitude = 0.0
    var verticalLoadG = 0.0
    var gyroMagnitude = 0.0
    var pressureHPa: Double?
    var relativeAltitudeM: Double?
    var absoluteAltitudeM: Double?
    var baselineM: Double?
    var state = JumpDetector.JumpState.idle.rawValue
    var candidate = false
    var candidateScore = 0.0
    var latestHeightM: Double?
    var latestConfidence: Double?
    var latestJumpID: String?
    var filterOutput = 0.0
    var debugFlags = ""
}

struct ReplayJumpReport: Codable, Identifiable {
    let id: String
    let takeoffNs: UInt64
    let landingNs: UInt64
    let heightM: Double
    let airtimeSec: Double
    let confidence: Double
    let acceptedReason: String
}

struct ReplayRunReport: Codable {
    let sourceFile: String
    let sourceSessionID: String?
    let recordedEngine: String?
    let replayEngine: String
    let configurationSnapshot: String
    let build: String
    let generatedAt: Date
    let sourceDurationNs: UInt64
    let deliveredEvents: Int
    let lateEvents: Int
    let maximumLatenessMs: Double
    let outOfOrderRecords: Int
    let duplicateTimestamps: Int
    let rejectedCandidates: [String]
    let jumps: [ReplayJumpReport]
    let fingerprint: String
}

enum ReplayRegressionState: Equatable {
    case unavailable
    case noBaseline
    case matches
    case differs
}

private struct ReplayTimeMapping {
    let syntheticMotionBase: TimeInterval
    let bootWallClock: TimeInterval

    init() {
        syntheticMotionBase = ProcessInfo.processInfo.systemUptime
        bootWallClock = Date().timeIntervalSince1970 - syntheticMotionBase
    }

    func monotonic(relativeSeconds: TimeInterval) -> TimeInterval {
        syntheticMotionBase + relativeSeconds
    }

    func date(relativeSeconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: bootWallClock + monotonic(relativeSeconds: relativeSeconds))
    }

    func relativeNanoseconds(for date: Date) -> UInt64 {
        let sessionWallStart = bootWallClock + syntheticMotionBase
        let seconds = max(0, date.timeIntervalSince1970 - sessionWallStart)
        return UInt64(clamping: Int64((seconds * 1_000_000_000).rounded()))
    }
}

private final class ReplayTelemetryWriter {
    private(set) var url: URL?
    private var fileHandle: FileHandle?
    private var buffer = Data()
    private var rowCount = 0

    func start(sourceURL: URL, engine: DetectionEngine) {
        stop()
        url = nil
        let fileManager = FileManager.default
        let directory = fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("replay_reports", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let timestamp = Self.filenameFormatter.string(from: Date())
        let source = Self.sanitized(sourceURL.deletingPathExtension().lastPathComponent)
        let nonce = UUID().uuidString.prefix(6)
        let filename = "telemetry_\(timestamp)_\(source)_\(engine.rawValue)_\(nonce).csv"
        let destination = directory.appendingPathComponent(filename)
        fileManager.createFile(atPath: destination.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: destination.path) else { return }
        url = destination
        fileHandle = handle
        buffer = Data(Self.header.utf8)
        rowCount = 0
    }

    func append(_ snapshot: ReplayTelemetrySnapshot, eventKind: String) {
        guard fileHandle != nil else { return }
        let row = [
            String(snapshot.sourceTimestampNs),
            Self.format(snapshot.timelineSeconds, 6),
            Self.csv(eventKind),
            Self.format(snapshot.accelerationMagnitude, 5),
            Self.format(snapshot.verticalLoadG, 5),
            Self.format(snapshot.gyroMagnitude, 5),
            Self.optional(snapshot.pressureHPa, 4),
            Self.optional(snapshot.relativeAltitudeM, 4),
            Self.optional(snapshot.absoluteAltitudeM, 4),
            Self.optional(snapshot.baselineM, 4),
            Self.csv(snapshot.state),
            snapshot.candidate ? "1" : "0",
            Self.format(snapshot.candidateScore, 4),
            Self.optional(snapshot.latestHeightM, 4),
            Self.optional(snapshot.latestConfidence, 3),
            Self.csv(snapshot.latestJumpID ?? ""),
            Self.format(snapshot.filterOutput, 5),
            Self.csv(snapshot.debugFlags)
        ].joined(separator: ",") + "\n"
        buffer.append(contentsOf: row.utf8)
        rowCount += 1
        if rowCount % 500 == 0 { flush() }
    }

    func appendJump(_ jump: ReplayJumpReport) {
        guard fileHandle != nil else { return }
        let row = [
            String(jump.landingNs),
            Self.format(Double(jump.landingNs) / 1_000_000_000, 6),
            "jump",
            "", "", "", "", "", "", "",
            "accepted",
            "0",
            "",
            Self.format(jump.heightM, 4),
            Self.format(jump.confidence, 3),
            Self.csv(jump.id),
            "",
            Self.csv(jump.acceptedReason)
        ].joined(separator: ",") + "\n"
        buffer.append(contentsOf: row.utf8)
        flush()
    }

    func appendDebug(sourceTimestampNs: UInt64, timelineSeconds: Double, message: String) {
        guard fileHandle != nil else { return }
        let row = [
            String(sourceTimestampNs),
            Self.format(timelineSeconds, 6),
            "debug",
            "", "", "", "", "", "", "", "", "", "", "", "", "", "",
            Self.csv(message)
        ].joined(separator: ",") + "\n"
        buffer.append(contentsOf: row.utf8)
        if buffer.count >= 64 * 1_024 { flush() }
    }

    func stop() {
        flush()
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func flush() {
        guard let fileHandle, !buffer.isEmpty else { return }
        fileHandle.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private static let header =
        "timestamp_ns,timeline_s,event,imu_magnitude,vertical_load_g,gyro_magnitude,"
        + "pressure_hpa,relative_altitude_m,absolute_altitude_m,baseline_m,state,"
        + "candidate,candidate_score,height_m,confidence,jump_id,filter_output,debug_flags\n"

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter
    }()

    private static func sanitized(_ value: String) -> String {
        value.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
            .reduce(into: "") { $0.append($1) }
    }

    private static func format(_ value: Double, _ decimals: Int) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.\(decimals)f", value)
    }

    private static func optional(_ value: Double?, _ decimals: Int) -> String {
        guard let value else { return "" }
        return format(value, decimals)
    }

    private static func csv(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private final class ReplaySessionProcessor {
    var onSnapshot: ((ReplayTelemetrySnapshot) -> Void)?
    var onJumpsChanged: (([ReplayJumpReport]) -> Void)?

    private let log: ReplaySessionLog
    private let engine: DetectionEngine
    private let mode: DetectionMode
    private var detector: JumpDetecting
    private var mapping = ReplayTimeMapping()
    private var telemetry = ReplayTelemetrySnapshot()
    private var jumpReports: [ReplayJumpReport] = []
    private var rejectedCandidates: [String] = []
    private var gpsSpeedWindow: [Double] = []
    private var pendingAcceptedReason: String?
    private var configurationSnapshot = ""
    private var motionTick = 0
    private var latestSourceTimestampNs: UInt64 = 0
    private var latestTimelineSeconds = 0.0
    private let telemetryWriter = ReplayTelemetryWriter()

    init(log: ReplaySessionLog, engine: DetectionEngine, mode: DetectionMode) {
        self.log = log
        self.engine = engine
        self.mode = mode
        detector = Self.makeDetector(engine)
        reset()
    }

    var telemetryURL: URL? { telemetryWriter.url }
    var jumps: [ReplayJumpReport] { jumpReports }

    func reset() {
        telemetryWriter.stop()
        mapping = ReplayTimeMapping()
        telemetry = ReplayTelemetrySnapshot()
        jumpReports.removeAll(keepingCapacity: true)
        rejectedCandidates.removeAll(keepingCapacity: true)
        gpsSpeedWindow.removeAll(keepingCapacity: true)
        pendingAcceptedReason = nil
        motionTick = 0
        latestSourceTimestampNs = 0
        latestTimelineSeconds = 0

        detector = Self.makeDetector(engine)
        detector.sessionId = "replay-\(log.summary.header.session ?? UUID().uuidString)"
        detector.synchronousAnalysis = true
        wireDetector()
        detector.reset(mode: mode)
        configurationSnapshot = Self.configurationSnapshot(
            detector: detector,
            engine: engine,
            mode: mode
        )
        telemetryWriter.start(sourceURL: log.url, engine: engine)
        onSnapshot?(telemetry)
        onJumpsChanged?(jumpReports)
    }

    func process(_ timedEvent: TimedSensorProviderEvent, publishUI: Bool = true) {
        latestSourceTimestampNs = timedEvent.sourceTimestampNs
        latestTimelineSeconds = Double(timedEvent.timelineTimestampNs) / 1_000_000_000
        telemetry.sourceTimestampNs = timedEvent.sourceTimestampNs
        telemetry.timelineSeconds = latestTimelineSeconds
        let eventKind: String

        switch timedEvent.event {
        case .motion(let sourceSample):
            let sample = remap(sourceSample)
            telemetry.accelerationMagnitude = sample.accelerationMagnitude
            telemetry.verticalLoadG = JumpDetectorV15.verticalLoadG(of: sample)
            telemetry.gyroMagnitude = sample.rotationMagnitude
            telemetry.pressureHPa = sample.pressure
            telemetry.relativeAltitudeM = sample.relativeAltitude
            telemetry.absoluteAltitudeM = sample.absoluteAltitude
            telemetry.filterOutput = telemetry.verticalLoadG
            detector.processSample(sample)
            motionTick += 1
            eventKind = "motion"

        case .barometer(let reading):
            telemetry.pressureHPa = reading.pressureHPa
            telemetry.relativeAltitudeM = reading.relativeAltitudeM
            eventKind = "barometer"

        case .absoluteAltitude(let reading):
            telemetry.absoluteAltitudeM = reading.altitudeM
            let sensorT = mapping.monotonic(relativeSeconds: reading.sensorT)
            let receivedT = mapping.monotonic(relativeSeconds: reading.receivedT)
            detector.processAbsoluteAltitude(
                sensorT: sensorT,
                receivedT: receivedT,
                altitudeM: reading.altitudeM,
                accuracyM: reading.accuracyM,
                precisionM: reading.precisionM
            )
            eventKind = "absoluteAltitude"

        case .gps(let point):
            gpsSpeedWindow.append(point.speed)
            if gpsSpeedWindow.count > 5 { gpsSpeedWindow.removeFirst() }
            let smoothedSpeed = gpsSpeedWindow.reduce(0, +) / Double(gpsSpeedWindow.count)
            let relativeT = point.timestamp.timeIntervalSince1970
            detector.updateGPS(
                speed: smoothedSpeed,
                altitude: point.altitude,
                latitude: point.latitude,
                longitude: point.longitude,
                course: point.course,
                horizontalAccuracy: point.horizontalAccuracy,
                timestamp: mapping.date(relativeSeconds: relativeT)
            )
            eventKind = "gps"

        case .submersion(let reading):
            telemetry.debugFlags = reading.snapshot.submerged == true ? "submerged" : ""
            eventKind = "submersion"

        case .diagnostic(_, let message):
            handleRecordedDiagnostic(message)
            eventKind = "diagnostic"

        case .absoluteAltitudeStreamRestart(let reason):
            detector.absoluteAltitudeStreamDidRestart(reason: reason)
            telemetry.debugFlags = reason
            eventKind = "absoluteRestart"

        case .imuStreamRecovery(let reason):
            telemetry.debugFlags = reason
            eventKind = "imuRecovery"

        case .motionBatch:
            eventKind = "motionBatch"

        case .gpsBatch:
            eventKind = "gpsBatch"

        case .pipelineHealth(let health):
            telemetry.debugFlags = health.warnings.joined(separator: "|")
            eventKind = "pipelineHealth"
        }

        telemetryWriter.append(telemetry, eventKind: eventKind)
        if publishUI && (eventKind != "motion" || motionTick % 20 == 0) {
            onSnapshot?(telemetry)
        }
    }

    func forceSnapshot() {
        onSnapshot?(telemetry)
        onJumpsChanged?(jumpReports)
    }

    func finish(providerStatistics: SensorProviderStatistics) -> ReplayRunReport {
        for jump in detector.endSession() {
            accept(jump, reason: "endSession flush")
        }
        jumpReports.sort { $0.takeoffNs < $1.takeoffNs }
        telemetryWriter.stop()

        let fingerprint = Self.fingerprint(engine: engine, jumps: jumpReports)
        let report = ReplayRunReport(
            sourceFile: log.url.lastPathComponent,
            sourceSessionID: log.summary.header.session,
            recordedEngine: log.summary.header.engineVersion,
            replayEngine: engine.rawValue,
            configurationSnapshot: configurationSnapshot,
            build: Self.buildIdentifier,
            generatedAt: Date(),
            sourceDurationNs: log.summary.durationNs,
            deliveredEvents: providerStatistics.deliveredEvents,
            lateEvents: providerStatistics.lateEvents,
            maximumLatenessMs: providerStatistics.maximumLatenessMs,
            outOfOrderRecords: log.summary.outOfOrderRecordCount,
            duplicateTimestamps: log.summary.duplicateTimestampCount,
            rejectedCandidates: rejectedCandidates,
            jumps: jumpReports,
            fingerprint: fingerprint
        )
        Self.write(report)
        forceSnapshot()
        return report
    }

    private func wireDetector() {
        detector.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.telemetry.state = state.rawValue
            self.telemetry.candidate = state == .airborne
            if !self.telemetry.candidate {
                self.telemetry.candidateScore = 0
            }
            self.onSnapshot?(self.telemetry)
        }
        detector.onJumpDetected = { [weak self] jump in
            self?.accept(jump, reason: "detector accepted")
        }

        if let v9 = detector as? JumpDetectorV9 {
            v9.onJumpUpdated = { [weak self] jump in
                self?.update(jump)
            }
            v9.onJumpRetracted = { [weak self] id in
                self?.retract(id)
            }
        }
        if let v12 = detector as? JumpDetectorV12 {
            v12.onJumpUpdated = { [weak self] jump in
                self?.update(jump)
            }
            v12.onJumpRetracted = { [weak self] id in
                self?.retract(id)
            }
        }
        if let v14 = detector as? JumpDetectorV14 {
            v14.onDebugEvent = { [weak self] t, message in
                self?.handleEngineDebug(t: t, message: message)
            }
        }
        if let v15 = detector as? JumpDetectorV15 {
            v15.onDebugEvent = { [weak self] t, message in
                self?.handleEngineDebug(t: t, message: message)
            }
        }
        if let v16 = detector as? JumpDetectorV16 {
            v16.onDebugEvent = { [weak self] t, message in
                self?.handleEngineDebug(t: t, message: message)
            }
        }
    }

    private func remap(_ sample: IMUSample) -> IMUSample {
        let relativeMotionT = sample.motionTimestamp
            ?? sample.timestamp.timeIntervalSince1970
        let motionT = mapping.monotonic(relativeSeconds: relativeMotionT)
        return IMUSample(
            timestamp: mapping.date(relativeSeconds: relativeMotionT),
            accelerationX: sample.accelerationX,
            accelerationY: sample.accelerationY,
            accelerationZ: sample.accelerationZ,
            rotationX: sample.rotationX,
            rotationY: sample.rotationY,
            rotationZ: sample.rotationZ,
            gravity: sample.gravity,
            pressure: sample.pressure,
            motionTimestamp: motionT,
            relativeAltitude: sample.relativeAltitude,
            barometerTimestamp: sample.barometerTimestamp.map {
                mapping.monotonic(relativeSeconds: $0)
            },
            absoluteAltitude: sample.absoluteAltitude,
            absoluteAltitudeAccuracy: sample.absoluteAltitudeAccuracy,
            absoluteAltitudePrecision: sample.absoluteAltitudePrecision,
            absoluteAltitudeTimestamp: sample.absoluteAltitudeTimestamp.map {
                mapping.monotonic(relativeSeconds: $0)
            },
            attitudeQuaternion: sample.attitudeQuaternion,
            submerged: sample.submerged,
            waterDepth: sample.waterDepth,
            waterPressure: sample.waterPressure
        )
    }

    private func accept(_ jump: Jump, reason: String) {
        let acceptedReason = pendingAcceptedReason ?? reason
        pendingAcceptedReason = nil
        let report = report(for: jump, reason: acceptedReason)
        if let index = jumpReports.firstIndex(where: { $0.id == report.id }) {
            jumpReports[index] = report
        } else {
            jumpReports.append(report)
        }
        telemetry.latestHeightM = report.heightM
        telemetry.latestConfidence = report.confidence
        telemetry.latestJumpID = report.id
        telemetry.candidateScore = report.confidence
        telemetryWriter.appendJump(report)
        onJumpsChanged?(jumpReports.sorted { $0.takeoffNs < $1.takeoffNs })
        onSnapshot?(telemetry)
    }

    private func update(_ jump: Jump) {
        accept(jump, reason: "detector refined")
    }

    private func retract(_ id: String) {
        jumpReports.removeAll { $0.id == id }
        telemetry.debugFlags = "retracted \(id)"
        onJumpsChanged?(jumpReports)
        onSnapshot?(telemetry)
    }

    private func report(for jump: Jump, reason: String) -> ReplayJumpReport {
        ReplayJumpReport(
            id: jump.id,
            takeoffNs: mapping.relativeNanoseconds(for: jump.startTime),
            landingNs: mapping.relativeNanoseconds(for: jump.endTime),
            heightM: jump.height,
            airtimeSec: jump.airtime,
            confidence: jump.confidence,
            acceptedReason: reason
        )
    }

    private func handleRecordedDiagnostic(_ message: String) {
        telemetry.debugFlags = message
        if message.localizedCaseInsensitiveContains("absolute altitude watchdog restart") {
            detector.absoluteAltitudeStreamDidRestart(reason: message)
        }
        telemetryWriter.appendDebug(
            sourceTimestampNs: latestSourceTimestampNs,
            timelineSeconds: latestTimelineSeconds,
            message: message
        )
    }

    private func handleEngineDebug(t: TimeInterval, message: String) {
        telemetry.debugFlags = message
        if message.hasPrefix("CANDIDATE") {
            telemetry.candidate = true
            telemetry.candidateScore = 1
        } else if message.hasPrefix("REJECT") {
            telemetry.candidate = false
            rejectedCandidates.append(message)
        } else if message.hasPrefix("JUMP") {
            telemetry.candidate = false
            pendingAcceptedReason = message
        }
        if let baseline = Self.number(afterAny: ["baseline=", "base="], in: message) {
            telemetry.baselineM = baseline
        }
        if let score = Self.number(afterAny: ["score=", "confidence="], in: message) {
            telemetry.candidateScore = score
        }
        telemetryWriter.appendDebug(
            sourceTimestampNs: latestSourceTimestampNs,
            timelineSeconds: max(0, t - mapping.syntheticMotionBase),
            message: message
        )
        onSnapshot?(telemetry)
    }

    private static func number(afterAny prefixes: [String], in text: String) -> Double? {
        for prefix in prefixes {
            guard let range = text.range(of: prefix) else { continue }
            let suffix = text[range.upperBound...]
            let token = suffix.prefix { character in
                character.isNumber || character == "." || character == "-"
            }
            if let value = Double(token) { return value }
        }
        return nil
    }

    private static func makeDetector(_ engine: DetectionEngine) -> JumpDetecting {
        switch engine {
        case .v16BigAir: return JumpDetectorV16()
        case .v15Clean: return JumpDetectorV15()
        case .v14Hybrid: return JumpDetectorV14()
        case .v13Pure: return JumpDetectorV13()
        case .v12AppleSensorFusion: return JumpDetectorV12()
        case .v11Buffered: return JumpDetectorV11()
        case .v10: return JumpDetectorV10()
        case .v9: return JumpDetectorV9()
        case .v8: return JumpDetectorV8()
        case .v7: return JumpDetector()
        case .sensorRecorder: return JumpDetectorV15()
        }
    }

    private static func configurationSnapshot(
        detector: JumpDetecting,
        engine: DetectionEngine,
        mode: DetectionMode
    ) -> String {
        if let detector = detector as? JumpDetectorV15 {
            return String(reflecting: detector.effectiveConfiguration)
        }
        if let detector = detector as? JumpDetectorV16 {
            return String(reflecting: detector.effectiveConfiguration)
        }
        if let detector = detector as? JumpDetectorV14 {
            return String(reflecting: detector.effectiveConfiguration)
        }
        if let detector = detector as? JumpDetectorV13 {
            return String(reflecting: detector.effectiveConfiguration)
        }
        return "engine=\(engine.rawValue);mode=\(mode.rawValue);"
            + "minSpeed=\(mode.minSpeed);takeoffG=\(mode.takeoffG);"
            + "landingG=\(mode.landingG);minAirtime=\(mode.minAirtime);"
            + "maxAirtime=\(mode.maxAirtime);cooldown=\(mode.cooldown)"
    }

    private static var buildIdentifier: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version)(\(build))"
    }

    private static func fingerprint(engine: DetectionEngine, jumps: [ReplayJumpReport]) -> String {
        var canonical = "\(engine.rawValue)|\(jumps.count)"
        for jump in jumps.sorted(by: { $0.takeoffNs < $1.takeoffNs }) {
            canonical += "|\(jump.takeoffNs / 1_000_000)"
            canonical += ":\(jump.landingNs / 1_000_000)"
            canonical += ":\(Int64((jump.heightM * 1_000).rounded()))"
            canonical += ":\(Int64((jump.airtimeSec * 1_000).rounded()))"
            canonical += ":\(Int64((jump.confidence * 1_000).rounded()))"
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func write(_ report: ReplayRunReport) {
        let manager = FileManager.default
        let directory = manager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("replay_reports", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = report.sourceFile
            .replacingOccurrences(of: ".kslog", with: "")
            .replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent(
            "report_\(source)_\(report.replayEngine).json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private enum ReplayBaselineStore {
    private struct Baseline: Codable {
        let sourceFile: String
        let engine: String
        let build: String
        let savedAt: Date
        let fingerprint: String
        let jumps: [ReplayJumpReport]
    }

    static func comparison(for report: ReplayRunReport) -> ReplayRegressionState {
        guard let baseline = load(sourceFile: report.sourceFile, engine: report.replayEngine) else {
            return .noBaseline
        }
        return baseline.fingerprint == report.fingerprint ? .matches : .differs
    }

    static func save(_ report: ReplayRunReport) {
        let baseline = Baseline(
            sourceFile: report.sourceFile,
            engine: report.replayEngine,
            build: report.build,
            savedAt: Date(),
            fingerprint: report.fingerprint,
            jumps: report.jumps
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(baseline) else { return }
        try? data.write(to: url(sourceFile: report.sourceFile, engine: report.replayEngine), options: .atomic)
    }

    private static func load(sourceFile: String, engine: String) -> Baseline? {
        guard let data = try? Data(contentsOf: url(sourceFile: sourceFile, engine: engine)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Baseline.self, from: data)
    }

    private static func url(sourceFile: String, engine: String) -> URL {
        let manager = FileManager.default
        let directory = manager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("replay_reports/baselines", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = (sourceFile + "_" + engine).map {
            $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_"
        }.reduce(into: "") { $0.append($1) }
        return directory.appendingPathComponent("\(key).json")
    }
}

struct ReplaySessionDescriptor: Identifiable, Hashable {
    let id: String
    let url: URL
    let displayName: String
    let sizeBytes: Int64
}

final class ReplaySessionController: ObservableObject {
    @Published private(set) var sessions: [ReplaySessionDescriptor] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var logSummary: ReplayLogSummary?
    @Published private(set) var state: ReplayProviderState = .stopped
    @Published private(set) var telemetry = ReplayTelemetrySnapshot()
    @Published private(set) var jumps: [ReplayJumpReport] = []
    @Published private(set) var report: ReplayRunReport?
    @Published private(set) var regressionState: ReplayRegressionState = .unavailable
    @Published private(set) var telemetryFilename: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isSeeking = false
    @Published var selectedEngine: DetectionEngine
    @Published var replaySpeed = 1.0

    private let processingQueue = DispatchQueue(
        label: "com.kiters.sensor-replay.processing",
        qos: .userInitiated
    )
    private var log: ReplaySessionLog?
    private var provider: ReplaySensorProvider?
    private var processor: ReplaySessionProcessor?

    init() {
        let raw = UserDefaults.standard.string(forKey: "detectionEngine")
            ?? DetectionEngine.v15Clean.rawValue
        let stored = DetectionEngine(rawValue: raw) ?? .v15Clean
        selectedEngine = stored == .sensorRecorder ? .v15Clean : stored
        refreshSessions()
    }

    var progress: Double {
        guard let duration = logSummary?.durationNs, duration > 0 else { return 0 }
        let current = UInt64(max(0, telemetry.timelineSeconds) * 1_000_000_000)
        return min(1, Double(current) / Double(duration))
    }

    var durationSeconds: Double {
        Double(logSummary?.durationNs ?? 0) / 1_000_000_000
    }

    var currentSeconds: Double {
        telemetry.timelineSeconds
    }

    func refreshSessions() {
        let urls = SessionLogger.shared.allLogURLs()
            .filter { $0.pathExtension.lowercased() == "kslog" }
        sessions = urls.map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attributes?[.size] as? Int64 ?? 0
            return ReplaySessionDescriptor(
                id: url.path,
                url: url,
                displayName: url.deletingPathExtension().lastPathComponent,
                sizeBytes: size
            )
        }

        if let current = selectedSessionID,
           sessions.contains(where: { $0.id == current }) {
            return
        }
        if let first = sessions.first {
            selectSession(first.id)
        }
    }

    func selectSession(_ id: String) {
        guard let descriptor = sessions.first(where: { $0.id == id }) else { return }
        shutdownRun()
        selectedSessionID = id
        isLoading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let loaded = try ReplaySessionLog.load(from: descriptor.url)
                DispatchQueue.main.async {
                    guard self?.selectedSessionID == id else { return }
                    self?.install(log: loaded)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self?.selectedSessionID == id else { return }
                    self?.isLoading = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func selectEngine(_ engine: DetectionEngine) {
        guard engine != .sensorRecorder, engine != selectedEngine else { return }
        selectedEngine = engine
        guard let log else { return }
        shutdownRun()
        install(log: log)
    }

    func setSpeed(_ speed: Double) {
        replaySpeed = min(10, max(1, speed))
        provider?.setSpeed(replaySpeed)
    }

    func togglePlayPause() {
        guard !isLoading, !isSeeking else { return }
        switch state {
        case .playing:
            provider?.pause()
        case .finished:
            restart()
        case .stopped, .paused, .failed:
            provider?.start()
        }
    }

    func stop() {
        provider?.stop()
        guard let processor else { return }
        isSeeking = true
        processingQueue.async { [weak self] in
            processor.reset()
            DispatchQueue.main.async {
                guard self?.processor === processor else { return }
                self?.isSeeking = false
                self?.telemetry = ReplayTelemetrySnapshot()
                self?.jumps = []
                self?.report = nil
                self?.regressionState = .unavailable
                self?.telemetryFilename = processor.telemetryURL?.lastPathComponent
            }
        }
    }

    func restart() {
        guard let provider, let processor else { return }
        provider.stop()
        isSeeking = true
        processingQueue.async { [weak self] in
            processor.reset()
            DispatchQueue.main.async {
                guard self?.provider === provider, self?.processor === processor else { return }
                self?.isSeeking = false
                self?.report = nil
                self?.regressionState = .unavailable
                self?.telemetryFilename = processor.telemetryURL?.lastPathComponent
                provider.start()
            }
        }
    }

    func seek(by seconds: Double) {
        guard let log, let provider, let processor, !isSeeking else { return }
        let targetSeconds = min(
            durationSeconds,
            max(0, provider.currentTime + seconds)
        )
        let targetNs = UInt64((targetSeconds * 1_000_000_000).rounded())
        let shouldResume = provider.state == .playing
        provider.pause()
        isSeeking = true
        report = nil
        regressionState = .unavailable

        processingQueue.async { [weak self] in
            processor.reset()
            let decoder = log.makeDecoder()
            var pending: TimedSensorProviderEvent?
            var rebuiltStatistics = SensorProviderStatistics()
            do {
                while let event = try decoder.next() {
                    if event.scheduledTimestampNs > targetNs {
                        pending = event
                        break
                    }
                    processor.process(event, publishUI: false)
                    rebuiltStatistics.deliveredEvents += 1
                    switch event.event {
                    case .motion: rebuiltStatistics.motionSamples += 1
                    case .barometer: rebuiltStatistics.barometerSamples += 1
                    case .absoluteAltitude: rebuiltStatistics.absoluteAltitudeSamples += 1
                    case .gps: rebuiltStatistics.gpsSamples += 1
                    case .submersion: rebuiltStatistics.submersionSamples += 1
                    default: break
                    }
                }
                processor.forceSnapshot()
                provider.installPosition(
                    decoder: decoder,
                    pendingEvent: pending,
                    playheadTimelineNs: targetNs,
                    playheadScheduledNs: targetNs,
                    rebuiltStatistics: rebuiltStatistics
                )
                DispatchQueue.main.async {
                    guard self?.provider === provider, self?.processor === processor else { return }
                    self?.isSeeking = false
                    self?.telemetry.timelineSeconds = targetSeconds
                    self?.telemetryFilename = processor.telemetryURL?.lastPathComponent
                    if shouldResume { provider.start() }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isSeeking = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func saveCurrentAsBaseline() {
        guard let report else { return }
        ReplayBaselineStore.save(report)
        regressionState = .matches
    }

    func shutdown() {
        provider?.pause()
    }

    private func install(log: ReplaySessionLog) {
        self.log = log
        logSummary = log.summary
        isLoading = false
        state = .stopped
        telemetry = ReplayTelemetrySnapshot()
        jumps = []
        report = nil
        regressionState = .unavailable

        let processor = ReplaySessionProcessor(
            log: log,
            engine: selectedEngine,
            mode: currentDetectionMode
        )
        let provider = ReplaySensorProvider(log: log)
        provider.setSpeed(replaySpeed)
        self.processor = processor
        self.provider = provider
        telemetryFilename = processor.telemetryURL?.lastPathComponent

        processor.onSnapshot = { [weak self, weak processor] snapshot in
            DispatchQueue.main.async {
                guard let processor, self?.processor === processor else { return }
                self?.telemetry = snapshot
            }
        }
        processor.onJumpsChanged = { [weak self, weak processor] jumps in
            DispatchQueue.main.async {
                guard let processor, self?.processor === processor else { return }
                self?.jumps = jumps
            }
        }
        provider.onTimedEvent = { [weak self, weak processor] event in
            guard let self, let processor else { return }
            // Delivery is synchronous with the replay deadline: the provider
            // cannot race ahead and merely enqueue a 200 Hz session faster
            // than the production detector actually consumes it.
            self.processingQueue.sync {
                guard self.processor === processor else { return }
                processor.process(event)
            }
        }
        provider.onStateChange = { [weak self, weak provider, weak processor] state in
            guard let self, let provider else { return }
            if state == .finished, let processor {
                self.processingQueue.async {
                    let report = processor.finish(providerStatistics: provider.statistics)
                    DispatchQueue.main.async {
                        guard self.provider === provider, self.processor === processor else { return }
                        self.report = report
                        self.regressionState = ReplayBaselineStore.comparison(for: report)
                        self.telemetryFilename = processor.telemetryURL?.lastPathComponent
                        self.state = .finished
                    }
                }
            } else {
                DispatchQueue.main.async {
                    guard self.provider === provider else { return }
                    self.state = state
                    if case .failed(let message) = state {
                        self.errorMessage = message
                    }
                }
            }
        }
    }

    private var currentDetectionMode: DetectionMode {
        let raw = UserDefaults.standard.string(forKey: "detectionMode")
            ?? DetectionMode.standard.rawValue
        return DetectionMode(rawValue: raw) ?? .standard
    }

    private func shutdownRun() {
        provider?.stop()
        provider?.onTimedEvent = nil
        provider?.onStateChange = nil
        processor?.onSnapshot = nil
        processor?.onJumpsChanged = nil
        provider = nil
        processor = nil
        logSummary = nil
        state = .stopped
        telemetry = ReplayTelemetrySnapshot()
        jumps = []
        report = nil
        regressionState = .unavailable
        isSeeking = false
    }
}
