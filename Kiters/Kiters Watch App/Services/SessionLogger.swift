//
//  SessionLogger.swift
//  iSurf-Watch
//
//  Per-session CSV logger for debugging jump detection.
//  Writes ALL 6 sensor channels at 50 Hz + algorithm internals
//  so logs can be analysed offline in Excel / Python.
//
//  CSV columns (20 total):
//    idx, t,
//    ax, ay, az, aM,           ← user-acceleration (gravity removed)
//    gx, gy, gz, gM,           ← gyroscope (rad/s)
//    gvX, gvY, gvZ,            ← gravity vector
//    baro, baseBaro,            ← current & baseline pressure (hPa)
//    spd,                       ← GPS speed (m/s)
//    lowG, state, evt           ← algorithm internals
//
//  The file header includes the 6 detection parameters so every
//  log is self-documenting.
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
    private var buffer: String = ""
    private let flushInterval = 250  // ~5 seconds at 50Hz (or ~25s at 10Hz throttled)

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
            let filename = "log_\(dateStr)_\(sessionId.prefix(8)).csv"
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
            buffer = ""
            isActive = true

            // ── Write header ──
            var header = "# iSurf Session Log\n"
            header += "# session: \(sessionId)\n"
            header += "# date: \(dateStr)\n"
            header += "# mode: \(mode.displayName)\n"
            header += "# devMode: \(devMode)\n"
            header += "# sampleRate: 50 Hz\n"
            header += "# --- 6 Parameters ---\n"
            header += "# minSpeed(m/s): \(String(format: "%.2f", mode.minSpeed))\n"
            header += "# takeoffG(g): \(String(format: "%.2f", mode.takeoffG))\n"
            header += "# landingG(g): \(String(format: "%.2f", mode.landingG))\n"
            header += "# minAirtime(s): \(String(format: "%.2f", mode.minAirtime))\n"
            header += "# maxAirtime(s): \(String(format: "%.2f", mode.maxAirtime))\n"
            header += "# cooldown(s): \(String(format: "%.2f", mode.cooldown))\n"
            header += "# --- Columns ---\n"
            header += "# ax/ay/az = userAcceleration (g, gravity removed)\n"
            header += "# gx/gy/gz = gyroscope (rad/s)\n"
            header += "# gvX/gvY/gvZ = gravity vector (g)\n"
            header += "# baro = barometric pressure (hPa)\n"
            header += "# baseBaro = rolling baseline pressure (hPa)\n"
            header += "# spd = GPS speed (m/s)\n"
            header += "# lowG = consecutive low-g sample count\n"
            header += "# -----------------------\n"
            header += "idx,t,ax,ay,az,aM,gx,gy,gz,gM,gvX,gvY,gvZ,baro,baseBaro,spd,lowG,state,evt\n"

            write(header)

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
            let gvX = gv.map { String(format: "%.3f", $0.x) } ?? ""
            let gvY = gv.map { String(format: "%.3f", $0.y) } ?? ""
            let gvZ = gv.map { String(format: "%.3f", $0.z) } ?? ""
            let baroStr = baro.map { String(format: "%.2f", $0) } ?? ""
            let baseStr = baseBaro > 0 ? String(format: "%.2f", baseBaro) : ""
            let line = "\(sampleIndex),\(String(format: "%.3f", t)),\(f(ax)),\(f(ay)),\(f(az)),\(f(aM)),\(f(gx)),\(f(gy)),\(f(gz)),\(f(gM)),\(gvX),\(gvY),\(gvZ),\(baroStr),\(baseStr),\(String(format: "%.2f", spd)),\(lg),\(state),\(event)\n"
            buffer += line
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
            // Empty sensor columns — event-only row
            let line = "\(sampleIndex),\(String(format: "%.3f", t)),,,,,,,,,,,,,,\(String(format: "%.2f", speed)),,\(state),\(event)\n"
            buffer += line
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
            .filter { $0.pathExtension == "csv" }
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

    // MARK: - Private Helpers

    private var logsDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("session_logs", isDirectory: true)
    }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        write(buffer)
        buffer = ""
    }

    private func f(_ v: Double) -> String {
        String(format: "%.3f", v)
    }

    private static let fileDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()
}
