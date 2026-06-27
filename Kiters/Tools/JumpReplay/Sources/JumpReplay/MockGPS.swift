import Foundation

/// Drives a constant-speed mock GPS feed into JumpDetector so the state
/// machine leaves IDLE. Real GPS isn't available in offline replay.
final class MockGPS {
    let speed: Double  // m/s
    private let detector: JumpDetecting
    private var lastEmit: Date?

    init(speed: Double, detector: JumpDetecting) {
        self.speed = speed
        self.detector = detector
    }

    /// Emit a GPS update at most once per second, anchored to the sample clock.
    func tickIfNeeded(at sampleTime: Date) {
        if let last = lastEmit, sampleTime.timeIntervalSince(last) < 1.0 {
            return
        }
        lastEmit = sampleTime
        detector.updateGPS(
            speed: speed,
            altitude: 0,
            latitude: 0,
            longitude: 0,
            course: -1,
            horizontalAccuracy: nil,
            timestamp: sampleTime
        )
    }
}
