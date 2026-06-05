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
    /// Barometric pressure in hPa (from CMAltimeter). nil when unavailable.
    let pressure: Double?
    
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

    /// Kinematic-height calibration factor (multiplies h = g·t²/8).
    /// Default 1.12 compensates for ~12% underestimation in asymmetric arcs
    /// (boosted kiteboarding jumps).
    var kinematicCalibration: Double {
        switch self {
        case .standard: return JumpDetectionConfig.shared.standardKinematicCalibration
        case .custom:   return JumpDetectionConfig.shared.kinematicCalibration
        }
    }
}

// MARK: - Jump Detection Configuration (6 parameters)
/// Stores user-tunable parameters in UserDefaults.
/// Used when DetectionMode is .custom.
class JumpDetectionConfig {
    static let shared = JumpDetectionConfig()

    private let defaults = UserDefaults.standard

    private enum Key: String {
        case minSpeed              = "jd_minSpeed"
        case takeoffG              = "jd_takeoffG"
        case landingG              = "jd_landingG"
        case minAirtime            = "jd_minAirtime"
        case maxAirtime            = "jd_maxAirtime"
        case cooldown              = "jd_cooldown"
        case devMode               = "jd_devMode"
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
        get { val(.standardMinSpeed, default: 15.0 / 3.6) }
        set { defaults.set(newValue, forKey: Key.standardMinSpeed.rawValue) }
    }

    var standardTakeoffG: Double {
        get { val(.standardTakeoffG, default: 1.5) }
        set { defaults.set(newValue, forKey: Key.standardTakeoffG.rawValue) }
    }

    var standardLandingG: Double {
        get { val(.standardLandingG, default: 2.0) }
        set { defaults.set(newValue, forKey: Key.standardLandingG.rawValue) }
    }

    var standardMinAirtime: Double {
        get { val(.standardMinAirtime, default: 0.5) }
        set { defaults.set(newValue, forKey: Key.standardMinAirtime.rawValue) }
    }

    var standardMaxAirtime: Double {
        get { val(.standardMaxAirtime, default: 8.0) }
        set { defaults.set(newValue, forKey: Key.standardMaxAirtime.rawValue) }
    }

    var standardCooldown: Double {
        get { val(.standardCooldown, default: 1.5) }
        set { defaults.set(newValue, forKey: Key.standardCooldown.rawValue) }
    }

    var standardKinematicCalibration: Double {
        get { val(.standardKinematicCalibration, default: 1.12) }
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

    /// Dev mode: skip GPS speed gate, allow toss-testing without riding.
    var devMode: Bool {
        get {
            guard defaults.object(forKey: Key.devMode.rawValue) != nil else { return false }
            return defaults.bool(forKey: Key.devMode.rawValue)
        }
        set { defaults.set(newValue, forKey: Key.devMode.rawValue) }
    }

    func resetToDefaults() {
        minSpeed              = 15.0 / 3.6
        takeoffG              = 1.5
        landingG              = 2.0
        minAirtime            = 0.5
        maxAirtime            = 8.0
        cooldown              = 1.5
        kinematicCalibration  = 1.12
        devMode               = false
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

    private func val(_ key: Key, default defaultValue: Double) -> Double {
        guard defaults.object(forKey: key.rawValue) != nil else { return defaultValue }
        return defaults.double(forKey: key.rawValue)
    }
}
