import XCTest
@testable import V16Core

final class V16CoreTests: XCTestCase {
    func testBigAirShelfEmitsOnceWithoutGPSOrBarometer() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feedSyntheticJump(into: engine)

        XCTAssertEqual(delegate.jumps.count, 1)
        XCTAssertGreaterThanOrEqual(delegate.jumps[0].heightM, 1.5)
        XCTAssertGreaterThanOrEqual(delegate.jumps[0].liftPlateauSec, 0.9)
        XCTAssertNil(delegate.jumps[0].takeoffSpeedMS)
    }

    func testImpulseWithoutLiftShelfIsRejected() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feed(into: engine) { t in
            t >= 0 && t < 0.02 ? 2.0 : 0.0
        }

        XCTAssertTrue(delegate.jumps.isEmpty)
    }

    func testShortAttitudeDropoutDoesNotPoisonAllLaterBins() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feedSyntheticJump(into: engine, attitudeDropout: -1.00 ... -0.92)

        XCTAssertEqual(delegate.jumps.count, 1)
    }

    private func feedSyntheticJump(
        into engine: JumpEngineV16,
        attitudeDropout: ClosedRange<Double>? = nil
    ) {
        feed(into: engine, attitudeDropout: attitudeDropout) { t in
            if t >= 0 && t < 0.02 { return 2.0 }
            if t >= 0 && t < 1.2 { return 0.32 }
            if t >= 1.2 && t < 2.0 { return -0.45 }
            return 0
        }
    }

    private func feed(
        into engine: JumpEngineV16,
        attitudeDropout: ClosedRange<Double>? = nil,
        accelerationZ: (Double) -> Double
    ) {
        let hz = 50.0
        var t = -3.0
        while t <= 18.0 {
            let azG = accelerationZ(t)
            let hasAttitude = !(attitudeDropout?.contains(t) ?? false)
            engine.addIMU(
                t: t,
                loadG: abs(azG),
                accel: (0, 0, azG),
                quat: hasAttitude ? (1, 0, 0, 0) : nil
            )
            t += 1.0 / hz
        }
        engine.flush(now: t)
    }
}

private final class CaptureDelegate: JumpEngineV16Delegate {
    var jumps: [V16Jump] = []

    func jumpDetected(_ jump: V16Jump) {
        jumps.append(jump)
    }
}
