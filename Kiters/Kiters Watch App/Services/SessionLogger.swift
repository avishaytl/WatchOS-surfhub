//
//  SessionLogger.swift
//  iSurf-Watch
//
//  Per-session binary logger for debugging jump detection.
//  Writes ALL 6 sensor channels at 50 Hz + algorithm internals with compact,
//  scaled integer records so the watch spends less storage and I/O on logs.
//
//  New files use the .kslog binary format. Older .csv logs are still listed,
//  shared, uploaded, and deleted so existing diagnostic files keep working.
//

import Foundation
import CoreMotion
#if canImport(WatchKit)
import WatchKit
#endif

final class SessionLogger {

    // MARK: - Singleton (one active log at a time)
    static let shared = SessionLogger()

    // MARK: - State

    /// All file I/O happens on this serial queue — never blocks the sensor thread.
    private let ioQueue = DispatchQueue(label: "com.isurf.sessionlogger.io", qos: .utility)

    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var isActive = false
    private var startDate: Date?
    private var sampleIndex: Int = 0
    private var t0BootUs: UInt64 = 0
    private var wallClockAtT0Ms: Int64 = 0
    private var bootWallClock: TimeInterval = 0
    private var activeEngine: DetectionEngine?
    private var statusTimer: DispatchSourceTimer?
    private var relativeBaroHzEwma: Double = 0
    private var lastRelativeBaroT: TimeInterval?
    private let queueHealthLock = NSLock()
    private var pendingIOOperations = 0
    private var maximumPendingIOOperations = 0

    /// Buffer writes for performance — flush every N lines
    private var buffer = Data()
    private let flushInterval = 250  // ~5 seconds at 50Hz (or ~25s at 10Hz throttled)

    private enum RecordType: UInt8 {
        case sample = 1
        case event = 2
    }

    private enum KSLG2RecordType: UInt8 {
        case motion = 3
        case rawAccel = 4
        case baro = 5
        case absoluteAltitude = 6
        case gps = 7
        case submersion = 8
        case event = 9
        case sync = 10
        case status = 11
        case v13Audit = 12
    }

    private struct BinaryLogHeader: Codable {
        let app: String
        let format: String
        let version: Int
        let session: String
        let date: String
        let mode: String
        let schemaVersion: Int?
        let engineVersion: String?
        let sensorOnly: Bool?
        let sampleRateHz: Int
        let parameters: BinaryLogParameters
        let columns: [String]
        let t0BootUs: UInt64?
        let wallClockAtT0Ms: Int64?
        let device: BinaryLogDevice?
        let engines: BinaryLogEngines?
        let streams: BinaryLogStreams?
        let reference: BinaryLogReference?
        let columnsNote: String?
    }

    private struct BinaryLogParameters: Codable {
        // LEGACY (v7 DetectionMode) — metadata only. V13/V14/V15 never read
        // these: their adapters ignore the `mode` argument and build their own
        // config from settings. Recorded for backward compatibility with the
        // on-watch viewer and older tooling; do NOT explain a V15 log's
        // behaviour with takeoffG/landingG/minAirtime — see the v15* fields.
        let minSpeed: Double
        let takeoffG: Double
        let landingG: Double
        let minAirtime: Double
        let maxAirtime: Double
        let cooldown: Double
        // Optional so logs written before the V13 threshold split continue to
        // decode in the on-watch viewer.
        let v13MinCountedHeightM: Double?
        let v13CandidateRiseM: Double?
        let v13TakeoffWindowSec: Double?
        let v13LandingDescentM: Double?
        let v13AbsoluteAltitudeSampleIntervalSec: Double?
        // The thresholds V15 actually runs on. Optional so older logs decode
        // unchanged, and nil whenever the active engine is not V15.
        let v15MinRiseM: Double?
        let v15YankOpenG: Double?
        let v15QuietStdG: Double?
        let v15ImpactG: Double?
        let v15FloatFactor: Double?
        let v15MinFloatFraction: Double?
        let v15SplashGuardSec: Double?
        let v15MaxFlightSec: Double?
        let v15MinAirtimeSec: Double?
        let v15AirtimeTaperStartSec: Double?
        let v15GpsVerifyMinSpeedMS: Double?
        let v15ColdStartGraceSec: Double?
    }

    private struct BinaryLogDevice: Codable {
        let model: String
        let watchOS: String
        let appVersion: String
    }

    private struct BinaryLogEngines: Codable {
        let active: String
        let candidates: [String]
    }

    private struct BinaryLogStreams: Codable {
        let motionHz: Int
        let rawAccHz: Int
        let baroExpectedHz: Int
        let gpsHz: Int
        let submersion: Bool
    }

    private struct BinaryLogReference: Codable {
        let surfr: Bool
        let surfrWatch: String
        let syncMethod: String
    }

    // MARK: - Public API

    /// Start a new log file for this session.
    /// Call once when the session starts.
    func start(sessionId: String,
               mode: DetectionMode,
               sensorOnly: Bool,
               engine: DetectionEngine? = nil,
               v13Config: V13Config? = nil,
               v15Config: V15Config? = nil) {
        stop() // close any previous log

        ioQueue.sync {
            let fm = FileManager.default
            let dir = logsDirectory
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            let dateStr = Self.fileDateFormatter.string(from: Date())
            let filename = "log_\(dateStr)_\(sessionId.prefix(8)).kslog"
            let url = dir.appendingPathComponent(filename)

            fm.createFile(atPath: url.path, contents: nil)
            guard let fh = FileHandle(forWritingAtPath: url.path) else {
                print("❌ SessionLogger: cannot open file \(url.path)")
                return
            }

            fileHandle = fh
            fileURL = url
            let now = Date()
            let uptime = ProcessInfo.processInfo.systemUptime
            startDate = now
            t0BootUs = Self.microseconds(uptime)
            wallClockAtT0Ms = Int64((now.timeIntervalSince1970 * 1000).rounded())
            bootWallClock = now.timeIntervalSince1970 - uptime
            activeEngine = engine
            sampleIndex = 0
            relativeBaroHzEwma = 0
            lastRelativeBaroT = nil
            resetQueueHealth()
            buffer.removeAll(keepingCapacity: true)
            isActive = true

            write(Self.makeHeaderData(
                sessionId: sessionId,
                dateStr: dateStr,
                mode: mode,
                sensorOnly: sensorOnly,
                engine: engine,
                v13Config: v13Config,
                v15Config: v15Config,
                t0BootUs: t0BootUs,
                wallClockAtT0Ms: wallClockAtT0Ms
            ))
            startStatusTimer()

            print("📝 SessionLogger started → \(filename)")
        }
    }

    /// Log one IMU sample (called at 50 Hz from sensor thread).
    /// Work is dispatched to a background serial queue — never blocks the caller.
    ///
    /// - Parameters:
    ///   - sample: Full IMU + baro sample
    ///   - speed: Current GPS speed (m/s)
    ///   - baselinePressure: Rolling average baseline pressure (hPa)
    ///   - lowGCount: Current consecutive low-g count from JumpDetector
    ///   - state: Current state machine state string
    ///   - event: Optional event description
    func logSample(
        sample: IMUSample,
        speed: Double,
        baselinePressure: Double,
        lowGCount: Int,
        state: String,
        event: String = ""
    ) {
        guard !event.isEmpty else { return }
        let t = sample.motionTimestamp ?? monotonicTime(from: sample.timestamp)
        appendEvent(t: t, speed: speed, state: state, event: event, flushImmediately: false)
    }

    /// KSLG v2 MOTION record: one per CMDeviceMotion sample, using the sensor's
    /// monotonic timestamp and preserving quaternion attitude for LOG5 replay.
    func logMotionSample(_ sample: IMUSample) {
        logMotionSamples([sample])
    }

    /// Enqueue one Core Motion batch instead of one dispatch block per 200 Hz
    /// sample. Records remain byte-for-byte identical and in sensor order.
    func logMotionSamples(_ samples: [IMUSample]) {
        guard !samples.isEmpty else { return }
        enqueueIO { [self] in
            guard isActive else { return }
            let firstIndex = sampleIndex
            for sample in samples {
                let t = sample.motionTimestamp ?? monotonicTime(from: sample.timestamp)
                let q = sample.attitudeQuaternion ?? MotionQuaternion(w: 1, x: 0, y: 0, z: 0)
                sampleIndex += 1
                buffer.append(Self.makeMotionRecord(
                    tUs: relativeMicros(forMonotonicTime: t),
                    ax: sample.accelerationX,
                    ay: sample.accelerationY,
                    az: sample.accelerationZ,
                    rx: sample.rotationX,
                    ry: sample.rotationY,
                    rz: sample.rotationZ,
                    q: q
                ))
            }
            if firstIndex / flushInterval != sampleIndex / flushInterval { flush() }
        }
    }

    func logBarometer(t: TimeInterval, relativeAltitudeM: Double, pressureHPa: Double) {
        enqueueIO { [self] in
            guard isActive else { return }
            if let last = lastRelativeBaroT {
                let dt = t - last
                if dt > 0 {
                    let hz = 1.0 / dt
                    relativeBaroHzEwma = relativeBaroHzEwma == 0 ? hz : (0.75 * relativeBaroHzEwma + 0.25 * hz)
                }
            }
            lastRelativeBaroT = t
            sampleIndex += 1
            buffer.append(Self.makeBaroRecord(
                tUs: relativeMicros(forMonotonicTime: t),
                relativeAltitudeM: relativeAltitudeM,
                pressureHPa: pressureHPa
            ))
            if sampleIndex % flushInterval == 0 { flush() }
        }
    }

    func logAbsoluteAltitude(t: TimeInterval, altitudeM: Double, accuracyM: Double?, precisionM: Double?) {
        enqueueIO { [self] in
            guard isActive else { return }
            sampleIndex += 1
            buffer.append(Self.makeAbsoluteAltitudeRecord(
                tUs: relativeMicros(forMonotonicTime: t),
                altitudeM: altitudeM,
                accuracyM: accuracyM,
                precisionM: precisionM
            ))
            if sampleIndex % flushInterval == 0 { flush() }
        }
    }

    func logGPSPoint(_ point: GPSPoint) {
        let t = monotonicTime(from: point.timestamp)
        let lat = point.latitude
        let lng = point.longitude
        let speed = point.speed
        let course = point.course
        let hAcc = point.horizontalAccuracy
        let vAcc = point.verticalAccuracy
        let altitude = point.altitude

        enqueueIO { [self] in
            guard isActive else { return }
            sampleIndex += 1
            buffer.append(Self.makeGPSRecord(
                tUs: relativeMicros(forMonotonicTime: t),
                lat: lat,
                lng: lng,
                speed: speed,
                course: course,
                hAcc: hAcc,
                vAcc: vAcc,
                gpsAlt: altitude
            ))
            if sampleIndex % flushInterval == 0 { flush() }
        }
    }

    func logSubmersion(t: TimeInterval, kind: UInt8, value: Double) {
        enqueueIO { [self] in
            guard isActive else { return }
            sampleIndex += 1
            buffer.append(Self.makeSubmersionRecord(
                tUs: relativeMicros(forMonotonicTime: t),
                kind: kind,
                value: value
            ))
            if sampleIndex % flushInterval == 0 { flush() }
        }
    }

    func logSync(label: String) {
        let t = ProcessInfo.processInfo.systemUptime
        let wallClockUnixMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        enqueueIO { [self] in
            guard isActive else { return }
            sampleIndex += 1
            buffer.append(Self.makeSyncRecord(
                tUs: relativeMicros(forMonotonicTime: t),
                wallClockUnixMs: wallClockUnixMs,
                label: label
            ))
            flush()
        }
    }

    /// Log a discrete event (state transition, jump detected, etc.)
    func logEvent(_ event: String, state: String = "", speed: Double = 0) {
        appendEvent(t: ProcessInfo.processInfo.systemUptime, speed: speed, state: state, event: event, flushImmediately: true)
    }

    /// Log a discrete event at an existing CoreMotion monotonic timestamp.
    func logEvent(t: TimeInterval, event: String, state: String = "", speed: Double = 0) {
        appendEvent(t: t, speed: speed, state: state, event: event, flushImmediately: true)
    }

    /// Structured, self-describing V13 calculation record. JSON encoding and
    /// disk work stay on the logger queue, never on Core Motion/engine queues.
    func logV13Audit(_ record: V13AuditRecord) {
        enqueueIO { [self] in
            guard isActive,
                  let payload = try? JSONEncoder().encode(record) else { return }
            sampleIndex += 1
            buffer.append(Self.makeV13AuditRecord(
                tUs: relativeMicros(forMonotonicTime: record.monotonicTime),
                payload: payload
            ))
            if record.kind == "schema"
                || record.kind == "summary"
                || record.stage == "result"
                || sampleIndex % flushInterval == 0 {
                flush()
            }
        }
    }

    private func appendEvent(t: TimeInterval,
                             speed: Double,
                             state: String,
                             event: String,
                             flushImmediately: Bool) {
        guard isActive else { return }
        enqueueIO { [self] in
            guard isActive else { return }
            sampleIndex += 1
            buffer.append(Self.makeKSLG2EventRecord(
                tUs: relativeMicros(forMonotonicTime: t),
                state: state,
                event: event
            ))
            if flushImmediately || sampleIndex % flushInterval == 0 {
                flush()
            }
        }
    }

    private func enqueueIO(_ work: @escaping () -> Void) {
        queueHealthLock.lock()
        pendingIOOperations += 1
        maximumPendingIOOperations = max(maximumPendingIOOperations, pendingIOOperations)
        queueHealthLock.unlock()

        ioQueue.async { [self] in
            work()
            queueHealthLock.lock()
            pendingIOOperations = max(0, pendingIOOperations - 1)
            queueHealthLock.unlock()
        }
    }

    private func resetQueueHealth() {
        queueHealthLock.lock()
        pendingIOOperations = 0
        maximumPendingIOOperations = 0
        queueHealthLock.unlock()
    }

    /// Current and peak dispatch backlog since the previous health snapshot.
    func queueHealthSnapshot() -> (pending: Int, maximumPending: Int) {
        queueHealthLock.lock()
        let result = (pendingIOOperations, maximumPendingIOOperations)
        maximumPendingIOOperations = pendingIOOperations
        queueHealthLock.unlock()
        return result
    }

    private func startStatusTimer() {
        statusTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.appendStatusRecordLocked()
        }
        statusTimer = timer
        timer.resume()
    }

    private func stopStatusTimer() {
        statusTimer?.cancel()
        statusTimer = nil
    }

    private func appendStatusRecordLocked() {
        guard isActive else { return }
        sampleIndex += 1
        buffer.append(Self.makeStatusRecord(
            tUs: relativeMicros(forMonotonicTime: ProcessInfo.processInfo.systemUptime),
            thermal: Self.thermalCode(),
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryPct: Self.batteryPercent(),
            baroSource: currentBaroSourceCode(),
            baroHz: relativeBaroHzEwma
        ))
        if sampleIndex % flushInterval == 0 { flush() }
    }

    /// Stop logging and close the file.
    func stop() {
        guard isActive else { return }
        // Drain the queue so every buffered line is written before we close.
        ioQueue.sync {
            stopStatusTimer()
            flush()
            fileHandle?.closeFile()
            fileHandle = nil
            isActive = false
            activeEngine = nil
        }
        print("📝 SessionLogger stopped (\(sampleIndex) samples written)")
    }

    /// Returns URL of the most recent log file, or nil.
    func mostRecentLogURL() -> URL? {
        return fileURL
    }

    /// Returns URLs for all log files, newest first.
    func allLogURLs() -> [URL] {
        let fm = FileManager.default
        let dir = logsDirectory
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return files
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
    }

    /// Delete all log files.
    func clearAllLogs() {
        let fm = FileManager.default
        for url in allLogURLs() {
            try? fm.removeItem(at: url)
        }
        print("🗑️ All session logs deleted")
    }

    func isBinaryLog(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == Self.binaryExtension
    }

    func estimatedRowCount(for url: URL, fileSizeBytes: Int64) -> Int {
        if isBinaryLog(url) {
            guard let headerInfo = Self.binaryHeaderInfo(url) else {
                return max(0, Int(fileSizeBytes / Int64(Self.sampleRecordMinimumSize)))
            }
            let payloadBytes = max(0, fileSizeBytes - Int64(headerInfo.headerSize + headerInfo.headerLength))
            return max(0, Int(payloadBytes / Int64(Self.sampleRecordMinimumSize)))
        }
        return max(0, Int(fileSizeBytes / 120))
    }

    func buildShareText(for url: URL, fileSize: String, maxChars: Int = 12_000) -> String {
        if isBinaryLog(url) {
            return Self.buildBinaryShareText(for: url, fileSize: fileSize, maxChars: maxChars)
        }
        return Self.buildCSVShareText(for: url, fileSize: fileSize, maxChars: maxChars)
    }

    // MARK: - Private Helpers

    private var logsDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("session_logs", isDirectory: true)
    }

    private func write(_ data: Data) {
        fileHandle?.write(data)
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private func monotonicTime(from date: Date) -> TimeInterval {
        guard bootWallClock > 0 else { return ProcessInfo.processInfo.systemUptime }
        return date.timeIntervalSince1970 - bootWallClock
    }

    private func relativeMicros(forMonotonicTime t: TimeInterval) -> UInt64 {
        let absoluteUs = Self.microseconds(t)
        guard absoluteUs >= t0BootUs else { return 0 }
        return absoluteUs - t0BootUs
    }

    private func currentBaroSourceCode() -> UInt8 {
        guard activeEngine == .v12AppleSensorFusion || activeEngine == .v13Pure else { return 0 }
        #if os(watchOS)
        if #available(watchOS 8.0, *), CMAltimeter.isAbsoluteAltitudeAvailable() {
            return 2
        }
        #endif
        return 1
    }

    private static func microseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(clamping: Int64((max(0, seconds) * 1_000_000).rounded()))
    }

    private static func thermalCode() -> UInt8 {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    private static func batteryPercent() -> Int {
        #if os(watchOS)
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        guard level >= 0 else { return -1 }
        return Int((level * 100).rounded())
        #else
        return -1
        #endif
    }

    private static let fileDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    private static let binaryExtension = "kslog"
    private static let csvExtension = "csv"
    private static let supportedExtensions: Set<String> = [binaryExtension, csvExtension]
    private static let magic = [UInt8]("KSLG".utf8)
    private static let binaryVersion: UInt8 = 2
    private static let v1FileHeaderSize = 8
    private static let v2FileHeaderSize = 7
    private static let sampleRecordBodySize = 45
    private static let eventRecordBodySize = 13
    private static let sampleRecordMinimumSize = 1 + sampleRecordBodySize
    private static let legacyCSVColumns = "idx,t,ax,ay,az,aM,gx,gy,gz,gM,gvX,gvY,gvZ,baro,baseBaro,spd,lowG,state,evt"
    private static let v12CSVColumns = [
        "v12_state",
        "v12_candidate_id",
        "v12_baseline_altitude",
        "v12_smoothed_altitude",
        "v12_max_altitude",
        "v12_altitude_delta",
        "v12_takeoff_detected",
        "v12_apex_detected",
        "v12_landing_detected",
        "v12_motion_quality",
        "v12_location_quality",
        "v12_water_signal_status",
        "v12_confidence",
        "v12_rejection_reason"
    ]
    private static let csvColumns = legacyCSVColumns + "," + v12CSVColumns.joined(separator: ",")

    private static func makeHeaderData(sessionId: String,
                                       dateStr: String,
                                       mode: DetectionMode,
                                       sensorOnly: Bool,
                                       engine: DetectionEngine?,
                                       v13Config: V13Config?,
                                       v15Config: V15Config?,
                                       t0BootUs: UInt64,
                                       wallClockAtT0Ms: Int64) -> Data {
        let header = BinaryLogHeader(
            app: "Kiters",
            format: "kslog",
            version: Int(binaryVersion),
            session: sessionId,
            date: dateStr,
            mode: mode.displayName,
            schemaVersion: 2,
            engineVersion: engine?.rawValue,
            sensorOnly: sensorOnly,
            sampleRateHz: 200,
            parameters: BinaryLogParameters(
                minSpeed: mode.minSpeed,
                takeoffG: mode.takeoffG,
                landingG: mode.landingG,
                minAirtime: mode.minAirtime,
                maxAirtime: mode.maxAirtime,
                cooldown: mode.cooldown,
                v13MinCountedHeightM: v13Config?.minCountedHeightM,
                v13CandidateRiseM: v13Config?.candidateRiseM,
                v13TakeoffWindowSec: v13Config?.takeoffWindowSec,
                v13LandingDescentM: v13Config?.landingDescentM,
                v13AbsoluteAltitudeSampleIntervalSec: v13Config?.absoluteAltitudeSampleIntervalSec,
                v15MinRiseM: v15Config?.minRiseM,
                v15YankOpenG: v15Config?.yankOpenG,
                v15QuietStdG: v15Config?.quietStdG,
                v15ImpactG: v15Config?.impactG,
                v15FloatFactor: v15Config?.floatFactor,
                v15MinFloatFraction: v15Config?.minFloatFraction,
                v15SplashGuardSec: v15Config?.splashGuardSec,
                v15MaxFlightSec: v15Config?.maxFlightSec,
                v15MinAirtimeSec: v15Config?.minAirtimeSec,
                v15AirtimeTaperStartSec: v15Config?.airtimeTaperStartSec,
                v15GpsVerifyMinSpeedMS: v15Config?.gpsVerifyMinSpeedMS,
                v15ColdStartGraceSec: v15Config?.coldStartGraceSec
            ),
            columns: csvColumns.components(separatedBy: ","),
            t0BootUs: t0BootUs,
            wallClockAtT0Ms: wallClockAtT0Ms,
            device: currentDeviceInfo(),
            engines: BinaryLogEngines(
                active: engine?.rawValue ?? "unknown",
                candidates: ["v11-buffered", "v12-apple-sensor-fusion", "v13-pure", "v14-hybrid", "sensor-recorder"]
            ),
            streams: BinaryLogStreams(
                motionHz: 200,
                rawAccHz: 0,
                baroExpectedHz: engine == .v13Pure
                    ? Int((1.0 / max(0.25, v13Config?.absoluteAltitudeSampleIntervalSec ?? 0.5)).rounded())
                    : 1,
                gpsHz: 1,
                submersion: true
            ),
            reference: BinaryLogReference(
                surfr: false,
                surfrWatch: "",
                syncMethod: "filmed stopwatch + SYNC records"
            ),
            columnsNote: "stream-tagged records - see LOG5_RECORDING_FORMAT.md"
        )
        let json = (try? JSONEncoder().encode(header)) ?? Data()
        var data = Data(capacity: v2FileHeaderSize + json.count)
        data.append(contentsOf: magic)
        data.append(binaryVersion)
        data.appendUInt16(UInt16(clamping: json.count))
        data.append(json.prefix(Int(UInt16.max)))
        return data
    }

    private static func currentDeviceInfo() -> BinaryLogDevice {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        #if os(watchOS)
        let device = WKInterfaceDevice.current()
        return BinaryLogDevice(
            model: device.model,
            watchOS: device.systemVersion,
            appVersion: appVersion
        )
        #else
        return BinaryLogDevice(model: "unknown", watchOS: "", appVersion: appVersion)
        #endif
    }

    private static func makeSampleRecord(
        index: Int,
        t: TimeInterval,
        ax: Double, ay: Double, az: Double, aM: Double,
        gx: Double, gy: Double, gz: Double, gM: Double,
        gravity: Vector3?,
        baro: Double?,
        baseBaro: Double?,
        speed: Double,
        lowGCount: Int,
        state: String,
        event: String
    ) -> Data {
        let eventData = clippedUTF8(event)
        var data = Data(capacity: sampleRecordMinimumSize + eventData.count)
        data.append(RecordType.sample.rawValue)
        data.appendUInt32(UInt32(clamping: index))
        data.appendUInt32(milliseconds(t))
        data.appendInt16(scaledInt16(ax, scale: 1000))
        data.appendInt16(scaledInt16(ay, scale: 1000))
        data.appendInt16(scaledInt16(az, scale: 1000))
        data.appendInt16(scaledInt16(aM, scale: 1000))
        data.appendInt16(scaledInt16(gx, scale: 1000))
        data.appendInt16(scaledInt16(gy, scale: 1000))
        data.appendInt16(scaledInt16(gz, scale: 1000))
        data.appendInt16(scaledInt16(gM, scale: 1000))
        data.appendInt16(scaledInt16(gravity?.x, scale: 1000))
        data.appendInt16(scaledInt16(gravity?.y, scale: 1000))
        data.appendInt16(scaledInt16(gravity?.z, scale: 1000))
        data.appendInt32(scaledInt32(baro, scale: 100))
        data.appendInt32(scaledInt32(baseBaro, scale: 100))
        data.appendUInt16(scaledUInt16(speed, scale: 100))
        data.appendUInt16(UInt16(clamping: lowGCount))
        data.append(stateCode(state))
        data.appendUInt16(UInt16(eventData.count))
        data.append(eventData)
        return data
    }

    private static func makeEventRecord(index: Int, t: TimeInterval, speed: Double, state: String, event: String) -> Data {
        let eventData = clippedUTF8(event)
        var data = Data(capacity: 1 + eventRecordBodySize + eventData.count)
        data.append(RecordType.event.rawValue)
        data.appendUInt32(UInt32(clamping: index))
        data.appendUInt32(milliseconds(t))
        data.appendUInt16(scaledUInt16(speed, scale: 100))
        data.append(stateCode(state))
        data.appendUInt16(UInt16(eventData.count))
        data.append(eventData)
        return data
    }

    private static func makeMotionRecord(tUs: UInt64,
                                         ax: Double,
                                         ay: Double,
                                         az: Double,
                                         rx: Double,
                                         ry: Double,
                                         rz: Double,
                                         q: MotionQuaternion) -> Data {
        var data = Data(capacity: 29)
        data.append(KSLG2RecordType.motion.rawValue)
        data.appendUInt64(tUs)
        data.appendInt16(scaledInt16(ax, scale: 1000))
        data.appendInt16(scaledInt16(ay, scale: 1000))
        data.appendInt16(scaledInt16(az, scale: 1000))
        data.appendInt16(scaledInt16(rx, scale: 1000))
        data.appendInt16(scaledInt16(ry, scale: 1000))
        data.appendInt16(scaledInt16(rz, scale: 1000))
        data.appendInt16(scaledInt16(q.w, scale: 10000))
        data.appendInt16(scaledInt16(q.x, scale: 10000))
        data.appendInt16(scaledInt16(q.y, scale: 10000))
        data.appendInt16(scaledInt16(q.z, scale: 10000))
        return data
    }

    private static func makeBaroRecord(tUs: UInt64,
                                       relativeAltitudeM: Double,
                                       pressureHPa: Double) -> Data {
        var data = Data(capacity: 17)
        data.append(KSLG2RecordType.baro.rawValue)
        data.appendUInt64(tUs)
        data.appendInt32(scaledInt32(relativeAltitudeM, scale: 1000))
        data.appendInt32(scaledInt32(pressureHPa, scale: 1000))
        return data
    }

    private static func makeAbsoluteAltitudeRecord(tUs: UInt64,
                                                   altitudeM: Double,
                                                   accuracyM: Double?,
                                                   precisionM: Double?) -> Data {
        var data = Data(capacity: 21)
        data.append(KSLG2RecordType.absoluteAltitude.rawValue)
        data.appendUInt64(tUs)
        data.appendInt32(scaledInt32(altitudeM, scale: 1000))
        data.appendInt32(scaledInt32(accuracyM, scale: 1000))
        data.appendInt32(scaledInt32(precisionM, scale: 1000))
        return data
    }

    private static func makeGPSRecord(tUs: UInt64,
                                      lat: Double,
                                      lng: Double,
                                      speed: Double,
                                      course: Double,
                                      hAcc: Double,
                                      vAcc: Double,
                                      gpsAlt: Double) -> Data {
        var data = Data(capacity: 33)
        data.append(KSLG2RecordType.gps.rawValue)
        data.appendUInt64(tUs)
        data.appendInt32(scaledInt32(lat, scale: 10_000_000))
        data.appendInt32(scaledInt32(lng, scale: 10_000_000))
        data.appendUInt16(scaledUInt16Optional(speed >= 0 ? speed : nil, scale: 100))
        data.appendUInt16(scaledUInt16Optional(course >= 0 ? course : nil, scale: 10))
        data.appendUInt16(scaledUInt16Optional(hAcc >= 0 ? hAcc : nil, scale: 10))
        data.appendUInt16(scaledUInt16Optional(vAcc >= 0 ? vAcc : nil, scale: 10))
        data.appendInt32(scaledInt32(gpsAlt, scale: 1000))
        return data
    }

    private static func makeSubmersionRecord(tUs: UInt64, kind: UInt8, value: Double) -> Data {
        var data = Data(capacity: 12)
        data.append(KSLG2RecordType.submersion.rawValue)
        data.appendUInt64(tUs)
        data.append(kind)
        let scale = kind == 0 ? 1.0 : 100.0
        data.appendInt16(scaledInt16(value, scale: scale))
        return data
    }

    private static func makeKSLG2EventRecord(tUs: UInt64, state: String, event: String) -> Data {
        let eventData = clippedUTF8(event)
        var data = Data(capacity: 12 + eventData.count)
        data.append(KSLG2RecordType.event.rawValue)
        data.appendUInt64(tUs)
        data.append(stateCode(state))
        data.appendUInt16(UInt16(eventData.count))
        data.append(eventData)
        return data
    }

    private static func makeSyncRecord(tUs: UInt64, wallClockUnixMs: Int64, label: String) -> Data {
        let labelData = clippedUTF8(label)
        var data = Data(capacity: 19 + labelData.count)
        data.append(KSLG2RecordType.sync.rawValue)
        data.appendUInt64(tUs)
        data.appendInt64(wallClockUnixMs)
        data.appendUInt16(UInt16(labelData.count))
        data.append(labelData)
        return data
    }

    private static func makeStatusRecord(tUs: UInt64,
                                         thermal: UInt8,
                                         lowPower: Bool,
                                         batteryPct: Int,
                                         baroSource: UInt8,
                                         baroHz: Double) -> Data {
        var data = Data(capacity: 15)
        data.append(KSLG2RecordType.status.rawValue)
        data.appendUInt64(tUs)
        data.append(thermal)
        data.append(lowPower ? UInt8(1) : UInt8(0))
        data.appendInt16(Int16(clamping: batteryPct))
        data.append(baroSource)
        data.appendUInt16(scaledUInt16(baroHz, scale: 100))
        return data
    }

    private static func makeV13AuditRecord(tUs: UInt64, payload: Data) -> Data {
        let clipped = payload.prefix(Int(UInt32.max))
        var data = Data(capacity: 13 + clipped.count)
        data.append(KSLG2RecordType.v13Audit.rawValue)
        data.appendUInt64(tUs)
        data.appendUInt32(UInt32(clamping: clipped.count))
        data.append(clipped)
        return data
    }

    private static func milliseconds(_ t: TimeInterval) -> UInt32 {
        UInt32(clamping: max(0, Int((t * 1000).rounded())))
    }

    private static func scaledInt16(_ value: Double?, scale: Double) -> Int16 {
        guard let value, value.isFinite else { return Int16.min }
        return Int16(clamping: Int((value * scale).rounded()))
    }

    private static func scaledInt32(_ value: Double?, scale: Double) -> Int32 {
        guard let value, value.isFinite else { return Int32.min }
        return Int32(clamping: Int((value * scale).rounded()))
    }

    private static func scaledUInt16(_ value: Double, scale: Double) -> UInt16 {
        guard value.isFinite else { return 0 }
        return UInt16(clamping: max(0, Int((value * scale).rounded())))
    }

    private static func scaledUInt16Optional(_ value: Double?, scale: Double) -> UInt16 {
        guard let value, value.isFinite else { return UInt16.max }
        return UInt16(clamping: max(0, Int((value * scale).rounded())))
    }

    private static func clippedUTF8(_ text: String) -> Data {
        let data = text.data(using: .utf8) ?? Data()
        guard data.count > Int(UInt16.max) else { return data }
        return data.prefix(Int(UInt16.max))
    }

    private static func stateCode(_ state: String) -> UInt8 {
        let normalized = state.lowercased()
        if normalized.contains("idle") { return 0 }
        if normalized.contains("riding") { return 1 }
        if normalized.contains("airborne") { return 2 }
        if normalized.contains("cooldown") { return 3 }
        return 255
    }

    private static func stateName(_ code: UInt8) -> String {
        switch code {
        case 0: return "idle"
        case 1: return "riding"
        case 2: return "airborne"
        case 3: return "cooldown"
        default: return ""
        }
    }

    private static func binaryHeaderInfo(_ url: URL) -> (version: UInt8, headerSize: Int, headerLength: Int)? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let prefix = fh.readData(ofLength: 5)
        guard prefix.count == 5 else { return nil }
        let bytes = [UInt8](prefix)
        guard Array(bytes.prefix(4)) == magic else { return nil }
        let version = bytes[4]
        if version == 2 {
            let lengthData = fh.readData(ofLength: 2)
            guard lengthData.count == 2 else { return nil }
            let l = [UInt8](lengthData)
            return (version, v2FileHeaderSize, Int(UInt16(l[0]) | (UInt16(l[1]) << 8)))
        }
        let rest = fh.readData(ofLength: 3)
        guard rest.count == 3 else { return nil }
        let r = [UInt8](rest)
        return (version, v1FileHeaderSize, Int(UInt16(r[1]) | (UInt16(r[2]) << 8)))
    }

    private static func readBinaryHeader(_ fh: FileHandle) -> (version: UInt8, header: BinaryLogHeader)? {
        let prefix = fh.readData(ofLength: 5)
        guard prefix.count == 5 else { return nil }
        let bytes = [UInt8](prefix)
        guard Array(bytes.prefix(4)) == magic else { return nil }
        let version = bytes[4]
        let headerLength: Int
        if version == 2 {
            let lengthData = fh.readData(ofLength: 2)
            guard lengthData.count == 2 else { return nil }
            let l = [UInt8](lengthData)
            headerLength = Int(UInt16(l[0]) | (UInt16(l[1]) << 8))
        } else {
            let rest = fh.readData(ofLength: 3)
            guard rest.count == 3 else { return nil }
            let r = [UInt8](rest)
            headerLength = Int(UInt16(r[1]) | (UInt16(r[2]) << 8))
        }
        let headerData = fh.readData(ofLength: headerLength)
        guard headerData.count == headerLength else { return nil }
        guard let header = try? JSONDecoder().decode(BinaryLogHeader.self, from: headerData) else { return nil }
        return (version, header)
    }

    private static func buildBinaryShareText(for url: URL, fileSize: String, maxChars: Int) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return "Kiters Session Log\nFile: \(url.lastPathComponent)\nSize: \(fileSize)\n"
        }
        defer { try? fh.close() }

        guard let envelope = readBinaryHeader(fh) else {
            return "Kiters Session Log\nFile: \(url.lastPathComponent)\nSize: \(fileSize)\nFormat: binary kslog\n"
        }
        let header = envelope.header

        var text = "Kiters Session Log\n"
        text += "File: \(url.lastPathComponent)\n"
        text += "Size: \(fileSize)\n"
        text += "Format: binary kslog v\(envelope.version)\n"
        text += "session: \(header.session)\n"
        text += "date: \(header.date)\n"
        text += "mode: \(header.mode)\n"
        if let schemaVersion = header.schemaVersion {
            text += "schemaVersion: \(schemaVersion)\n"
        }
        if let engineVersion = header.engineVersion {
            text += "engineVersion: \(engineVersion)\n"
        }
        text += "sensorOnly: \(header.sensorOnly ?? true)\n"
        text += "sampleRate: \(header.sampleRateHz) Hz\n"
        // Legacy v7 DetectionMode block — only meaningful for the v7/v8 engines.
        // V13/V14/V15 ignore it entirely, so labelling avoids misreading a log.
        let legacyOnly = (header.engineVersion.map { $0.hasPrefix("v1") } ?? false)
        text += legacyOnly ? "-- legacy v7 params (NOT used by this engine) --\n" : ""
        text += "minSpeed(m/s): \(String(format: "%.2f", header.parameters.minSpeed))\n"
        text += "takeoffG(g): \(String(format: "%.2f", header.parameters.takeoffG))\n"
        text += "landingG(g): \(String(format: "%.2f", header.parameters.landingG))\n"
        text += "minAirtime(s): \(String(format: "%.2f", header.parameters.minAirtime))\n"
        text += "maxAirtime(s): \(String(format: "%.2f", header.parameters.maxAirtime))\n"
        text += "cooldown(s): \(String(format: "%.2f", header.parameters.cooldown))\n"
        if let minCountedHeightM = header.parameters.v13MinCountedHeightM {
            text += "v13MinCountedHeight(m): \(String(format: "%.2f", minCountedHeightM))\n"
        }
        if let candidateRiseM = header.parameters.v13CandidateRiseM {
            text += "v13CandidateRise(m): \(String(format: "%.2f", candidateRiseM))\n"
        }
        if let takeoffWindowSec = header.parameters.v13TakeoffWindowSec {
            text += "v13TakeoffWindow(s): \(String(format: "%.2f", takeoffWindowSec))\n"
        }
        if let landingDescentM = header.parameters.v13LandingDescentM {
            text += "v13LandingDescent(m): \(String(format: "%.2f", landingDescentM))\n"
        }
        if let v = header.parameters.v15MinRiseM {
            text += "-- V15 thresholds actually in force --\n"
            text += "v15MinRise(m): \(String(format: "%.2f", v))\n"
        }
        if let v = header.parameters.v15YankOpenG {
            text += "v15YankOpen(g): \(String(format: "%.2f", v))\n"
        }
        if let v = header.parameters.v15QuietStdG {
            text += "v15QuietStd(g): \(String(format: "%.2f", v))\n"
        }
        if let v = header.parameters.v15ImpactG {
            text += "v15Impact(g): \(String(format: "%.2f", v))\n"
        }
        if let v = header.parameters.v15FloatFactor {
            text += "v15FloatFactor: \(String(format: "%.2f", v))\n"
        }
        if let v = header.parameters.v15MinFloatFraction {
            text += "v15MinFloatFraction: \(String(format: "%.2f", v))\n"
        }
        if let v = header.parameters.v15MinAirtimeSec {
            text += "v15MinAirtime(s): \(String(format: "%.2f", v))\n"
        }
        if let v = header.parameters.v15MaxFlightSec {
            text += "v15MaxFlight(s): \(String(format: "%.2f", v))\n"
        }
        if let v = header.parameters.v15AirtimeTaperStartSec {
            text += "v15AirtimeTaperStart(s): \(String(format: "%.2f", v))\n"
        }
        if let v = header.parameters.v15GpsVerifyMinSpeedMS {
            text += "v15GpsVerifyMinSpeed(m/s): \(String(format: "%.2f", v))\n"
        }
        if let v = header.parameters.v15ColdStartGraceSec {
            text += "v15ColdStartGrace(s): \(String(format: "%.2f", v))\n"
        }
        text += "\n"

        if envelope.version == 2 {
            return buildKSLG2ShareText(
                fh,
                header: header,
                intro: text,
                maxChars: maxChars
            )
        }

        text += "CSV preview decoded from binary:\n"
        text += "\(csvColumns)\n"

        while text.count < maxChars {
            let typeData = fh.readData(ofLength: 1)
            guard typeData.count == 1, let type = typeData.first else { break }

            let line: String?
            if type == RecordType.sample.rawValue {
                line = readSamplePreviewLine(fh, engineVersion: header.engineVersion)
            } else if type == RecordType.event.rawValue {
                line = readEventPreviewLine(fh, engineVersion: header.engineVersion)
            } else {
                break
            }

            guard let line else { break }
            if text.count + line.count + 1 > maxChars {
                text += "\n... (truncated - send to iPhone for full file)\n"
                break
            }
            text += line + "\n"
        }

        return text
    }

    private static func buildKSLG2ShareText(_ fh: FileHandle,
                                            header: BinaryLogHeader,
                                            intro: String,
                                            maxChars: Int) -> String {
        var text = intro
        if let t0 = header.t0BootUs {
            text += "t0BootUs: \(t0)\n"
        }
        if let wall = header.wallClockAtT0Ms {
            text += "wallClockAtT0Ms: \(wall)\n"
        }
        if let engines = header.engines {
            text += "engines.active: \(engines.active)\n"
        }
        text += "\nKSLG v2 stream preview:\n"
        text += "tag,t,summary\n"

        while text.count < maxChars {
            let tagData = fh.readData(ofLength: 1)
            guard tagData.count == 1, let tag = tagData.first else { break }
            let line: String?
            switch tag {
            case KSLG2RecordType.motion.rawValue:
                line = readKSLG2FixedPreviewLine(fh, bodySize: 28, tag: "MOTION")
            case KSLG2RecordType.rawAccel.rawValue:
                line = readKSLG2FixedPreviewLine(fh, bodySize: 14, tag: "RAWACC")
            case KSLG2RecordType.baro.rawValue:
                line = readKSLG2BaroPreviewLine(fh)
            case KSLG2RecordType.absoluteAltitude.rawValue:
                line = readKSLG2AbsAltPreviewLine(fh)
            case KSLG2RecordType.gps.rawValue:
                line = readKSLG2FixedPreviewLine(fh, bodySize: 28, tag: "GPS")
            case KSLG2RecordType.submersion.rawValue:
                line = readKSLG2SubmersionPreviewLine(fh)
            case KSLG2RecordType.event.rawValue:
                line = readKSLG2EventPreviewLine(fh)
            case KSLG2RecordType.sync.rawValue:
                line = readKSLG2SyncPreviewLine(fh)
            case KSLG2RecordType.status.rawValue:
                line = readKSLG2StatusPreviewLine(fh)
            case KSLG2RecordType.v13Audit.rawValue:
                line = readKSLG2V13AuditPreviewLine(fh)
            default:
                line = nil
            }

            guard let line else { break }
            if text.count + line.count + 1 > maxChars {
                text += "\n... (truncated - send to iPhone for full file)\n"
                break
            }
            text += line + "\n"
        }
        return text
    }

    private static func readKSLG2FixedPreviewLine(_ fh: FileHandle, bodySize: Int, tag: String) -> String? {
        let body = fh.readData(ofLength: bodySize)
        guard body.count == bodySize else { return nil }
        let bytes = [UInt8](body)
        var offset = 0
        let tUs = readUInt64(bytes, &offset)
        return "\(tag),\(formatMicroseconds(tUs)),"
    }

    private static func readKSLG2BaroPreviewLine(_ fh: FileHandle) -> String? {
        let body = fh.readData(ofLength: 16)
        guard body.count == 16 else { return nil }
        let bytes = [UInt8](body)
        var offset = 0
        let tUs = readUInt64(bytes, &offset)
        let rel = readInt32(bytes, &offset)
        let pressure = readInt32(bytes, &offset)
        return "BARO,\(formatMicroseconds(tUs)),relAlt=\(formatScaled(rel, scale: 1000, decimals: 3)); pressureHPa=\(formatScaled(pressure, scale: 1000, decimals: 3))"
    }

    private static func readKSLG2AbsAltPreviewLine(_ fh: FileHandle) -> String? {
        let body = fh.readData(ofLength: 20)
        guard body.count == 20 else { return nil }
        let bytes = [UInt8](body)
        var offset = 0
        let tUs = readUInt64(bytes, &offset)
        let alt = readInt32(bytes, &offset)
        let acc = readInt32(bytes, &offset)
        let precision = readInt32(bytes, &offset)
        return "ABSALT,\(formatMicroseconds(tUs)),alt=\(formatScaled(alt, scale: 1000, decimals: 3)); acc=\(formatScaled(acc, scale: 1000, decimals: 3)); precision=\(formatScaled(precision, scale: 1000, decimals: 3))"
    }

    private static func readKSLG2SubmersionPreviewLine(_ fh: FileHandle) -> String? {
        let body = fh.readData(ofLength: 11)
        guard body.count == 11 else { return nil }
        let bytes = [UInt8](body)
        var offset = 0
        let tUs = readUInt64(bytes, &offset)
        let kind = readUInt8(bytes, &offset)
        let value = readInt16(bytes, &offset)
        let scale = kind == 0 ? 1.0 : 100.0
        return "SUBMERSION,\(formatMicroseconds(tUs)),kind=\(kind); value=\(formatScaled(value, scale: scale, decimals: kind == 0 ? 0 : 2))"
    }

    private static func readKSLG2EventPreviewLine(_ fh: FileHandle) -> String? {
        let body = fh.readData(ofLength: 11)
        guard body.count == 11 else { return nil }
        let bytes = [UInt8](body)
        var offset = 0
        let tUs = readUInt64(bytes, &offset)
        let state = readUInt8(bytes, &offset)
        let eventLength = Int(readUInt16(bytes, &offset))
        let event = readEventString(fh, length: eventLength)
        return "EVENT,\(formatMicroseconds(tUs)),state=\(stateName(state)); evt=\(sanitizeCSV(event))"
    }

    private static func readKSLG2V13AuditPreviewLine(_ fh: FileHandle) -> String? {
        let body = fh.readData(ofLength: 12)
        guard body.count == 12 else { return nil }
        let bytes = [UInt8](body)
        var offset = 0
        let tUs = readUInt64(bytes, &offset)
        let payloadLengthValue = readUInt32(bytes, &offset)
        // The length comes from a file that can be truncated while a session
        // is being written (or otherwise be corrupt). Never trust it as an
        // allocation size on a memory-constrained watch.
        guard payloadLengthValue <= 256 * 1_024 else { return nil }
        let payloadLength = Int(payloadLengthValue)
        let payload = fh.readData(ofLength: payloadLength)
        guard payload.count == payloadLength,
              let record = try? JSONDecoder().decode(V13AuditRecord.self, from: payload) else { return nil }

        var summary = "seq=\(record.sequence); \(record.stage).\(record.action); decision=\(record.decision)"
        if let candidateID = record.candidateID { summary += "; candidate=\(candidateID)" }
        if let reason = record.reason { summary += "; reason=\(reason)" }
        if let height = record.values["heightM"] { summary += "; height=\(String(format: "%.2f", height))m" }
        if let airtime = record.values["airtimeSec"] { summary += "; airtime=\(String(format: "%.2f", airtime))s" }
        return "V13_AUDIT,\(formatMicroseconds(tUs)),\(summary)"
    }

    private static func readKSLG2SyncPreviewLine(_ fh: FileHandle) -> String? {
        let body = fh.readData(ofLength: 18)
        guard body.count == 18 else { return nil }
        let bytes = [UInt8](body)
        var offset = 0
        let tUs = readUInt64(bytes, &offset)
        let wall = readUInt64(bytes, &offset)
        let labelLength = Int(readUInt16(bytes, &offset))
        let label = readEventString(fh, length: labelLength)
        return "SYNC,\(formatMicroseconds(tUs)),wallMs=\(wall); label=\(sanitizeCSV(label))"
    }

    private static func readKSLG2StatusPreviewLine(_ fh: FileHandle) -> String? {
        // STATUS is 15 bytes after the tag:
        // tUs(8) + thermal(1) + lowPower(1) + battery(2) + source(1) + hz(2).
        let body = fh.readData(ofLength: 15)
        guard body.count == 15 else { return nil }
        let bytes = [UInt8](body)
        var offset = 0
        let tUs = readUInt64(bytes, &offset)
        let thermal = readUInt8(bytes, &offset)
        let lowPower = readUInt8(bytes, &offset)
        let battery = readInt16(bytes, &offset)
        let source = readUInt8(bytes, &offset)
        let hz = readUInt16(bytes, &offset)
        return "STATUS,\(formatMicroseconds(tUs)),thermal=\(thermal); lowPower=\(lowPower); battery=\(battery); baroSource=\(source); baroHz=\(String(format: "%.2f", Double(hz) / 100))"
    }

    private static func readSamplePreviewLine(_ fh: FileHandle, engineVersion: String?) -> String? {
        let body = fh.readData(ofLength: sampleRecordBodySize)
        guard body.count == sampleRecordBodySize else { return nil }
        let bytes = [UInt8](body)
        var offset = 0
        let idx = readUInt32(bytes, &offset)
        let tMillis = readUInt32(bytes, &offset)
        let ax = readInt16(bytes, &offset)
        let ay = readInt16(bytes, &offset)
        let az = readInt16(bytes, &offset)
        let aM = readInt16(bytes, &offset)
        let gx = readInt16(bytes, &offset)
        let gy = readInt16(bytes, &offset)
        let gz = readInt16(bytes, &offset)
        let gM = readInt16(bytes, &offset)
        let gvX = readInt16(bytes, &offset)
        let gvY = readInt16(bytes, &offset)
        let gvZ = readInt16(bytes, &offset)
        let baro = readInt32(bytes, &offset)
        let baseBaro = readInt32(bytes, &offset)
        let speed = readUInt16(bytes, &offset)
        let lowG = readUInt16(bytes, &offset)
        let state = readUInt8(bytes, &offset)
        let eventLength = Int(readUInt16(bytes, &offset))
        let event = readEventString(fh, length: eventLength)

        let legacyLine = [
            "\(idx)",
            formatSeconds(tMillis),
            formatScaled(ax, scale: 1000, decimals: 3),
            formatScaled(ay, scale: 1000, decimals: 3),
            formatScaled(az, scale: 1000, decimals: 3),
            formatScaled(aM, scale: 1000, decimals: 3),
            formatScaled(gx, scale: 1000, decimals: 3),
            formatScaled(gy, scale: 1000, decimals: 3),
            formatScaled(gz, scale: 1000, decimals: 3),
            formatScaled(gM, scale: 1000, decimals: 3),
            formatScaled(gvX, scale: 1000, decimals: 3),
            formatScaled(gvY, scale: 1000, decimals: 3),
            formatScaled(gvZ, scale: 1000, decimals: 3),
            formatScaled(baro, scale: 100, decimals: 2),
            formatScaled(baseBaro, scale: 100, decimals: 2),
            String(format: "%.2f", Double(speed) / 100),
            "\(lowG)",
            stateName(state),
            sanitizeCSV(event)
        ].joined(separator: ",")
        return legacyLine + v12PreviewFields(
            state: stateName(state),
            event: event,
            engineVersion: engineVersion
        )
    }

    private static func readEventPreviewLine(_ fh: FileHandle, engineVersion: String?) -> String? {
        let body = fh.readData(ofLength: eventRecordBodySize)
        guard body.count == eventRecordBodySize else { return nil }
        let bytes = [UInt8](body)
        var offset = 0
        let idx = readUInt32(bytes, &offset)
        let tMillis = readUInt32(bytes, &offset)
        let speed = readUInt16(bytes, &offset)
        let state = readUInt8(bytes, &offset)
        let eventLength = Int(readUInt16(bytes, &offset))
        let event = readEventString(fh, length: eventLength)
        let stateText = stateName(state)
        let legacyLine = "\(idx),\(formatSeconds(tMillis)),,,,,,,,,,,,,,\(String(format: "%.2f", Double(speed) / 100)),,\(stateText),\(sanitizeCSV(event))"
        return legacyLine + v12PreviewFields(
            state: stateText,
            event: event,
            engineVersion: engineVersion
        )
    }

    private static func v12PreviewFields(state: String, event: String, engineVersion: String?) -> String {
        guard engineVersion == DetectionEngine.v12AppleSensorFusion.rawValue else {
            return "," + Array(repeating: "", count: v12CSVColumns.count).joined(separator: ",")
        }

        let upperEvent = event.uppercased()
        let takeoff = upperEvent.contains("TAKEOFF") || upperEvent.contains("RESTART") ? "1" : ""
        let jumpEvent = upperEvent.contains("JUMP")
        let rejection = v12RejectionReason(from: event)
        let confidence = v12Confidence(from: event)
        let fields = [
            state,
            "",
            "",
            "",
            "",
            "",
            takeoff,
            jumpEvent ? "1" : "",
            jumpEvent ? "1" : "",
            "",
            "",
            "",
            confidence,
            rejection
        ]
        return "," + fields.map(sanitizeCSV).joined(separator: ",")
    }

    private static func v12RejectionReason(from event: String) -> String {
        let trimmed = event.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "REJECT ") {
            return String(trimmed[range.upperBound...]).components(separatedBy: " ").first ?? ""
        }
        if let range = trimmed.range(of: "ABORT ") {
            return String(trimmed[range.upperBound...]).components(separatedBy: " ").first ?? ""
        }
        return ""
    }

    private static func v12Confidence(from event: String) -> String {
        guard let range = event.range(of: "conf=") else { return "" }
        let tail = event[range.upperBound...]
        let token = tail.prefix { char in
            char.isNumber || char == "." || char == "-"
        }
        return String(token)
    }

    private static func buildCSVShareText(for url: URL, fileSize: String, maxChars: Int) -> String {
        let filename = url.lastPathComponent
        var text = "Kiters Session Log\n"
        text += "File: \(filename)\n"
        text += "Size: \(fileSize)\n\n"

        guard let fh = try? FileHandle(forReadingFrom: url) else { return text }
        let readSize = min(Int((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0), maxChars + 2_000)
        let data = fh.readData(ofLength: readSize)
        try? fh.close()

        guard let content = String(data: data, encoding: .utf8) else { return text }
        let lines = content.components(separatedBy: "\n")
        var csvStart = 0
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                if trimmed.hasPrefix("# session:") || trimmed.hasPrefix("# date:") ||
                   trimmed.hasPrefix("# mode:") || trimmed.hasPrefix("# sensorOnly:") ||
                   trimmed.hasPrefix("# sampleRate:") || trimmed.hasPrefix("# minSpeed") ||
                   trimmed.hasPrefix("# takeoffG") || trimmed.hasPrefix("# landingG") ||
                   trimmed.hasPrefix("# minAirtime") || trimmed.hasPrefix("# maxAirtime") ||
                   trimmed.hasPrefix("# cooldown") {
                    text += trimmed.replacingOccurrences(of: "# ", with: "  ") + "\n"
                }
            } else if trimmed.hasPrefix("idx,") {
                csvStart = i
                break
            } else {
                csvStart = i
                break
            }
        }

        text += "\nCSV DATA:\n"
        for line in lines.dropFirst(csvStart) {
            if text.count + line.count + 1 > maxChars {
                text += "\n... (truncated - send to iPhone for full file)\n"
                break
            }
            text += line + "\n"
        }
        return text
    }

    private static func readEventString(_ fh: FileHandle, length: Int) -> String {
        guard length > 0 else { return "" }
        let data = fh.readData(ofLength: length)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func readUInt8(_ bytes: [UInt8], _ offset: inout Int) -> UInt8 {
        let value = bytes[offset]
        offset += 1
        return value
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: inout Int) -> UInt16 {
        let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        offset += 2
        return value
    }

    private static func readInt16(_ bytes: [UInt8], _ offset: inout Int) -> Int16 {
        Int16(bitPattern: readUInt16(bytes, &offset))
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: inout Int) -> UInt32 {
        let value = UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
        offset += 4
        return value
    }

    private static func readInt32(_ bytes: [UInt8], _ offset: inout Int) -> Int32 {
        Int32(bitPattern: readUInt32(bytes, &offset))
    }

    private static func readUInt64(_ bytes: [UInt8], _ offset: inout Int) -> UInt64 {
        let lo = UInt64(readUInt32(bytes, &offset))
        let hi = UInt64(readUInt32(bytes, &offset))
        return lo | (hi << 32)
    }

    private static func formatSeconds(_ milliseconds: UInt32) -> String {
        String(format: "%.3f", Double(milliseconds) / 1000)
    }

    private static func formatMicroseconds(_ microseconds: UInt64) -> String {
        String(format: "%.6f", Double(microseconds) / 1_000_000)
    }

    private static func formatScaled(_ value: Int16, scale: Double, decimals: Int) -> String {
        guard value != Int16.min else { return "" }
        return String(format: "%.\(decimals)f", Double(value) / scale)
    }

    private static func formatScaled(_ value: Int32, scale: Double, decimals: Int) -> String {
        guard value != Int32.min else { return "" }
        return String(format: "%.\(decimals)f", Double(value) / scale)
    }

    private static func sanitizeCSV(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: ",", with: ";")
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendInt16(_ value: Int16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendInt32(_ value: Int32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendInt64(_ value: Int64) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
