import Foundation

enum SensorFormat: String {
    case coreMotion  // user-acceleration in m/s², gravity in m/s²
    case android     // linear (user) acceleration in m/s², gravity in g-units (unit vector)
    case onDevice    // watchOS SessionLogger CSV: accel in g, gyro in rad/s, gravity in g-units
}

struct LoadedLog {
    var samples: [IMUSample]
    var speeds: [Double?]
    var events: [LoadedLogEvent]
    var absoluteAltitudes: [LoadedAbsoluteAltitude]
    var v13AuditRecords: [V13AuditRecord]
    var format: SensorFormat
    var detectedRate: Double  // Hz
    var sourceURL: URL

    /// Full decoded timeline. Motion can stop while altitude/audit records keep
    /// arriving, so report duration must not be derived from IMU alone.
    var timelineDurationSec: Double {
        var firstT: TimeInterval?
        var lastT: TimeInterval?

        func include(_ t: TimeInterval) {
            guard t.isFinite else { return }
            firstT = min(firstT ?? t, t)
            lastT = max(lastT ?? t, t)
        }

        samples.forEach {
            include($0.motionTimestamp ?? $0.timestamp.timeIntervalSince1970)
        }
        absoluteAltitudes.forEach { include($0.sensorT) }
        events.forEach { include($0.timestamp.timeIntervalSince1970) }
        v13AuditRecords.forEach { include($0.monotonicTime) }

        guard let firstT, let lastT else { return 0 }
        return max(0, lastT - firstT)
    }
}

struct LoadedLogEvent {
    let timestamp: Date
    let message: String
}

struct LoadedAbsoluteAltitude {
    let sensorT: TimeInterval
    let altitudeM: Double
    let accuracyM: Double?
    let precisionM: Double?
}

enum Loader {
    /// Load a CSV or JSON log into IMUSample[]. Format is auto-detected
    /// from the gravity-magnitude statistics unless `forceFormat` is set.
    static func load(_ url: URL, forceFormat: SensorFormat? = nil) throws -> LoadedLog {
        let (raw, hint, absoluteAltitudes, v13AuditRecords) = try loadRaw(url)
        guard !raw.isEmpty else {
            throw LoaderError.empty
        }
        let format = forceFormat ?? hint ?? FormatDetector.detect(raw)
        let samples = raw.map { $0.toIMUSample(format: format) }
        let speeds = raw.map { $0.speed }
        let events = raw.compactMap { row -> LoadedLogEvent? in
            guard let event = row.event?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !event.isEmpty else { return nil }
            return LoadedLogEvent(timestamp: Date(timeIntervalSince1970: row.t), message: event)
        }
        let rate = estimateRate(samples)
        return LoadedLog(samples: samples, speeds: speeds, events: events, absoluteAltitudes: absoluteAltitudes, v13AuditRecords: v13AuditRecords, format: format, detectedRate: rate, sourceURL: url)
    }

    private static func loadRaw(_ url: URL) throws -> ([RawRow], SensorFormat?, [LoadedAbsoluteAltitude], [V13AuditRecord]) {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)
        if ext == "json" {
            return try parseJSONLog(data)
        } else if ext == "csv" {
            let (rows, hint) = try parseCSV(data)
            return (rows, hint, [], [])
        } else if ext == "kslog" {
            return try parseKSLog(data)
        }
        throw LoaderError.unsupportedExtension(ext)
    }

    private struct SessionLogEnvelope: Decodable {
        let contentType: String?
        let contentEncoding: String?
        let content: String?
    }

    private static func parseJSONLog(_ data: Data) throws -> ([RawRow], SensorFormat?, [LoadedAbsoluteAltitude], [V13AuditRecord]) {
        if let envelope = try? JSONDecoder().decode(SessionLogEnvelope.self, from: data),
           let content = envelope.content {
            let contentType = envelope.contentType?.lowercased() ?? ""
            let encoding = envelope.contentEncoding?.lowercased() ?? ""
            if contentType.contains("csv"), let csvData = content.data(using: .utf8) {
                let (rows, hint) = try parseCSV(csvData)
                return (rows, hint, [], [])
            }
            if encoding == "base64" || contentType.contains("kiters-session-log") || contentType.contains("kslog") {
                guard let blob = Data(base64Encoded: content, options: [.ignoreUnknownCharacters]) else {
                    throw LoaderError.encoding
                }
                return try parseKSLog(blob)
            }
        }

        let decoder = JSONDecoder()
        return (try decoder.decode([RawRow].self, from: data), nil, [], [])
    }

    private static func parseKSLog(_ data: Data) throws -> ([RawRow], SensorFormat?, [LoadedAbsoluteAltitude], [V13AuditRecord]) {
        let b = [UInt8](data)
        guard b.count >= 7,
              b[0] == 0x4b, b[1] == 0x53, b[2] == 0x4c, b[3] == 0x47 else {
            throw LoaderError.encoding
        }
        if b[4] == 2 {
            return try parseKSLG2(b)
        }

        guard b.count >= 8 else { throw LoaderError.encoding }
        let headerLength = Int(readUInt16(b, 6))
        var i = 8 + headerLength
        var rows: [RawRow] = []
        rows.reserveCapacity(max(0, (b.count - i) / 46))

        while i < b.count {
            let type = b[i]
            if type == 1 {
                guard i + 46 <= b.count else { break }
                let tMillis = readUInt32(b, i + 5)
                let ax = scaled(readInt16(b, i + 9), 1000)
                let ay = scaled(readInt16(b, i + 11), 1000)
                let az = scaled(readInt16(b, i + 13), 1000)
                let gx = scaled(readInt16(b, i + 17), 1000)
                let gy = scaled(readInt16(b, i + 19), 1000)
                let gz = scaled(readInt16(b, i + 21), 1000)
                let gvX = scaled(readInt16(b, i + 25), 1000)
                let gvY = scaled(readInt16(b, i + 27), 1000)
                let gvZ = scaled(readInt16(b, i + 29), 1000)
                let baro = scaled(readInt32(b, i + 31), 100)
                let speed = Double(readUInt16(b, i + 39)) / 100.0
                let eventLength = Int(readUInt16(b, i + 44))
                let event = eventLength > 0
                    ? String(bytes: b[(i + 46)..<(i + 46 + eventLength)], encoding: .utf8)
                    : nil
                rows.append(RawRow(
                    timestamp: Double(tMillis) / 1000.0,
                    accX: ax ?? 0, accY: ay ?? 0, accZ: az ?? 0,
                    gravX: gvX ?? 0, gravY: gvY ?? 0, gravZ: gvZ ?? 0,
                    baro: baro ?? 0,
                    speed: speed,
                    gyrX: gx ?? 0, gyrY: gy ?? 0, gyrZ: gz ?? 0,
                    event: event
                ))
                i += 46 + eventLength
            } else if type == 2 {
                guard i + 14 <= b.count else { break }
                let tMillis = readUInt32(b, i + 5)
                let speed = Double(readUInt16(b, i + 9)) / 100.0
                let eventLength = Int(readUInt16(b, i + 12))
                let event = eventLength > 0
                    ? String(bytes: b[(i + 14)..<(i + 14 + eventLength)], encoding: .utf8)
                    : nil
                rows.append(RawRow(
                    timestamp: Double(tMillis) / 1000.0,
                    accX: 0, accY: 0, accZ: 0,
                    gravX: 0, gravY: 0, gravZ: -1,
                    baro: 0,
                    speed: speed,
                    gyrX: 0, gyrY: 0, gyrZ: 0,
                    event: event
                ))
                i += 14 + eventLength
            } else {
                break
            }
        }
        return (rows, .onDevice, [], [])
    }

    private struct KSLG2Header: Decodable {
        let t0BootUs: UInt64?
    }

    private struct KSLG2Baro {
        let t: Double
        let relAlt: Double?
        let pressure: Double?
    }

    private struct KSLG2AbsAlt {
        let t: Double
        let alt: Double?
        let accuracy: Double?
        let precision: Double?
    }

    private static func parseKSLG2(_ b: [UInt8]) throws -> ([RawRow], SensorFormat?, [LoadedAbsoluteAltitude], [V13AuditRecord]) {
        let headerLength = Int(readUInt16(b, 5))
        let headerStart = 7
        let payloadStart = headerStart + headerLength
        guard payloadStart <= b.count else { throw LoaderError.encoding }

        let headerData = Data(b[headerStart..<payloadStart])
        let header = try? JSONDecoder().decode(KSLG2Header.self, from: headerData)
        let t0BootUs = header?.t0BootUs

        func monotonicSeconds(relativeUs: UInt64) -> Double {
            if let t0BootUs {
                return Double(t0BootUs + relativeUs) / 1_000_000.0
            }
            return Double(relativeUs) / 1_000_000.0
        }

        var i = payloadStart
        var rows: [RawRow] = []
        rows.reserveCapacity(max(0, (b.count - i) / 29))

        var latestBaro: KSLG2Baro?
        var latestAbsAlt: KSLG2AbsAlt?
        var latestSpeed: Double?
        var latestSubmerged: Bool?
        var latestWaterDepth: Double?
        var pendingEvents: [String] = []
        var absoluteAltitudes: [LoadedAbsoluteAltitude] = []
        var v13AuditRecords: [V13AuditRecord] = []

        while i < b.count {
            let tag = b[i]
            switch tag {
            case 3: // MOTION
                guard i + 29 <= b.count else { i = b.count; break }
                let relUs = readUInt64(b, i + 1)
                let t = monotonicSeconds(relativeUs: relUs)
                let ax = scaled(readInt16(b, i + 9), 1000) ?? 0
                let ay = scaled(readInt16(b, i + 11), 1000) ?? 0
                let az = scaled(readInt16(b, i + 13), 1000) ?? 0
                let rx = scaled(readInt16(b, i + 15), 1000) ?? 0
                let ry = scaled(readInt16(b, i + 17), 1000) ?? 0
                let rz = scaled(readInt16(b, i + 19), 1000) ?? 0
                let qw = scaled(readInt16(b, i + 21), 10000)
                let qx = scaled(readInt16(b, i + 23), 10000)
                let qy = scaled(readInt16(b, i + 25), 10000)
                let qz = scaled(readInt16(b, i + 27), 10000)

                rows.append(RawRow(
                    timestamp: t,
                    accX: ax, accY: ay, accZ: az,
                    gravX: 0, gravY: 0, gravZ: -1,
                    baro: latestBaro?.pressure ?? 0,
                    speed: latestSpeed,
                    gyrX: rx, gyrY: ry, gyrZ: rz,
                    event: pendingEvents.isEmpty ? nil : pendingEvents.joined(separator: "; "),
                    motionTimestamp: t,
                    quatW: qw,
                    quatX: qx,
                    quatY: qy,
                    quatZ: qz,
                    relativeAltitude: latestBaro?.relAlt,
                    barometerTimestamp: latestBaro?.t,
                    absoluteAltitude: latestAbsAlt?.alt,
                    absoluteAltitudeAccuracy: latestAbsAlt?.accuracy,
                    absoluteAltitudePrecision: latestAbsAlt?.precision,
                    absoluteAltitudeTimestamp: latestAbsAlt?.t,
                    submerged: latestSubmerged,
                    waterDepth: latestWaterDepth
                ))
                pendingEvents.removeAll(keepingCapacity: true)
                i += 29

            case 4: // RAWACC
                guard i + 15 <= b.count else { i = b.count; break }
                i += 15

            case 5: // BARO
                guard i + 17 <= b.count else { i = b.count; break }
                let t = monotonicSeconds(relativeUs: readUInt64(b, i + 1))
                latestBaro = KSLG2Baro(
                    t: t,
                    relAlt: scaled(readInt32(b, i + 9), 1000),
                    pressure: scaled(readInt32(b, i + 13), 1000)
                )
                i += 17

            case 6: // ABSALT
                guard i + 21 <= b.count else { i = b.count; break }
                let t = monotonicSeconds(relativeUs: readUInt64(b, i + 1))
                latestAbsAlt = KSLG2AbsAlt(
                    t: t,
                    alt: scaled(readInt32(b, i + 9), 1000),
                    accuracy: scaled(readInt32(b, i + 13), 1000),
                    precision: scaled(readInt32(b, i + 17), 1000)
                )
                if let altitudeM = latestAbsAlt?.alt {
                    absoluteAltitudes.append(LoadedAbsoluteAltitude(
                        sensorT: t,
                        altitudeM: altitudeM,
                        accuracyM: latestAbsAlt?.accuracy,
                        precisionM: latestAbsAlt?.precision
                    ))
                }
                i += 21

            case 7: // GPS
                guard i + 29 <= b.count else { i = b.count; break }
                latestSpeed = scaled(readUInt16(b, i + 17), 100)
                i += 29

            case 8: // SUBMERSION
                guard i + 12 <= b.count else { i = b.count; break }
                let kind = b[i + 9]
                let value = scaled(readInt16(b, i + 10), kind == 0 ? 1 : 100)
                if kind == 0 {
                    latestSubmerged = (value ?? 0) >= 0.5
                } else if kind == 1 {
                    latestWaterDepth = value
                }
                i += 12

            case 9: // EVENT
                guard i + 12 <= b.count else { i = b.count; break }
                let relUs = readUInt64(b, i + 1)
                let t = monotonicSeconds(relativeUs: relUs)
                let eventLength = Int(readUInt16(b, i + 10))
                guard i + 12 + eventLength <= b.count else { i = b.count; break }
                let event = eventLength > 0
                    ? String(bytes: b[(i + 12)..<(i + 12 + eventLength)], encoding: .utf8)
                    : nil
                if let event, !event.isEmpty {
                    pendingEvents.append(String(format: "%.3f:%@", t, event))
                }
                i += 12 + eventLength

            case 10: // SYNC
                guard i + 19 <= b.count else { i = b.count; break }
                let labelLength = Int(readUInt16(b, i + 17))
                guard i + 19 + labelLength <= b.count else { i = b.count; break }
                i += 19 + labelLength

            case 11: // STATUS
                guard i + 16 <= b.count else { i = b.count; break }
                i += 16

            case 12: // V13_AUDIT: tUs + UInt32 JSON length + V13AuditRecord
                guard i + 13 <= b.count else { i = b.count; break }
                let payloadLength = Int(readUInt32(b, i + 9))
                guard payloadLength >= 0, i + 13 + payloadLength <= b.count else {
                    i = b.count
                    break
                }
                let payload = Data(b[(i + 13)..<(i + 13 + payloadLength)])
                if let record = try? JSONDecoder().decode(V13AuditRecord.self, from: payload) {
                    v13AuditRecords.append(record)
                }
                i += 13 + payloadLength

            default:
                i = b.count
            }
        }

        return (rows, .onDevice, absoluteAltitudes, v13AuditRecords)
    }

    private static func readUInt16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func readUInt64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(readUInt32(b, i)) | (UInt64(readUInt32(b, i + 4)) << 32)
    }

    private static func readUInt32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(readUInt16(b, i)) | (UInt32(readUInt16(b, i + 2)) << 16)
    }

    private static func readInt16(_ b: [UInt8], _ i: Int) -> Int16 {
        Int16(bitPattern: readUInt16(b, i))
    }

    private static func readInt32(_ b: [UInt8], _ i: Int) -> Int32 {
        Int32(bitPattern: readUInt32(b, i))
    }

    private static func scaled(_ value: Int16, _ scale: Double) -> Double? {
        value == Int16.min ? nil : Double(value) / scale
    }

    private static func scaled(_ value: Int32, _ scale: Double) -> Double? {
        value == Int32.min ? nil : Double(value) / scale
    }

    private static func scaled(_ value: UInt16, _ scale: Double) -> Double? {
        value == UInt16.max ? nil : Double(value) / scale
    }

    private static func parseCSV(_ data: Data) throws -> ([RawRow], SensorFormat?) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoaderError.encoding
        }
        // Skip SessionLogger comment lines (lines starting with '#')
        let allLines = text.split(whereSeparator: \.isNewline)
        let nonCommentLines = allLines.filter { !$0.hasPrefix("#") }
        guard !nonCommentLines.isEmpty else { return ([], nil) }

        let rawHeaderCols = nonCommentLines.first!
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let dataLines = nonCommentLines.dropFirst()

        // Detect on-device SessionLogger format: has 'ax' column but not 'accX'
        let isOnDevice = rawHeaderCols.contains("ax") && !rawHeaderCols.contains("accX")
        let formatHint: SensorFormat? = isOnDevice ? .onDevice : nil

        // Normalise known column aliases to the standard names expected below.
        let commonAliases: [String: String] = [
            "motionT": "motionTimestamp",
            "motionTime": "motionTimestamp",
            "baroT": "barometerTimestamp",
            "baroTime": "barometerTimestamp",
            "relAlt": "relativeAltitude",
            "relativeAlt": "relativeAltitude",
            "absAlt": "absoluteAltitude",
            "absoluteAlt": "absoluteAltitude",
            "absAltT": "absoluteAltitudeTimestamp",
            "absAltTime": "absoluteAltitudeTimestamp",
            "qw": "quatW", "qx": "quatX", "qy": "quatY", "qz": "quatZ",
            "attitudeW": "quatW", "attitudeX": "quatX",
            "attitudeY": "quatY", "attitudeZ": "quatZ",
            "waterDepthM": "waterDepth",
            "waterPressureHPa": "waterPressure"
        ]
        let onDeviceAliases: [String: String] = [
            "t": "timestamp",
            "ax": "accX", "ay": "accY", "az": "accZ",
            "gvX": "gravX", "gvY": "gravY", "gvZ": "gravZ",
            "gx": "gyrX", "gy": "gyrY", "gz": "gyrZ"
        ]
        let cols = rawHeaderCols.map { raw -> String in
            let onDeviceName = isOnDevice ? (onDeviceAliases[raw] ?? raw) : raw
            return commonAliases[onDeviceName] ?? onDeviceName
        }

        func idx(_ name: String) -> Int? { cols.firstIndex(of: name) }
        let map = (
            t:    idx("timestamp"),
            ax:   idx("accX"),
            ay:   idx("accY"),
            az:   idx("accZ"),
            gx:   idx("gravX"),
            gy:   idx("gravY"),
            gz:   idx("gravZ"),
            baro: idx("baro"),
            spd:  idx("spd"),
            wx:   idx("gyrX"),
            wy:   idx("gyrY"),
            wz:   idx("gyrZ"),
            evt:  idx("evt"),
            motionT: idx("motionTimestamp"),
            qw: idx("quatW"),
            qx: idx("quatX"),
            qy: idx("quatY"),
            qz: idx("quatZ"),
            relAlt: idx("relativeAltitude"),
            baroT: idx("barometerTimestamp"),
            absAlt: idx("absoluteAltitude"),
            absAltAccuracy: idx("absoluteAltitudeAccuracy"),
            absAltPrecision: idx("absoluteAltitudePrecision"),
            absAltT: idx("absoluteAltitudeTimestamp"),
            submerged: idx("submerged"),
            waterDepth: idx("waterDepth"),
            waterPressure: idx("waterPressure")
        )
        guard let ti = map.t, let axi = map.ax else {
            throw LoaderError.missingColumns
        }

        var rows: [RawRow] = []
        rows.reserveCapacity(dataLines.count)
        for line in dataLines {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            guard f.count >= cols.count else { continue }
            let ts = parseTimestamp(f[ti])
            func optionalDouble(_ index: Int?) -> Double? {
                guard let index else { return nil }
                let value = f[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                return Double(value)
            }
            func optionalBool(_ index: Int?) -> Bool? {
                guard let index else { return nil }
                let value = f[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                switch value {
                case "1", "true", "yes", "y": return true
                case "0", "false", "no", "n": return false
                default: return nil
                }
            }
            let row = RawRow(
                timestamp: ts,
                accX: Double(f[axi]) ?? 0,
                accY: map.ay.flatMap { Double(f[$0]) } ?? 0,
                accZ: map.az.flatMap { Double(f[$0]) } ?? 0,
                gravX: map.gx.flatMap { Double(f[$0]) } ?? 0,
                gravY: map.gy.flatMap { Double(f[$0]) } ?? 0,
                gravZ: map.gz.flatMap { Double(f[$0]) } ?? 0,
                baro: map.baro.flatMap { Double(f[$0]) } ?? 0,
                speed: map.spd.flatMap { Double(f[$0]) },
                gyrX: map.wx.flatMap { Double(f[$0]) } ?? 0,
                gyrY: map.wy.flatMap { Double(f[$0]) } ?? 0,
                gyrZ: map.wz.flatMap { Double(f[$0]) } ?? 0,
                event: map.evt.flatMap { f[$0] },
                motionTimestamp: optionalDouble(map.motionT),
                quatW: optionalDouble(map.qw),
                quatX: optionalDouble(map.qx),
                quatY: optionalDouble(map.qy),
                quatZ: optionalDouble(map.qz),
                relativeAltitude: optionalDouble(map.relAlt),
                barometerTimestamp: optionalDouble(map.baroT),
                absoluteAltitude: optionalDouble(map.absAlt),
                absoluteAltitudeAccuracy: optionalDouble(map.absAltAccuracy),
                absoluteAltitudePrecision: optionalDouble(map.absAltPrecision),
                absoluteAltitudeTimestamp: optionalDouble(map.absAltT),
                submerged: optionalBool(map.submerged),
                waterDepth: optionalDouble(map.waterDepth),
                waterPressure: optionalDouble(map.waterPressure)
            )
            rows.append(row)
        }
        return (rows, formatHint)
    }

    private static func parseTimestamp(_ s: String) -> Double {
        // Accept either a numeric seconds offset or an ISO8601 string.
        if let v = Double(s) { return v }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        // Fallback: try plain "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        if let d = df.date(from: s) { return d.timeIntervalSince1970 }
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = df.date(from: s) { return d.timeIntervalSince1970 }
        return 0
    }

    private static func estimateRate(_ samples: [IMUSample]) -> Double {
        guard samples.count > 10 else { return 0 }
        let dt = samples.last!.timestamp.timeIntervalSince(samples.first!.timestamp)
        guard dt > 0 else { return 0 }
        return Double(samples.count - 1) / dt
    }
}

enum LoaderError: Error, CustomStringConvertible {
    case empty
    case unsupportedExtension(String)
    case encoding
    case missingColumns

    var description: String {
        switch self {
        case .empty: return "log file is empty"
        case .unsupportedExtension(let e): return "unsupported extension: .\(e)"
        case .encoding: return "could not decode file as UTF-8"
        case .missingColumns: return "CSV missing required columns (timestamp, accX, ...)"
        }
    }
}

struct RawRow: Decodable {
    let timestamp: TimestampValue
    let accX: Double
    let accY: Double
    let accZ: Double
    let gravX: Double
    let gravY: Double
    let gravZ: Double
    let baro: Double
    let speed: Double?
    let gyrX: Double
    let gyrY: Double
    let gyrZ: Double
    let event: String?
    let motionTimestamp: Double?
    let quatW: Double?
    let quatX: Double?
    let quatY: Double?
    let quatZ: Double?
    let relativeAltitude: Double?
    let barometerTimestamp: Double?
    let absoluteAltitude: Double?
    let absoluteAltitudeAccuracy: Double?
    let absoluteAltitudePrecision: Double?
    let absoluteAltitudeTimestamp: Double?
    let submerged: Bool?
    let waterDepth: Double?
    let waterPressure: Double?

    init(timestamp: Double, accX: Double, accY: Double, accZ: Double,
         gravX: Double, gravY: Double, gravZ: Double, baro: Double,
         speed: Double? = nil,
         gyrX: Double, gyrY: Double, gyrZ: Double,
         event: String? = nil,
         motionTimestamp: Double? = nil,
         quatW: Double? = nil,
         quatX: Double? = nil,
         quatY: Double? = nil,
         quatZ: Double? = nil,
         relativeAltitude: Double? = nil,
         barometerTimestamp: Double? = nil,
         absoluteAltitude: Double? = nil,
         absoluteAltitudeAccuracy: Double? = nil,
         absoluteAltitudePrecision: Double? = nil,
         absoluteAltitudeTimestamp: Double? = nil,
         submerged: Bool? = nil,
         waterDepth: Double? = nil,
         waterPressure: Double? = nil) {
        self.timestamp = TimestampValue(value: timestamp)
        self.accX = accX; self.accY = accY; self.accZ = accZ
        self.gravX = gravX; self.gravY = gravY; self.gravZ = gravZ
        self.baro = baro
        self.speed = speed
        self.gyrX = gyrX; self.gyrY = gyrY; self.gyrZ = gyrZ
        self.event = event
        self.motionTimestamp = motionTimestamp
        self.quatW = quatW
        self.quatX = quatX
        self.quatY = quatY
        self.quatZ = quatZ
        self.relativeAltitude = relativeAltitude
        self.barometerTimestamp = barometerTimestamp
        self.absoluteAltitude = absoluteAltitude
        self.absoluteAltitudeAccuracy = absoluteAltitudeAccuracy
        self.absoluteAltitudePrecision = absoluteAltitudePrecision
        self.absoluteAltitudeTimestamp = absoluteAltitudeTimestamp
        self.submerged = submerged
        self.waterDepth = waterDepth
        self.waterPressure = waterPressure
    }

    var t: Double { timestamp.value }

    func toIMUSample(format: SensorFormat) -> IMUSample {
        let date: Date
        if let motionTimestamp {
            let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
            date = Date(timeIntervalSince1970: bootWallClock + motionTimestamp)
        } else {
            date = Date(timeIntervalSince1970: t)
        }
        let userAx, userAy, userAz: Double
        let gx, gy, gz: Double  // gravity in m/s² (CoreMotion convention used downstream)
        let wx, wy, wz: Double  // gyro in rad/s (CoreMotion convention)

        switch format {
        case .coreMotion:
            // accX/Y/Z are user-accel m/s², gravX/Y/Z are m/s² (|g|≈9.8),
            // gyro is rad/s.
            userAx = accX; userAy = accY; userAz = accZ
            gx = gravX; gy = gravY; gz = gravZ
            wx = gyrX; wy = gyrY; wz = gyrZ
        case .android:
            // accX/Y/Z is LINEAR (user) acceleration in m/s² (gravity already removed),
            // gravX/Y/Z is the gravity unit vector in g-units (|g|≈1),
            // gyro is deg/s (Android Sensor.TYPE_GYROSCOPE on-screen units).
            userAx = accX; userAy = accY; userAz = accZ
            gx = gravX * 9.81
            gy = gravY * 9.81
            gz = gravZ * 9.81
            let degToRad = Double.pi / 180.0
            wx = gyrX * degToRad
            wy = gyrY * degToRad
            wz = gyrZ * degToRad
        case .onDevice:
            // watchOS SessionLogger CSV: accel already in g, gyro already in rad/s,
            // gravity already in g-units. Scale to m/s² so the shared `* inv` below
            // converts back to g — net effect is identity (values pass through unchanged).
            userAx = accX * 9.81; userAy = accY * 9.81; userAz = accZ * 9.81
            gx = gravX * 9.81; gy = gravY * 9.81; gz = gravZ * 9.81
            wx = gyrX; wy = gyrY; wz = gyrZ
        }

        // JumpDetector expects userAcceleration in **g** (its accelerationMagnitude
        // is compared to landingG/takeoffG which are g-thresholds).
        // The watchOS path stores userAccel in g already (CMDeviceMotion does it).
        // We mirror that contract here: divide by 9.81 once before storing.
        let inv = 1.0 / 9.81
        let attitudeQuaternion: MotionQuaternion?
        if let quatW, let quatX, let quatY, let quatZ {
            attitudeQuaternion = MotionQuaternion(w: quatW, x: quatX, y: quatY, z: quatZ)
        } else {
            attitudeQuaternion = nil
        }
        return IMUSample(
            timestamp: date,
            accelerationX: userAx * inv,
            accelerationY: userAy * inv,
            accelerationZ: userAz * inv,
            rotationX: wx,
            rotationY: wy,
            rotationZ: wz,
            gravity: Vector3(x: gx * inv, y: gy * inv, z: gz * inv),
            pressure: baro > 0 ? baro : nil,
            motionTimestamp: motionTimestamp,
            relativeAltitude: relativeAltitude,
            barometerTimestamp: barometerTimestamp,
            absoluteAltitude: absoluteAltitude,
            absoluteAltitudeAccuracy: absoluteAltitudeAccuracy,
            absoluteAltitudePrecision: absoluteAltitudePrecision,
            absoluteAltitudeTimestamp: absoluteAltitudeTimestamp,
            attitudeQuaternion: attitudeQuaternion,
            submerged: submerged,
            waterDepth: waterDepth,
            waterPressure: waterPressure
        )
    }
}

/// Decodes a timestamp from either a JSON number or string.
struct TimestampValue: Decodable {
    let value: Double  // seconds since 1970

    init(value: Double) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            self.value = d
        } else {
            let s = try c.decode(String.self)
            self.value = Loader.publicParseTimestamp(s)
        }
    }
}

extension Loader {
    static func publicParseTimestamp(_ s: String) -> Double { parseTimestamp(s) }
}
