//
//  Session.swift
//  iSurf-Watch
//
//  Data models for tracking sessions and jumps
//

import Foundation
import CoreLocation

// MARK: - Session Model
struct Session: Identifiable, Codable {
    let id: String
    var startTime: Date
    var endTime: Date?
    var sport: Sport
    var status: SessionStatus
    var gpsPoints: [GPSPoint]
    var imuSamples: [IMUSample]
    var jumps: [Jump]

    /// HealthKit workout aggregates frozen when the session ends. Optional so
    /// sessions recorded before health upload support decode unchanged, and so
    /// an offline retry reuses the original session's values rather than live
    /// metrics from a later workout.
    var activeCalories: Int?
    var maxHeartRate: Int?

    /// Cached cumulative GPS distance in metres, updated incrementally as
    /// points are appended. Falls back to a one-shot recompute if zero (e.g.
    /// for sessions decoded from older payloads that didn't store it).
    var cachedDistance: Double = 0

    // Computed properties
    var duration: TimeInterval {
        let end = endTime ?? Date()
        return end.timeIntervalSince(startTime)
    }

    var distance: Double {
        if cachedDistance > 0 { return cachedDistance }
        return calculateTotalDistance()
    }
    
    var maxSpeed: Double {
        gpsPoints.map { $0.speed }.max() ?? 0
    }
    
    var avgSpeed: Double {
        guard !gpsPoints.isEmpty else { return 0 }
        let totalSpeed = gpsPoints.map { $0.speed }.reduce(0, +)
        return totalSpeed / Double(gpsPoints.count)
    }
    
    init(sport: Sport) {
        self.id = UUID().uuidString
        self.startTime = Date()
        self.sport = sport
        self.status = .active
        self.gpsPoints = []
        self.imuSamples = []
        self.jumps = []
        self.activeCalories = nil
        self.maxHeartRate = nil
    }
    
    private func calculateTotalDistance() -> Double {
        guard gpsPoints.count > 1 else { return 0 }
        
        var totalDistance: Double = 0
        for i in 1..<gpsPoints.count {
            let point1 = CLLocation(
                latitude: gpsPoints[i-1].latitude,
                longitude: gpsPoints[i-1].longitude
            )
            let point2 = CLLocation(
                latitude: gpsPoints[i].latitude,
                longitude: gpsPoints[i].longitude
            )
            totalDistance += point2.distance(from: point1)
        }
        return totalDistance
    }
}

// MARK: - Jump Model
struct Jump: Identifiable, Codable {
    let id: String
    var sessionId: String
    var startTime: Date
    var endTime: Date
    var height: Double          // metres — barometer-based (primary) or kinematic fallback
    var airtime: Double         // seconds
    var jumpDistance: Double    // metres, horizontal GPS interpolation over airtime
    var rotations: Int
    var confidence: Double      // 0–100
    var imuSamples: [IMUSample]
    /// Time from takeoff to apex (peak height), seconds. nil if not computed.
    var apexTime: Double?
    /// V12 absolute-altitude metadata. Optional so older sessions and older
    /// engines decode unchanged.
    var heightSource: String?
    var absoluteTakeoffAltitude: Double?
    var absoluteApexAltitude: Double?
    var absoluteLandingAltitude: Double?
    var takeoffSpeed: Double?
    var landingSpeed: Double?
    /// V14 relative-height layer diagnostics. Optional so older sessions and
    /// older engines decode unchanged. `heightConfidence` can be low/zero
    /// (heightSource == "unavailable") on a jump that is still real — see
    /// `detectionConfidence`, which reflects the IMU signature alone.
    var detectionConfidence: Double?
    var heightConfidence: Double?
    var baselineQuality: Double?
    var heightFailureReason: String?
    /// V15 GPS ride verification. `false` means a recent GPS fix showed the
    /// rider was NOT moving at riding speed at takeoff — the event is real
    /// enough to keep but must not be counted or used for session records.
    /// `nil` on older sessions and engines that do not report it; `true` also
    /// when no fix was available (GPS may never delete a jump).
    var gpsVerified: Bool?
    /// Ground speed (m/s) behind that verdict, nil when no recent fix existed.
    var takeoffGroundSpeed: Double?
    /// V16 matched-filter output before its linear metres calibration.
    var matchedFilterApexRawM: Double?
    /// V16 lift-shelf duration — the big-air confirmation statistic.
    var liftPlateauDurationSec: Double?
    /// `low` or `unresolved` for V16; nil for engines with a validated airtime.
    var airtimeConfidence: String?
    /// `low` or `unresolved` for V16; nil for legacy engines. Kept separately
    /// from airtime because a resolved landing can still have no usable GPS
    /// distance measurement.
    var distanceConfidence: String?

    // MARK: Flight-path anchors — the phone draws the arc from these
    //
    // The take-off fix plus a scalar distance cannot say which WAY the jump
    // went, so the phone falls back to the GPS track's bearing and draws a
    // straight chord: 8.09 m of error measured against the mid-flight fixes on
    // log 287. These two extra positions take that to 4.55 m. All nil when the
    // landing was never resolved — the phone renders nothing rather than a
    // guess, and must NOT substitute defaults.
    var landingLatitude: Double?
    var landingLongitude: Double?
    var apexLatitude: Double?
    var apexLongitude: Double?
    /// Apex time ÷ airtime, 0...1 — the vertical shape of the arc. Measured
    /// 0.33-0.61 (median 0.40) across the log-287 goldens; without it the phone
    /// assumes 0.42 for every jump.
    var riseFraction: Double?

    // MARK: Rider diagnostics
    /// Peak load at the pop (g) — how violently the board released.
    var takeoffYankG: Double?
    /// Peak load at touchdown (g). A clean landing is progressive, a slam is a
    /// spike; read with `speedRetention`, which says whether the rider rode away.
    var landingImpactG: Double?
    /// Gyro integral over the flight, in revolutions. The WRIST's rotation —
    /// an arm movement counts — so present it as a rotation INDEX, never as a
    /// spin count.
    var rotationRevs: Double?
    /// Mean load over the 1.5 s before the pop (g): how hard the rider carved
    /// into the send.
    var edgeLoadG: Double?

    init(sessionId: String, startTime: Date) {
        self.id = UUID().uuidString
        self.sessionId = sessionId
        self.startTime = startTime
        self.endTime = startTime
        self.height = 0
        self.airtime = 0
        self.jumpDistance = 0
        self.rotations = 0
        self.confidence = 0
        self.imuSamples = []
        self.apexTime = nil
        self.heightSource = nil
        self.absoluteTakeoffAltitude = nil
        self.absoluteApexAltitude = nil
        self.absoluteLandingAltitude = nil
        self.takeoffSpeed = nil
        self.landingSpeed = nil
        self.detectionConfidence = nil
        self.heightConfidence = nil
        self.baselineQuality = nil
        self.heightFailureReason = nil
        self.gpsVerified = nil
        self.takeoffGroundSpeed = nil
        self.matchedFilterApexRawM = nil
        self.liftPlateauDurationSec = nil
        self.airtimeConfidence = nil
        self.distanceConfidence = nil
        self.landingLatitude = nil
        self.landingLongitude = nil
        self.apexLatitude = nil
        self.apexLongitude = nil
        self.riseFraction = nil
        self.takeoffYankG = nil
        self.landingImpactG = nil
        self.rotationRevs = nil
        self.edgeLoadG = nil
    }
}

extension Jump {
    /// The engine explicitly did not find a landing, so `airtime` holds the 0
    /// sentinel and `endTime == startTime`. This is "not measured", NOT a
    /// zero-second flight — V16 reports it on jumps whose descent was never
    /// arrested, and 2 of the 5 such reference emissions are genuine jumps.
    var hasUnresolvedAirtime: Bool { airtimeConfidence == "unresolved" }

    /// The engine did not measure a horizontal distance. `jumpDistance` remains
    /// a non-optional legacy field, so consumers must use this marker instead
    /// of interpreting its zero sentinel as a measurement.
    var hasUnresolvedDistance: Bool { distanceConfidence == "unresolved" }

    /// Airtime for display. Renders "—" when unresolved rather than a
    /// convincing-looking number — a 1.82 m emission once reached the field
    /// shown as a 0.34 s flight, shorter than free fall from that height and so
    /// physically impossible. Never format `airtime` directly in a view.
    ///
    /// For the same reason, never FILTER on a low airtime: the shortest
    /// measured airtime across the whole reference set is 2.40 s, so such a
    /// filter removes nothing real and removes exactly these sentinels.
    func airtimeText(format: String) -> String {
        hasUnresolvedAirtime ? "—" : String(format: format, airtime)
    }
}

// MARK: - GPS Point
struct GPSPoint: Codable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double
    let course: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double

    init(timestamp: Date,
         latitude: Double,
         longitude: Double,
         altitude: Double,
         speed: Double,
         course: Double,
         horizontalAccuracy: Double,
         verticalAccuracy: Double) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = max(0, speed)
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
    }
    
    init(from location: CLLocation) {
        self.timestamp = location.timestamp
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.speed = max(0, location.speed) // speed can be negative if invalid
        self.course = location.course
        self.horizontalAccuracy = location.horizontalAccuracy
        self.verticalAccuracy = location.verticalAccuracy
    }
}

// MARK: - IMU Sample
struct IMUSample: Codable {
    let timestamp: Date
    let accelerationX: Double
    let accelerationY: Double
    let accelerationZ: Double
    let rotationX: Double
    let rotationY: Double
    let rotationZ: Double
    let gravity: Vector3?
    /// CoreMotion monotonic timestamp for the IMU sample, seconds since boot.
    /// Used by V12 so motion, barometer, GPS, and submersion share one clock.
    let motionTimestamp: TimeInterval?
    /// Barometric pressure in hPa (from CMAltimeter). nil when unavailable.
    let pressure: Double?
    /// CMAltimeter relative altitude in metres, delivered on the barometer's own
    /// cadence. nil when unavailable or for logs captured before V12 metadata.
    let relativeAltitude: Double?
    /// CoreMotion monotonic timestamp for the barometer sample currently stamped
    /// onto this IMU sample. V12 de-duplicates ZOH-held baro samples by this value.
    let barometerTimestamp: TimeInterval?
    /// CMAltimeter absolute altitude in metres, from startAbsoluteAltitudeUpdates.
    /// V12 prefers this fast delta channel when available; the local jump anchor
    /// cancels its slow sea-level offset.
    let absoluteAltitude: Double?
    let absoluteAltitudeAccuracy: Double?
    let absoluteAltitudePrecision: Double?
    let absoluteAltitudeTimestamp: TimeInterval?
    /// Device attitude quaternion from CMDeviceMotion, needed by LOG5 v2 replay.
    let attitudeQuaternion: MotionQuaternion?

    // ── Water submersion (Apple Watch Ultra · CMWaterSubmersionManager) ──
    // ZOH-held onto each IMU sample the same way `pressure` is. All optional so
    // older `.kslog` files (recorded before this channel existed) and non-Ultra
    // devices simply decode these as nil — the engine treats absent submersion
    // as "unknown" and falls back to IMU-only detection.
    /// True while the watch reports the wearer/board is under water (surfaced =
    /// false). nil when submersion sensing is unavailable.
    let submerged: Bool?
    /// Depth under water in metres (nil when surfaced or unavailable).
    let waterDepth: Double?
    /// Water pressure in hPa from the submersion sensor (a higher-quality baro
    /// than CMAltimeter during water sports). nil when surfaced/unavailable.
    let waterPressure: Double?

    /// New submersion params default to nil so every existing call site (which
    /// ends at `pressure:`) and every previously-recorded log stays valid.
    init(timestamp: Date,
         accelerationX: Double,
         accelerationY: Double,
         accelerationZ: Double,
         rotationX: Double,
         rotationY: Double,
         rotationZ: Double,
         gravity: Vector3?,
         pressure: Double?,
         motionTimestamp: TimeInterval? = nil,
         relativeAltitude: Double? = nil,
         barometerTimestamp: TimeInterval? = nil,
         absoluteAltitude: Double? = nil,
         absoluteAltitudeAccuracy: Double? = nil,
         absoluteAltitudePrecision: Double? = nil,
         absoluteAltitudeTimestamp: TimeInterval? = nil,
         attitudeQuaternion: MotionQuaternion? = nil,
         submerged: Bool? = nil,
         waterDepth: Double? = nil,
         waterPressure: Double? = nil) {
        self.timestamp = timestamp
        self.accelerationX = accelerationX
        self.accelerationY = accelerationY
        self.accelerationZ = accelerationZ
        self.rotationX = rotationX
        self.rotationY = rotationY
        self.rotationZ = rotationZ
        self.gravity = gravity
        self.motionTimestamp = motionTimestamp
        self.pressure = pressure
        self.relativeAltitude = relativeAltitude
        self.barometerTimestamp = barometerTimestamp
        self.absoluteAltitude = absoluteAltitude
        self.absoluteAltitudeAccuracy = absoluteAltitudeAccuracy
        self.absoluteAltitudePrecision = absoluteAltitudePrecision
        self.absoluteAltitudeTimestamp = absoluteAltitudeTimestamp
        self.attitudeQuaternion = attitudeQuaternion
        self.submerged = submerged
        self.waterDepth = waterDepth
        self.waterPressure = waterPressure
    }

    var accelerationMagnitude: Double {
        sqrt(accelerationX * accelerationX +
             accelerationY * accelerationY +
             accelerationZ * accelerationZ)
    }

    /// Gyroscope magnitude in rad/s
    var rotationMagnitude: Double {
        sqrt(rotationX * rotationX +
             rotationY * rotationY +
             rotationZ * rotationZ)
    }
}

// MARK: - Supporting Types
struct Vector3: Codable {
    let x: Double
    let y: Double
    let z: Double
}

struct MotionQuaternion: Codable {
    let w: Double
    let x: Double
    let y: Double
    let z: Double
}

enum Sport: String, Codable, CaseIterable {
    case kiteboarding
    // case windsurfing
    // case wingfoiling
    // case surfing
    
    var displayName: String {
        switch self {
        case .kiteboarding: return "Kiteboarding"
        // case .windsurfing: return "Windsurfing"
        // case .wingfoiling: return "Wing Foiling"
        // case .surfing: return "Surfing"
        }
    }
}

enum SessionStatus: String, Codable {
    case active
    case paused
    case completed
}

// MARK: - Jump Detection Mode
/// User-selectable algorithm preset.
/// Exposed in Settings and stored in UserDefaults as "detectionMode".
enum DetectionMode: String, Codable, CaseIterable {
    case standard
    case custom

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .custom:   return "Custom"
        }
    }

    var description: String {
        switch self {
        case .standard: return "Optimised for real-world kiteboarding."
        case .custom:   return "Fine-tune parameters yourself."
        }
    }

    var icon: String {
        switch self {
        case .standard: return "figure.surfing"
        case .custom:   return "slider.horizontal.3"
        }
    }

    // ──────────────────────────────────────────────
    // MARK: 6 Core Parameters
    // ──────────────────────────────────────────────

    /// Minimum GPS speed (m/s) to arm jump detection.
    var minSpeed: Double {
        switch self {
        case .standard: return JumpDetectionConfig.shared.standardMinSpeed
        case .custom:   return JumpDetectionConfig.shared.minSpeed
        }
    }

    /// Takeoff acceleration spike (g).
    var takeoffG: Double {
        switch self {
        case .standard: return JumpDetectionConfig.shared.standardTakeoffG
        case .custom:   return JumpDetectionConfig.shared.takeoffG
        }
    }

    /// Landing impact threshold (g).
    var landingG: Double {
        switch self {
        case .standard: return JumpDetectionConfig.shared.standardLandingG
        case .custom:   return JumpDetectionConfig.shared.landingG
        }
    }

    /// Minimum airtime (seconds) for a valid jump.
    var minAirtime: Double {
        switch self {
        case .standard: return JumpDetectionConfig.shared.standardMinAirtime
        case .custom:   return JumpDetectionConfig.shared.minAirtime
        }
    }

    /// Maximum airtime (seconds) — discard if longer.
    var maxAirtime: Double {
        switch self {
        case .standard: return JumpDetectionConfig.shared.standardMaxAirtime
        case .custom:   return JumpDetectionConfig.shared.maxAirtime
        }
    }

    /// Cooldown between jumps (seconds).
    var cooldown: Double {
        switch self {
        case .standard: return JumpDetectionConfig.shared.standardCooldown
        case .custom:   return JumpDetectionConfig.shared.cooldown
        }
    }

    /// Kinematic-height calibration factor (multiplies the V7 rise-time height).
    /// Standard uses a stronger production calibration because labelled watch
    /// logs showed roughly metre-level under-reading on rider jumps.
    /// (boosted kiteboarding jumps).
    var kinematicCalibration: Double {
        switch self {
        case .standard: return JumpDetectionConfig.shared.standardKinematicCalibration
        case .custom:   return JumpDetectionConfig.shared.kinematicCalibration
        }
    }
}

// MARK: - Jump Detection Engine
/// User-selectable jump-detection ENGINE (independent of DetectionMode presets).
/// Stored in UserDefaults as "detectionEngine". Takes effect at next session start.
enum DetectionEngine: String, Codable, CaseIterable {
    case v11Buffered = "v11-buffered"  // offline buffered engine (3–5 s delayed, fewer false positives)
    case v16BigAir = "v16-big-air"      // isolated quaternion/world-Z IMU engine; height integrated over the measured flight
    case v15Clean = "v15-clean"        // IMU-led detection (yank→quiet→impact) + continuous single-consumer absolute barometer measuring via apexFit
    case v14Hybrid = "v14-hybrid"      // IMU+pressure detection; absolute altimeter sampled on demand per jump for the height cross-check
    case sensorRecorder = "sensor-recorder" // no detection at all: every sensor streams continuously into the .kslog for ground-truth capture
    case v13Pure = "v13-pure"          // altitude-first engine: rise opens a candidate, classification runs after landing (≤5 s)
    case v12AppleSensorFusion = "v12-apple-sensor-fusion" // opt-in Apple sensor-fusion engine; runtime-gated by required sensors
    case v10  // sensor-grounded kite-aware evolution (KitesurfJumpEngineV10)
    case v9   // cyclic-buffer scanner over the v8 engine (provisional→final, surfaces the accurate final)
    case v8   // baro-centric whole-session engine (periodic re-analysis live)
    case v7   // legacy streaming FSM (KitesurfJumpEngineV7)

    var displayName: String {
        switch self {
        case .v11Buffered: return "V11 Buffered"
        case .v16BigAir: return "V16.4 Big Air (Default)"
        case .v15Clean: return "V15 Clean (Beta)"
        case .v14Hybrid: return "V14 Hybrid (Beta)"
        case .sensorRecorder: return "Sensor Recorder"
        case .v13Pure: return "V13 Pure (Beta)"
        case .v12AppleSensorFusion: return "V12 Sensor Fusion"
        case .v10: return "V10"
        case .v9: return "V9"
        case .v8: return "V8"
        case .v7: return "V7"
        }
    }
    var description: String {
        switch self {
        case .v11Buffered: return "Offline buffered: analyses full jump segments on a 3–5 s background pass. Slightly delayed, fewer false positives."
        case .v16BigAir: return "Big-air first, IMU only — the barometer is not used at all. A pop opens a candidate; a sustained LIFT SHELF in world-vertical acceleration confirms it, with the measured flight window providing corroboration when a long flight overflows the fixed window. Height is measured by endpoint-anchored double integration over the flight and is reported in metres with no calibration constant: 0.28 m pooled MAE and 38/39 guarded recall across the V16.4 reference suite. The waves-only negative control stays silent and the tallest false reading remains 1.56 m. Hand throws on a bench are detected too, so the watch can be tested without going on the water. Airtime is estimated from where the water arrests the descent and is never used as a gate. Distance is omitted when no landing window was measured. Jumps at or above 2.5 m are delivered immediately after evaluation; smaller ones wait out the dedup hold."
        case .sensorRecorder: return "Recording only: no jump detection, no formulas. Every sensor (IMU 200Hz, relative + absolute altimeter, GPS, submersion) streams continuously into the session log for offline analysis."
        case .v15Clean: return "IMU-led second generation: a yank spike opens, flight-quiet sustains, a physical impact (or baro return-to-base) closes. The absolute barometer streams continuously for the whole session as the single consumer and measures height via a parabolic apex fit, with relative-pressure and ballistic fallbacks. No GPS or turbulence gates."
        case .v14Hybrid: return "Hybrid: IMU unweight + pressure-baseline formula opens a jump; the absolute altimeter runs only from takeoff to a stable landing baseline and cross-checks the peak height. Works fully without GPS."
        case .v13Pure: return "Altitude-first: absolute-altitude rise opens a candidate; the full arc is classified after landing against the pre-jump baseline. The user's minimum height filters only the final count; GPS and IMU never reject."
        case .v12AppleSensorFusion: return "Apple sensor-fusion engine using batched motion, altimeter, GPS and optional submersion data. Opt-in and gated by runtime readiness checks."
        case .v10: return "Sensor-grounded, kite-aware engine."
        case .v9: return "Cyclic-buffer scanner over the baro-centric v8 engine. Re-scans a rolling window and surfaces each jump once its accurate measurement settles."
        case .v8: return "Baro-centric engine (experimental)."
        case .v7: return "Legacy real-time engine."
        }
    }
    var icon: String {
        switch self {
        case .v11Buffered: return "tray.full"
        case .v16BigAir: return "waveform.path.ecg.rectangle"
        case .v15Clean: return "wind"
        case .v14Hybrid: return "figure.surfing"
        case .sensorRecorder: return "record.circle"
        case .v13Pure: return "square.stack.3d.up"
        case .v12AppleSensorFusion: return "waveform.path.ecg"
        case .v10: return "checkmark.seal"
        case .v9: return "arrow.triangle.2.circlepath"
        case .v8: return "sparkles"
        case .v7: return "clock.arrow.circlepath"
        }
    }
}

// MARK: - Jump Detection Configuration (6 parameters)
/// Stores user-tunable parameters in UserDefaults.
/// Used when DetectionMode is .custom.
class JumpDetectionConfig {
    static let shared = JumpDetectionConfig()

    private let defaults = UserDefaults.standard
    private let currentStandardCalibrationVersion = "surfr-v7-20260621-height125"

    private init() {
        installStandardCalibrationIfNeeded()
    }

    private enum Key: String {
        case minSpeed              = "jd_minSpeed"
        case takeoffG              = "jd_takeoffG"
        case landingG              = "jd_landingG"
        case minAirtime            = "jd_minAirtime"
        case maxAirtime            = "jd_maxAirtime"
        case cooldown              = "jd_cooldown"
        case kinematicCalibration  = "jd_kinematicCalibration"
        case standardMinSpeed      = "jd_standard_minSpeed"
        case standardTakeoffG      = "jd_standard_takeoffG"
        case standardLandingG      = "jd_standard_landingG"
        case standardMinAirtime    = "jd_standard_minAirtime"
        case standardMaxAirtime    = "jd_standard_maxAirtime"
        case standardCooldown      = "jd_standard_cooldown"
        case standardKinematicCalibration = "jd_standard_kinematicCalibration"
        case standardCalibrationVersion   = "jd_standard_calibrationVersion"
    }

    var standardMinSpeed: Double {
        get { val(.standardMinSpeed, default: 5.0 / 3.6) }
        set { defaults.set(newValue, forKey: Key.standardMinSpeed.rawValue) }
    }

    var standardTakeoffG: Double {
        get { val(.standardTakeoffG, default: 1.7) }
        set { defaults.set(newValue, forKey: Key.standardTakeoffG.rawValue) }
    }

    var standardLandingG: Double {
        get { val(.standardLandingG, default: 1.4) }
        set { defaults.set(newValue, forKey: Key.standardLandingG.rawValue) }
    }

    var standardMinAirtime: Double {
        get { val(.standardMinAirtime, default: 2.0) }
        set { defaults.set(newValue, forKey: Key.standardMinAirtime.rawValue) }
    }

    var standardMaxAirtime: Double {
        get { val(.standardMaxAirtime, default: 6.5) }
        set { defaults.set(newValue, forKey: Key.standardMaxAirtime.rawValue) }
    }

    var standardCooldown: Double {
        get { val(.standardCooldown, default: 1.0) }
        set { defaults.set(newValue, forKey: Key.standardCooldown.rawValue) }
    }

    var standardKinematicCalibration: Double {
        get { val(.standardKinematicCalibration, default: 1.25) }
        set { defaults.set(newValue, forKey: Key.standardKinematicCalibration.rawValue) }
    }

    var standardCalibrationVersion: String? {
        get { defaults.string(forKey: Key.standardCalibrationVersion.rawValue) }
        set { defaults.set(newValue, forKey: Key.standardCalibrationVersion.rawValue) }
    }

    var minSpeed: Double {
        get { val(.minSpeed, default: 15.0 / 3.6) }
        set { defaults.set(newValue, forKey: Key.minSpeed.rawValue) }
    }

    var takeoffG: Double {
        get { val(.takeoffG, default: 1.5) }
        set { defaults.set(newValue, forKey: Key.takeoffG.rawValue) }
    }

    var landingG: Double {
        get { val(.landingG, default: 2.0) }
        set { defaults.set(newValue, forKey: Key.landingG.rawValue) }
    }

    var minAirtime: Double {
        get { val(.minAirtime, default: 0.5) }
        set { defaults.set(newValue, forKey: Key.minAirtime.rawValue) }
    }

    var maxAirtime: Double {
        get { val(.maxAirtime, default: 8.0) }
        set { defaults.set(newValue, forKey: Key.maxAirtime.rawValue) }
    }

    var cooldown: Double {
        get { val(.cooldown, default: 1.5) }
        set { defaults.set(newValue, forKey: Key.cooldown.rawValue) }
    }

    /// Kinematic-height calibration factor (default 1.12, range 0.8–1.5).
    var kinematicCalibration: Double {
        get { val(.kinematicCalibration, default: 1.12) }
        set { defaults.set(newValue, forKey: Key.kinematicCalibration.rawValue) }
    }

    func resetToDefaults() {
        minSpeed              = 15.0 / 3.6
        takeoffG              = 1.5
        landingG              = 2.0
        minAirtime            = 0.5
        maxAirtime            = 8.0
        cooldown              = 1.5
        kinematicCalibration  = 1.12
    }

    func applyStandardCalibration(_ schema: CloudCalibrationSchema) {
        standardMinSpeed = schema.minSpeed
        standardTakeoffG = schema.takeoffG
        standardLandingG = schema.landingG
        standardMinAirtime = schema.minAirtime
        standardMaxAirtime = schema.maxAirtime
        standardCooldown = schema.cooldown
        standardKinematicCalibration = schema.kinematicCalibration
        standardCalibrationVersion = schema.version
    }

    private func installStandardCalibrationIfNeeded() {
        guard standardCalibrationVersion != currentStandardCalibrationVersion else { return }
        standardMinSpeed = 5.0 / 3.6
        standardTakeoffG = 1.7
        standardLandingG = 1.4
        standardMinAirtime = 2.0
        standardMaxAirtime = 6.5
        standardCooldown = 1.0
        standardKinematicCalibration = 1.25
        standardCalibrationVersion = currentStandardCalibrationVersion
    }

    private func val(_ key: Key, default defaultValue: Double) -> Double {
        guard defaults.object(forKey: key.rawValue) != nil else { return defaultValue }
        return defaults.double(forKey: key.rawValue)
    }
}
