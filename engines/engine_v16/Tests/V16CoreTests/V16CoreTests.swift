import XCTest
@testable import V16Core

/// Behavioural cover for JumpEngineV16 at the 16.1 operating point.
///
/// These are RULE tests, not calibration tests. The height/airtime accuracy
/// figures in the spec were measured on real 200 Hz logs against the HOOLAN
/// goldens (see V16_1_HANDOFF/04_REFERENCE/hoolan287_reference.mjs) and cannot
/// be reproduced from a synthetic square wave — what is asserted here is that
/// each rule 16.1 changed still behaves the way the spec says it does.
final class V16CoreTests: XCTestCase {

    // MARK: 16.1 identity

    func testEngineReportsVersion16_1() {
        XCTAssertEqual(JumpEngineV16.version, "16.1")
    }

    /// The three defaults 16.1 moved. A silent revert here would look like a
    /// calibration drift in the field with nothing in the log to explain it.
    func testShippedCalibrationDefaults() {
        let cfg = V16Config()
        XCTAssertEqual(cfg.heightOffsetM, 1.43, accuracy: 1e-9)
        XCTAssertEqual(cfg.heightScale, 1.91, accuracy: 1e-9)
        XCTAssertEqual(cfg.minReportM, 1.4, accuracy: 1e-9)
        XCTAssertEqual(cfg.minLiftPlateauSec, 0.8, accuracy: 1e-9)
        XCTAssertEqual(cfg.liftThreshMS2, 1.25, accuracy: 1e-9)
        // The hold logic in holdUntil() is only sound while dedup < evalDelay:
        // it assumes every rival pop has already arrived by the time a jump is
        // held. Reversing these would make a rival arrive after the deadline.
        XCTAssertLessThan(cfg.dedupSec, cfg.evalDelaySec)
        XCTAssertLessThan(cfg.fastEvalSec, cfg.evalDelaySec)
        // Ring must outlive the widest window any evaluation reads.
        XCTAssertGreaterThan(cfg.historySec, cfg.apexPreSec + cfg.evalDelaySec)
    }

    // MARK: Detection

    func testBigAirShelfEmitsOnceWithoutGPSOrBarometer() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feedSyntheticJump(into: engine)

        XCTAssertEqual(delegate.jumps.count, 1)
        XCTAssertGreaterThanOrEqual(delegate.jumps[0].heightM, V16Config().minReportM)
        XCTAssertGreaterThanOrEqual(delegate.jumps[0].liftPlateauSec, V16Config().minLiftPlateauSec)
        XCTAssertNil(delegate.jumps[0].takeoffSpeedMS)
    }

    /// The phantom firewall: a wave or chop bump is a short impulse with no
    /// sustained lift shelf behind it, and must never reach the rider.
    func testImpulseWithoutLiftShelfIsRejected() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feed(into: engine) { t in
            t >= 0 && t < 0.02 ? 2.0 : 0.0
        }

        XCTAssertTrue(delegate.jumps.isEmpty)
    }

    /// A shelf that stops just short of minLiftPlateauSec is still a reject —
    /// this is the one gate standing between chop and the wrist.
    func testShelfShorterThanThresholdIsRejected() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feed(into: engine) { t in
            if t >= 0 && t < 0.02 { return 2.0 }
            if t >= 0 && t < 0.5 { return 0.32 }   // 0.5 s of lift, need 0.8
            if t >= 0.5 && t < 1.3 { return -0.45 }
            return 0
        }

        XCTAssertTrue(delegate.jumps.isEmpty)
    }

    // MARK: 16.1 change 4 — boxSmooth NaN poisoning

    /// A dropped 0.1 s of CMDeviceMotion used to turn every LATER bin NaN, so
    /// the lift shelf could never be found again and the jump was rejected as
    /// noLiftPlateau. Latent at 200 Hz; live on the watch, where a 0.1 s bin
    /// holds only 5 samples. The dropout here lands BEFORE the pop so that the
    /// shelf itself is intact — under the old running-sum smoother that was
    /// enough to kill the jump anyway.
    func testShortAttitudeDropoutDoesNotPoisonAllLaterBins() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feedSyntheticJump(into: engine, attitudeDropout: -1.00 ... -0.92)

        XCTAssertEqual(delegate.jumps.count, 1)
    }

    // MARK: 16.1 change 3 — landing is the end of the arrested descent

    /// The rewritten rule resolves a landing from shelf -> sustained descent
    /// alone. The old rule additionally demanded sustained "float" afterwards,
    /// a quiet state that never arrives because the arm keeps working the bar —
    /// it returned nil on 2 of 19 goldens. Here the signal stays noisy after
    /// touchdown, exactly the case that used to fail.
    func testLandingResolvesEvenWhenMotionStaysNoisyAfterTouchdown() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feed(into: engine) { t in
            if t >= 0 && t < 0.02 { return 2.0 }
            if t >= 0 && t < 1.2 { return 0.32 }        // lift shelf
            if t >= 1.2 && t < 2.0 { return -0.45 }     // descent
            if t >= 2.0 && t < 6.0 {                    // working the bar
                return t.truncatingRemainder(dividingBy: 0.4) < 0.2 ? 0.30 : -0.28
            }
            return 0
        }

        XCTAssertEqual(delegate.jumps.count, 1)
        guard let airtime = delegate.jumps.first?.airtimeSec else {
            return XCTFail("landing not resolved — the 16.0 float rule regressed")
        }
        // Landing = end of the descent run + landOffsetSec, so it must sit
        // after the descent ends and well before the scan window closes.
        XCTAssertGreaterThan(airtime, 1.2)
        XCTAssertLessThan(airtime, V16Config().plateauScanSec)
    }

    /// nil, not 0, when the descent is never arrested. The whole sentinel
    /// contract downstream rests on this distinction.
    func testAirtimeIsNilRatherThanZeroWhenDescentNeverEnds() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feed(into: engine, until: 8.0) { t in
            if t >= 0 && t < 0.02 { return 2.0 }
            if t >= 0 && t < 1.2 { return 0.32 }
            if t >= 1.2 { return -0.45 }    // descends to the end of the feed
            return 0
        }

        XCTAssertEqual(delegate.jumps.count, 1)
        XCTAssertNil(delegate.jumps[0].airtimeSec)
    }

    // MARK: 16.1 change 5 — latency

    /// A jump at or above immediateReportM skips the dedup hold and is
    /// delivered as soon as it is judged. Before 16.1 every emission waited
    /// dedupSec + evalDelaySec, putting the number on the wrist 8-12 s after
    /// the rider was already back on the water.
    func testBigAirIsDeliveredWithoutWaitingOutTheDedupHold() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate
        let cfg = V16Config()

        var deliveredAt: TimeInterval?
        engine.onDebug = { t, event in
            if event.hasPrefix("JUMP"), deliveredAt == nil { deliveredAt = t }
        }

        feedSyntheticJump(into: engine, preUnweightG: -0.4, flush: false)

        // No flush() — if delivery still depended on the hold, nothing would
        // have arrived by now.
        XCTAssertEqual(delegate.jumps.count, 1)
        XCTAssertGreaterThanOrEqual(delegate.jumps[0].heightM, cfg.immediateReportM)
        guard let deliveredAt else {
            return XCTFail("no JUMP event — big air did not take the immediate path")
        }
        XCTAssertLessThanOrEqual(deliveredAt - delegate.jumps[0].takeoffT,
                                 cfg.evalDelaySec + 0.05)
    }

    // MARK: Dedup

    /// popClusterSec folds the several pops of one takeoff into a single
    /// candidate — a takeoff's pop burst measures 0.80 s median on the goldens.
    func testMultiplePopsOfOneTakeoffProduceOneJump() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feed(into: engine) { t in
            if t >= 0 && t < 0.02 { return 2.0 }
            if t >= 0.30 && t < 0.32 { return 2.6 }   // second, stronger pop
            if t >= 0.60 && t < 0.62 { return 2.2 }   // third
            if t >= 0 && t < 1.6 { return 0.32 }
            if t >= 1.6 && t < 2.4 { return -0.45 }
            return 0
        }

        XCTAssertEqual(delegate.jumps.count, 1)
    }

    // MARK: Helpers

    /// Pop, lift shelf, descent — the minimum shape that clears every gate.
    /// It scores ~1.5 m, i.e. a small jump, which is what most tests here want.
    ///
    /// `preUnweightG` adds the pre-pop unweighting of a real big-air takeoff
    /// and is what makes the jump BIG: the matched filter is a curvature
    /// contrast over a fixed support, and §7.2 measured its argmax at t0−1.15 s
    /// to t0+0.01 s — at or before the pop, on every golden. So the height
    /// comes from the edge-and-load BEFORE takeoff, not from the shelf after
    /// it. Amplifying the shelf instead barely moves the result (0.32 g and
    /// 1.0 g score 1.46 m and 1.63 m), which is the same finding from the
    /// other side. −0.4 g here scores ~8 m, inside the 2.1-8.5 m calibrated
    /// band, and stays well under popMinG so it raises no candidate of its own.
    private func feedSyntheticJump(
        into engine: JumpEngineV16,
        attitudeDropout: ClosedRange<Double>? = nil,
        preUnweightG: Double = 0,
        flush: Bool = true
    ) {
        feed(into: engine, attitudeDropout: attitudeDropout, flush: flush) { t in
            if t >= 0 && t < 0.02 { return 2.0 }
            if t >= 0 && t < 1.2 { return 0.32 }
            if t >= 1.2 && t < 2.0 { return -0.45 }
            if t >= -2.0 && t < -0.3 { return preUnweightG }
            return 0
        }
    }

    /// Feeds a 50 Hz stream — the watch's real rate, and the rate at which the
    /// boxSmooth bug is live (0.1 s = 5 samples per bin).
    ///
    /// The quaternion is identity, so device Z IS world Z and `accelerationZ`
    /// is the world-vertical channel in g directly.
    private func feed(
        into engine: JumpEngineV16,
        attitudeDropout: ClosedRange<Double>? = nil,
        until end: Double = 18.0,
        flush: Bool = true,
        accelerationZ: (Double) -> Double
    ) {
        let hz = 50.0
        var t = -3.0
        while t <= end {
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
        if flush { engine.flush(now: t) }
    }
}

private final class CaptureDelegate: JumpEngineV16Delegate {
    var jumps: [V16Jump] = []

    func jumpDetected(_ jump: V16Jump) {
        jumps.append(jump)
    }
}
