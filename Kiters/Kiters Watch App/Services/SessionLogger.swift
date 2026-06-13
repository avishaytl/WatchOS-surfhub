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

    /// Buffer writes for performance — flush every N lines
    private var buffer = Data()
    private let flushInterval = 250  // ~5 seconds at 50Hz (or ~25s at 10Hz throttled)

    private enum RecordType: UInt8 {
        case sample = 1
        case event = 2
    }

    private struct BinaryLogHeader: Codable {
        let app: String
        let format: String
        let version: Int
        let session: String
        let date: String
        let mode: String
        let devMode: Bool
        let sampleRateHz: Int
        let parameters: BinaryLogParameters
        let columns: [String]
    }

    private struct BinaryLogParameters: Codable {
        let minSpeed: Double
        let takeoffG: Double
        let landingG: Double
        let minAirtime: Double
        let maxAirtime: Double
        let cooldown: Double
    }

    // MARK: - Public API

    /// Start a new log file for this session.
    /// Call once when the session starts.
    func start(sessionId: String, mode: DetectionMode, devMode: Bool) {
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
            startDate = Date()
            sampleIndex = 0
            buffer.removeAll(keepingCapacity: true)
            isActive = true

            write(Self.makeHeaderData(sessionId: sessionId, dateStr: dateStr, mode: mode, devMode: devMode))

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
        guard isActive, let t0 = startDate else { return }

        // Capture all values on the calling thread (fast), then format + write on ioQueue.
        let t = sample.timestamp.timeIntervalSince(t0)
        let ax = sample.accelerationX
        let ay = sample.accelerationY
        let az = sample.accelerationZ
        let aM = sample.accelerationMagnitude
        let gx = sample.rotationX
        let gy = sample.rotationY
        let gz = sample.rotationZ
        let gM = sample.rotationMagnitude
        let gv = sample.gravity
        let baro = sample.pressure
        let baseBaro = baselinePressure
        let spd = speed
        let lg = lowGCount

        ioQueue.async { [self] in
            guard isActive else { return }
            sampleIndex += 1
            buffer.append(Self.makeSampleRecord(
                index: sampleIndex,
                t: t,
                ax: ax, ay: ay, az: az, aM: aM,
                gx: gx, gy: gy, gz: gz, gM: gM,
                gravity: gv,
                baro: baro,
                baseBaro: baseBaro > 0 ? baseBaro : nil,
                speed: spd,
                lowGCount: lg,
                state: state,
                event: event
            ))
            if sampleIndex % flushInterval == 0 {
                flush()
            }
        }
    }

    /// Log a discrete event (state transition, jump detected, etc.)
    func logEvent(_ event: String, state: String = "", speed: Double = 0) {
        guard isActive, let t0 = startDate else { return }
        let t = Date().timeIntervalSince(t0)

        ioQueue.async { [self] in
            guard isActive else { return }
            sampleIndex += 1
            buffer.append(Self.makeEventRecord(
                index: sampleIndex,
                t: t,
                speed: speed,
                state: state,
                event: event
            ))
            flush()
        }
    }

    /// Stop logging and close the file.
    func stop() {
        guard isActive else { return }
        // Drain the queue so every buffered line is written before we close.
        ioQueue.sync {
            flush()
            fileHandle?.closeFile()
            fileHandle = nil
            isActive = false
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
            guard let headerLength = Self.binaryHeaderLength(url) else {
                return max(0, Int(fileSizeBytes / Int64(Self.sampleRecordMinimumSize)))
            }
            let payloadBytes = max(0, fileSizeBytes - Int64(Self.fileHeaderSize + headerLength))
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
    private static let binaryVersion: UInt8 = 1
    private static let fileHeaderSize = 8
    private static let sampleRecordBodySize = 45
    private static let eventRecordBodySize = 13
    private static let sampleRecordMinimumSize = 1 + sampleRecordBodySize
    private static let csvColumns = "idx,t,ax,ay,az,aM,gx,gy,gz,gM,gvX,gvY,gvZ,baro,baseBaro,spd,lowG,state,evt"

    private static func makeHeaderData(sessionId: String, dateStr: String, mode: DetectionMode, devMode: Bool) -> Data {
        let header = BinaryLogHeader(
            app: "Kiters",
            format: "kslog",
            version: Int(binaryVersion),
            session: sessionId,
            date: dateStr,
            mode: mode.displayName,
            devMode: devMode,
            sampleRateHz: 50,
            parameters: BinaryLogParameters(
                minSpeed: mode.minSpeed,
                takeoffG: mode.takeoffG,
                landingG: mode.landingG,
                minAirtime: mode.minAirtime,
                maxAirtime: mode.maxAirtime,
                cooldown: mode.cooldown
            ),
            columns: csvColumns.components(separatedBy: ",")
        )
        let json = (try? JSONEncoder().encode(header)) ?? Data()
        var data = Data(capacity: fileHeaderSize + json.count)
        data.append(contentsOf: magic)
        data.append(binaryVersion)
        data.append(0)
        data.appendUInt16(UInt16(clamping: json.count))
        data.append(json.prefix(Int(UInt16.max)))
        return data
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

    private static func binaryHeaderLength(_ url: URL) -> Int? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let fileHeader = fh.readData(ofLength: fileHeaderSize)
        guard fileHeader.count == fileHeaderSize else { return nil }
        let bytes = [UInt8](fileHeader)
        guard Array(bytes.prefix(4)) == magic else { return nil }
        return Int(UInt16(bytes[6]) | (UInt16(bytes[7]) << 8))
    }

    private static func readBinaryHeader(_ fh: FileHandle) -> BinaryLogHeader? {
        let fileHeader = fh.readData(ofLength: fileHeaderSize)
        guard fileHeader.count == fileHeaderSize else { return nil }
        let bytes = [UInt8](fileHeader)
        guard Array(bytes.prefix(4)) == magic else { return nil }
        let headerLength = Int(UInt16(bytes[6]) | (UInt16(bytes[7]) << 8))
        let headerData = fh.readData(ofLength: headerLength)
        guard headerData.count == headerLength else { return nil }
        return try? JSONDecoder().decode(BinaryLogHeader.self, from: headerData)
    }

    private static func buildBinaryShareText(for url: URL, fileSize: String, maxChars: Int) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return "Kiters Session Log\nFile: \(url.lastPathComponent)\nSize: \(fileSize)\n"
        }
        defer { try? fh.close() }

        guard let header = readBinaryHeader(fh) else {
            return "Kiters Session Log\nFile: \(url.lastPathComponent)\nSize: \(fileSize)\nFormat: binary kslog\n"
        }

        var text = "Kiters Session Log\n"
        text += "File: \(url.lastPathComponent)\n"
        text += "Size: \(fileSize)\n"
        text += "Format: binary kslog v\(header.version)\n"
        text += "session: \(header.session)\n"
        text += "date: \(header.date)\n"
        text += "mode: \(header.mode)\n"
        text += "devMode: \(header.devMode)\n"
        text += "sampleRate: \(header.sampleRateHz) Hz\n"
        text += "minSpeed(m/s): \(String(format: "%.2f", header.parameters.minSpeed))\n"
        text += "takeoffG(g): \(String(format: "%.2f", header.parameters.takeoffG))\n"
        text += "landingG(g): \(String(format: "%.2f", header.parameters.landingG))\n"
        text += "minAirtime(s): \(String(format: "%.2f", header.parameters.minAirtime))\n"
        text += "maxAirtime(s): \(String(format: "%.2f", header.parameters.maxAirtime))\n"
        text += "cooldown(s): \(String(format: "%.2f", header.parameters.cooldown))\n\n"
        text += "CSV preview decoded from binary:\n"
        text += "\(csvColumns)\n"

        while text.count < maxChars {
            let typeData = fh.readData(ofLength: 1)
            guard typeData.count == 1, let type = typeData.first else { break }

            let line: String?
            if type == RecordType.sample.rawValue {
                line = readSamplePreviewLine(fh)
            } else if type == RecordType.event.rawValue {
                line = readEventPreviewLine(fh)
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

    private static func readSamplePreviewLine(_ fh: FileHandle) -> String? {
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

        return [
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
    }

    private static func readEventPreviewLine(_ fh: FileHandle) -> String? {
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
        return "\(idx),\(formatSeconds(tMillis)),,,,,,,,,,,,,,\(String(format: "%.2f", Double(speed) / 100)),,\(stateName(state)),\(sanitizeCSV(event))"
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
                   trimmed.hasPrefix("# mode:") || trimmed.hasPrefix("# devMode:") ||
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

    private static func formatSeconds(_ milliseconds: UInt32) -> String {
        String(format: "%.3f", Double(milliseconds) / 1000)
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

    mutating func appendInt16(_ value: Int16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendInt32(_ value: Int32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
