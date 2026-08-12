import Foundation

/// Session-wide HealthKit aggregates used by the watch-ingest `end` message.
///
/// Values stay as `Double` while HealthKit is collecting them. The upload
/// accessors round once, on the watch, and return nil for unavailable or invalid
/// measurements so the uploader can omit those optional fields entirely.
public struct SessionHealthMetrics: Equatable, Sendable {
    public private(set) var activeCaloriesKcal: Double = 0
    public private(set) var maxHeartRateBPM: Double = 0

    public init() {}

    public mutating func reset() {
        activeCaloriesKcal = 0
        maxHeartRateBPM = 0
    }

    /// HealthKit active-energy statistics are cumulative. Keeping the maximum
    /// protects the session total from a delayed callback carrying an older sum.
    public mutating func recordActiveCalories(_ kcal: Double) {
        guard kcal.isFinite, kcal > 0, kcal <= Double(Int.max) else { return }
        activeCaloriesKcal = max(activeCaloriesKcal, kcal)
    }

    /// Records a heart-rate observation while preserving the session maximum.
    public mutating func recordHeartRate(_ bpm: Double) {
        guard bpm.isFinite, bpm > 0, bpm <= Double(Int.max) else { return }
        maxHeartRateBPM = max(maxHeartRateBPM, bpm)
    }

    public mutating func merge(_ other: SessionHealthMetrics) {
        recordActiveCalories(other.activeCaloriesKcal)
        recordHeartRate(other.maxHeartRateBPM)
    }

    public var caloriesForUpload: Int? {
        Self.roundedPositiveInt(activeCaloriesKcal)
    }

    public var maxHrForUpload: Int? {
        Self.roundedPositiveInt(maxHeartRateBPM)
    }

    private static func roundedPositiveInt(_ value: Double) -> Int? {
        guard value.isFinite, value > 0 else { return nil }
        let rounded = value.rounded()
        guard rounded > 0, rounded <= Double(Int.max) else { return nil }
        return Int(rounded)
    }
}
