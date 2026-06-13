import Foundation

enum SensorFormat: String {
    case coreMotion  // user-acceleration in m/s², gravity in m/s²
    case android     // linear (user) acceleration in m/s², gravity in g-units (unit vector)
    case onDevice    // watchOS SessionLogger CSV: accel in g, gyro in rad/s, gravity in g-units
}

struct LoadedLog {
    var samples: [IMUSample]
    var speeds: [Double?]
    var format: SensorFormat
    var detectedRate: Double  // Hz
    var sourceURL: URL
}

enum Loader {
    /// Load a CSV or JSON log into IMUSample[]. Format is auto-detected
    /// from the gravity-magnitude statistics unless `forceFormat` is set.
    static func load(_ url: URL, forceFormat: SensorFormat? = nil) throws -> LoadedLog {
        let (raw, hint) = try loadRaw(url)
        guard !raw.isEmpty else {
            throw LoaderError.empty
        }
        let format = forceFormat ?? hint ?? FormatDetector.detect(raw)
        let samples = raw.map { $0.toIMUSample(format: format) }
        let speeds = raw.map { $0.speed }
        let rate = estimateRate(samples)
        return LoadedLog(samples: samples, speeds: speeds, format: format, detectedRate: rate, sourceURL: url)
    }

    private static func loadRaw(_ url: URL) throws -> ([RawRow], SensorFormat?) {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)
        if ext == "json" {
            return try parseJSONLog(data)
        } else if ext == "csv" {
            return try parseCSV(data)
        }
        throw LoaderError.unsupportedExtension(ext)
    }

    private struct SessionLogEnvelope: Decodable {
        let contentType: String?
        let content: String?
    }

    private static func parseJSONLog(_ data: Data) throws -> ([RawRow], SensorFormat?) {
        if let envelope = try? JSONDecoder().decode(SessionLogEnvelope.self, from: data),
           envelope.contentType?.lowercased().contains("csv") == true,
           let content = envelope.content,
           let csvData = content.data(using: .utf8) {
            return try parseCSV(csvData)
        }

        let decoder = JSONDecoder()
        return (try decoder.decode([RawRow].self, from: data), nil)
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

        // Normalise on-device column names to the standard names expected below
        let onDeviceAliases: [String: String] = [
            "t": "timestamp",
            "ax": "accX", "ay": "accY", "az": "accZ",
            "gvX": "gravX", "gvY": "gravY", "gvZ": "gravZ",
            "gx": "gyrX", "gy": "gyrY", "gz": "gyrZ"
        ]
        let cols = isOnDevice
            ? rawHeaderCols.map { onDeviceAliases[$0] ?? $0 }
            : rawHeaderCols

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
            wz:   idx("gyrZ")
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
                gyrZ: map.wz.flatMap { Double(f[$0]) } ?? 0
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

    init(timestamp: Double, accX: Double, accY: Double, accZ: Double,
         gravX: Double, gravY: Double, gravZ: Double, baro: Double,
         speed: Double? = nil,
         gyrX: Double, gyrY: Double, gyrZ: Double) {
        self.timestamp = TimestampValue(value: timestamp)
        self.accX = accX; self.accY = accY; self.accZ = accZ
        self.gravX = gravX; self.gravY = gravY; self.gravZ = gravZ
        self.baro = baro
        self.speed = speed
        self.gyrX = gyrX; self.gyrY = gyrY; self.gyrZ = gyrZ
    }

    var t: Double { timestamp.value }

    func toIMUSample(format: SensorFormat) -> IMUSample {
        let date = Date(timeIntervalSince1970: t)
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
        return IMUSample(
            timestamp: date,
            accelerationX: userAx * inv,
            accelerationY: userAy * inv,
            accelerationZ: userAz * inv,
            rotationX: wx,
            rotationY: wy,
            rotationZ: wz,
            gravity: Vector3(x: gx * inv, y: gy * inv, z: gz * inv),
            pressure: baro > 0 ? baro : nil
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
