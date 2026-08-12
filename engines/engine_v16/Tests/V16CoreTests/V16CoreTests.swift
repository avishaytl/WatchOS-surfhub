import XCTest
@testable import V16Core

/// Behavioural cover for JumpEngineV16 through the 16.5 operating point.
///
/// These are RULE tests, not calibration tests. The height/airtime accuracy
/// figures in the spec were measured on real 200 Hz logs against the HOOLAN
/// goldens (see V16_2_HANDOFF/04_REFERENCE/hoolan287_reference.mjs) and cannot
/// be reproduced from a synthetic square wave — what is asserted here is that
/// each shipped rule still behaves the way the handoff says it does.
///
/// ⚠️ SIGN, the thing 16.2 is built on. `az` is world-vertical
/// userAcceleration and reads +1 g in FREE FALL, i.e. it is the NEGATIVE of the
/// kinematic acceleration. So a positive `az` shelf is the rider UNLOADED —
/// hanging off the canopy — which is why the lift gate and the height integral
/// (which runs on -az) both key off it. The synthetic fixtures below are
/// written in that convention; reading them as "upward acceleration" will make
/// every number here look upside down.
final class V16CoreTests: XCTestCase {

    // MARK: 16.5 identity

    func testEngineReportsVersion16_5() {
        XCTAssertEqual(JumpEngineV16.version, "16.5")
    }

    /// The defaults 16.1 and 16.2 moved, plus the parameters 16.2 introduced.
    /// A silent revert here would look like a calibration drift in the field
    /// with nothing in the log to explain it.
    func testShippedCalibrationDefaults() {
        let cfg = V16Config()
        // 16.5
        XCTAssertEqual(cfg.heightPreRollSec, 0.3, accuracy: 1e-9)
        // 16.4
        XCTAssertEqual(cfg.minLiftPlateauSec, 0.6, accuracy: 1e-9)
        XCTAssertEqual(cfg.strongShelfSec, 1.05, accuracy: 1e-9)
        XCTAssertTrue(cfg.flightCorroboration)
        XCTAssertEqual(cfg.shortShelfFlightM, 1.2, accuracy: 1e-9)
        XCTAssertEqual(cfg.shortShelfFlightM, cfg.minReportM, accuracy: 1e-9)
        // 16.3
        XCTAssertTrue(cfg.landSettleFallback)
        XCTAssertEqual(cfg.landSettleBandG, 0.30, accuracy: 1e-9)
        XCTAssertEqual(cfg.landSettleMinSec, 0.4, accuracy: 1e-9)
        XCTAssertEqual(cfg.landSettleFromSec, 1.0, accuracy: 1e-9)
        XCTAssertEqual(cfg.landSettleToSec, 9.0, accuracy: 1e-9)
        XCTAssertTrue(cfg.phantomFilter)
        XCTAssertEqual(cfg.phantomShelfSec, 1.05, accuracy: 1e-9)
        XCTAssertEqual(cfg.phantomShelfWideSec, 1.20, accuracy: 1e-9)
        XCTAssertEqual(cfg.phantomWideHeightM, 2.0, accuracy: 1e-9)
        // The wide clause only makes sense as a RELAXATION of the narrow one.
        XCTAssertGreaterThanOrEqual(cfg.phantomShelfWideSec, cfg.phantomShelfSec)
        // The settle search must start after the pop, or the take-off's own
        // quiet moment reads as a landing.
        XCTAssertGreaterThan(cfg.landSettleFromSec, 0)
        XCTAssertLessThan(cfg.landSettleFromSec, cfg.landSettleToSec)
        // 16.2
        XCTAssertEqual(cfg.popClusterSec, 0.8, accuracy: 1e-9)
        XCTAssertEqual(cfg.apexAnchorSec, 2.0, accuracy: 1e-9)
        XCTAssertTrue(cfg.heightFromFlight)
        XCTAssertEqual(cfg.shelfFullSec, 0.8, accuracy: 1e-9)
        XCTAssertEqual(cfg.shortShelfApexM, 0.30, accuracy: 1e-9)
        XCTAssertEqual(cfg.freeFallG, 0.25, accuracy: 1e-9)
        XCTAssertEqual(cfg.minFreeFallSec, 0.45, accuracy: 1e-9)
        XCTAssertEqual(cfg.minAirtimeSec, 1.5, accuracy: 1e-9)
        XCTAssertEqual(cfg.minReportM, 1.2, accuracy: 1e-9)
        XCTAssertEqual(cfg.throwHeightScale, 1.0, accuracy: 1e-9)
        // Kept from 16.1 — the matched filter is still the fallback path.
        XCTAssertEqual(cfg.heightOffsetM, 1.43, accuracy: 1e-9)
        XCTAssertEqual(cfg.heightScale, 1.91, accuracy: 1e-9)
        XCTAssertEqual(cfg.liftThreshMS2, 1.25, accuracy: 1e-9)
        // The floor may not sit above the bar, or the corroboration branch in
        // evaluate() becomes unreachable and 16.2's recall gain evaporates.
        XCTAssertLessThanOrEqual(cfg.minLiftPlateauSec, cfg.shelfFullSec)
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

    /// A shelf that stops short of minLiftPlateauSec is still a reject — this
    /// is the one gate standing between chop and the wrist. V16.4 lowered the
    /// floor to 0.6 s; it did not remove it.
    func testShelfShorterThanTheFloorIsRejected() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate
        var reasons: [String] = []
        engine.onDebug = { _, event in reasons.append(event) }

        feed(into: engine) { t in
            if t >= 0 && t < 0.02 { return 2.0 }
            if t >= 0 && t < 0.5 { return 0.32 }   // too short after smoothing
            if t >= 0.5 && t < 1.3 { return -0.45 }
            return 0
        }

        XCTAssertTrue(delegate.jumps.isEmpty)
        XCTAssertTrue(reasons.contains { $0.contains("reason=noLiftPlateau") })
    }

    // MARK: Short shelves are admitted only with corroboration

    /// Opening the floor to 0.7 s recovers four real goldens but also 15 low
    /// phantoms, and those pile up exactly ON the floor (median shelf 0.70,
    /// median apex 0.23) while real jumps sit well above it (1.30 / 1.07). So a
    /// shelf inside [minLiftPlateauSec, shelfFullSec) has to clear
    /// shortShelfApexM as well. One extra 0.1 s bin of the SAME signal takes it
    /// over shelfFullSec, where the shelf stands on its own — and the rejection
    /// reason changes accordingly.
    func testShortShelfNeedsApexOrFlightCorroborationButAFullShelfDoesNot() {
        func reasons(shelfLength: Double) -> [String] {
            let engine = JumpEngineV16()
            var events: [String] = []
            engine.onDebug = { _, event in events.append(event) }
            feed(into: engine) { t in
                if t >= 0 && t < 0.02 { return 2.0 }
                if t >= 0 && t < shelfLength { return 0.35 }
                if t >= shelfLength && t < shelfLength + 0.8 { return -0.45 }
                return 0
            }
            return events
        }

        // 0.95 s of signal measures a 0.70 s shelf with apex 0.21 — under the bar.
        XCTAssertTrue(reasons(shelfLength: 0.95).contains { $0.contains("reason=shortShelfNoApex") })
        // 1.00 s measures 0.80 s and is admitted on the shelf alone; it dies
        // later, on its measured height, which is a different verdict entirely.
        let full = reasons(shelfLength: 1.00)
        XCTAssertFalse(full.contains { $0.contains("reason=shortShelfNoApex") })
        XCTAssertTrue(full.contains { $0.contains("reason=belowMinReport") })
    }

    // MARK: 16.4 — deferred flight corroboration

    /// A long flight can overflow the fixed 4.5 s matched-filter window even
    /// though the measured flight arc is well above the reporting floor. V16.4
    /// defers the short-shelf verdict until that flight measurement exists.
    func testFlightWindowCanCorroborateAShortShelf() {
        func run(_ cfg: V16Config) -> (jump: V16Jump?, events: [String]) {
            let delegate = CaptureDelegate()
            let engine = JumpEngineV16(cfg)
            engine.delegate = delegate
            var events: [String] = []
            engine.onDebug = { _, event in events.append(event) }
            feed(into: engine, until: 12.0) { t in
                if t >= 0 && t < 0.02 { return 2.0 }
                if t >= 0 && t < 0.65 { return 0.35 }
                if t >= 0.65 && t < 4.8 { return 0.08 }
                if t >= 4.8 && t < 5.6 { return -0.45 }
                return 0
            }
            return (delegate.jumps.first, events)
        }

        let shipped = run(V16Config())
        guard let jump = shipped.jump else {
            return XCTFail("the flight window did not recover the short-shelf fixture: \(shipped.events)")
        }
        XCTAssertLessThan(jump.liftPlateauSec, V16Config().shelfFullSec)
        XCTAssertLessThan(jump.apexRawM, V16Config().shortShelfApexM)
        XCTAssertGreaterThanOrEqual(jump.heightM, V16Config().shortShelfFlightM)

        var v163 = V16Config()
        v163.flightCorroboration = false
        let previous = run(v163)
        XCTAssertNil(previous.jump)
        XCTAssertTrue(previous.events.contains { $0.contains("reason=shortShelfNoApex") })
    }

    /// Confidence has its own absolute 1.05 s shelf. If it were still derived
    /// as minLiftPlateauSec * 1.5, V16.4's 0.6 s floor would incorrectly mark
    /// this 0.9 s shelf as high confidence.
    func testConfidenceUsesTheAbsoluteStrongShelfThreshold() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate
        feed(into: engine, until: 12.0) { t in
            if t >= 0 && t < 0.02 { return 2.0 }
            if t >= 0 && t < 0.85 { return 0.35 }
            if t >= 0.85 && t < 4.8 { return 0.04 }
            if t >= 4.8 && t < 5.6 { return -0.45 }
            return 0
        }

        guard let jump = delegate.jumps.first else { return XCTFail("fixture did not emit") }
        XCTAssertGreaterThanOrEqual(jump.liftPlateauSec, V16Config().shelfFullSec)
        XCTAssertLessThan(jump.liftPlateauSec, V16Config().strongShelfSec)
        XCTAssertEqual(jump.confidence, 0.55, accuracy: 1e-9)
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
            if t >= 0 && t < 1.2 { return 0.57 }        // unloaded: the flight
            if t >= 1.2 && t < 2.0 { return -0.45 }     // the water arresting it
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
        // The resolved landing must select the measured-flight path. Its exact
        // synthetic height changed in 16.5 because that window now includes
        // the 0.3 s takeoff pre-roll; this landing test must not pin the old
        // V16.4 fixture value.
        XCTAssertEqual(delegate.jumps[0].heightSource, .flight)
        XCTAssertGreaterThanOrEqual(delegate.jumps[0].heightM, V16Config().minReportM)
    }

    /// nil, not 0, when the descent is never arrested. The whole sentinel
    /// contract downstream rests on this distinction — and in 16.2 an
    /// unresolved landing is ALSO what selects the matched-filter fallback,
    /// because the flight integral has no window to run over.
    func testAirtimeIsNilRatherThanZeroWhenDescentNeverEnds() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feedUnresolvedLanding(into: engine)

        XCTAssertEqual(delegate.jumps.count, 1)
        XCTAssertNil(delegate.jumps[0].airtimeSec)
        let cfg = V16Config()
        XCTAssertEqual(delegate.jumps[0].heightM,
                       cfg.heightScale * delegate.jumps[0].apexRawM + cfg.heightOffsetM,
                       accuracy: 0.01,
                       "an unresolved landing must fall back to the matched filter")
    }

    // MARK: 16.2 change A — the height is a measurement, not a calibration

    /// The flight integral returns METRES. Two ways to see that it is not the
    /// old calibrated correlate: the same fixture reports a different height
    /// with heightFromFlight off, and that fallback number is exactly
    /// heightScale * apex + heightOffsetM while the flight number is not.
    func testHeightComesFromTheFlightIntegralNotTheMatchedFilter() {
        let cfg = V16Config()
        var v161 = cfg
        v161.heightFromFlight = false

        let flight = CaptureDelegate(), matched = CaptureDelegate()
        let a = JumpEngineV16(cfg), b = JumpEngineV16(v161)
        a.delegate = flight
        b.delegate = matched
        feedSyntheticJump(into: a)
        feedSyntheticJump(into: b)

        XCTAssertEqual(flight.jumps.count, 1)
        XCTAssertEqual(matched.jumps.count, 1)
        XCTAssertEqual(matched.jumps[0].heightM,
                       cfg.heightScale * matched.jumps[0].apexRawM + cfg.heightOffsetM,
                       accuracy: 0.01)
        XCTAssertNotEqual(flight.jumps[0].heightM, matched.jumps[0].heightM, accuracy: 0.01)
    }

    // MARK: 16.5 — height-only takeoff pre-roll

    /// t0 is the strongest pop, after the ascent has already started. V16.5
    /// includes the preceding 0.3 s only in the resolved-flight height window;
    /// detection, airtime and GPS distance must retain their original anchors.
    func testHeightPreRollChangesOnlyResolvedFlightHeight() {
        func run(_ cfg: V16Config) -> V16Jump? {
            let delegate = CaptureDelegate()
            let engine = JumpEngineV16(cfg)
            engine.delegate = delegate
            feedSyntheticJump(
                into: engine,
                heightLeadInG: 0.35,
                gpsSpeedMS: 10,
                cfg: cfg
            )
            return delegate.jumps.first
        }

        var noPreRoll = V16Config()
        noPreRoll.heightPreRollSec = 0
        guard let baseline = run(noPreRoll), let shipped = run(V16Config()) else {
            return XCTFail("pre-roll fixture did not emit")
        }

        XCTAssertGreaterThan(shipped.heightM, baseline.heightM + 0.05)
        XCTAssertEqual(shipped.takeoffT, baseline.takeoffT, accuracy: 1e-9)
        XCTAssertEqual(shipped.airtimeSec ?? -1, baseline.airtimeSec ?? -1, accuracy: 1e-9)
        XCTAssertEqual(shipped.distanceM ?? -1, baseline.distanceM ?? -1, accuracy: 0.01)
    }

    /// A free-fall window has directly observed physical boundaries. It must
    /// remain exact regardless of the kite-flight pre-roll setting.
    func testHeightPreRollDoesNotWidenAFreeFallWindow() {
        func height(_ preRoll: Double) -> Double? {
            var cfg = V16Config()
            cfg.heightPreRollSec = preRoll
            let delegate = CaptureDelegate()
            let engine = JumpEngineV16(cfg)
            engine.delegate = delegate
            feedThrow(into: engine, freeFallSec: 1.4)
            return delegate.jumps.first?.heightM
        }

        XCTAssertEqual(height(0) ?? -1, height(0.9) ?? -2, accuracy: 1e-9)
    }

    /// Without a resolved landing there is no flight window to pre-roll. The
    /// matched-filter fallback and its nil airtime/distance contract stay put.
    func testHeightPreRollDoesNotAffectAnUnresolvedLandingFallback() {
        func jump(_ preRoll: Double) -> V16Jump? {
            var cfg = V16Config()
            cfg.heightPreRollSec = preRoll
            let delegate = CaptureDelegate()
            let engine = JumpEngineV16(cfg)
            engine.delegate = delegate
            feedUnresolvedLanding(into: engine, gpsSpeedMS: 10)
            return delegate.jumps.first
        }

        guard let baseline = jump(0), let shifted = jump(0.9) else {
            return XCTFail("unresolved fixture did not emit")
        }
        XCTAssertEqual(shifted.heightM, baseline.heightM, accuracy: 1e-9)
        XCTAssertEqual(shifted.heightSource, .matched)
        XCTAssertNil(shifted.airtimeSec)
        XCTAssertNil(shifted.distanceM)
    }

    /// A longer arc measures taller, quadratically — the height IS the arc, and
    /// an anchored integral of a constant unload u over T seconds peaks at
    /// u*g0*T^2/8. Under the 16.1 matched filter the shelf barely moved the
    /// number at all (0.32 g and 1.0 g scored 1.46 m and 1.63 m over a FIXED
    /// support) — the whole reason a 16.1 fixture needed a pre-pop unweight to
    /// produce a big jump.
    ///
    /// The arc is lengthened rather than deepened here on purpose: in a purely
    /// vertical fixture |userAcceleration| = |az|, so an unload much past
    /// 0.75 g leaves the rider under freeFallG and the engine — correctly —
    /// switches to the free-fall window, which is a different measurement.
    func testLongerFlightArcMeasuresTaller() {
        func height(flightSec: Double) -> Double {
            let delegate = CaptureDelegate()
            let engine = JumpEngineV16()
            engine.delegate = delegate
            feedSyntheticJump(into: engine, flightSec: flightSec)
            return delegate.jumps.first?.heightM ?? 0
        }
        let short = height(flightSec: 2.0), long = height(flightSec: 2.6)
        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(long, short + 1.0)
    }

    /// Every jump has to say which operator produced its height: a metre
    /// measurement and a calibrated correlate are not interchangeable, and a
    /// session log that cannot tell them apart cannot be re-analysed.
    func testHeightSourceIsStampedPerJump() {
        func source(_ feed: (JumpEngineV16) -> Void) -> V16Jump.HeightSource? {
            let delegate = CaptureDelegate()
            let engine = JumpEngineV16()
            engine.delegate = delegate
            feed(engine)
            return delegate.jumps.first?.heightSource
        }

        XCTAssertEqual(source { feedSyntheticJump(into: $0) }, .flight)
        XCTAssertEqual(source { feedThrow(into: $0, freeFallSec: 1.4) }, .freefall)
        // No landing ever resolves -> no window -> the matched-filter fallback.
        XCTAssertEqual(source { feedUnresolvedLanding(into: $0) }, .matched)
    }

    // MARK: 16.2 change A2 — the free-fall integration window

    /// A thrown watch has no water to arrest it, so the descent-arrest rule
    /// closes about twice too late and the integral faithfully integrates the
    /// wrong window (bench: 2.80 s measured against a true 1.42 s flight). Free
    /// fall bounds the same event exactly, and it cannot fire while riding — a
    /// rider hangs from the canopy and is never unloaded (0 runs in 187 min).
    ///
    /// Ballistic truth for a T-second free fall is g*T^2/8. Here T = 1.4 s, so
    /// 2.40 m; the detected window is one sample short at each edge.
    func testFreeFallWindowMeasuresBallisticHeight() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feedThrow(into: engine, freeFallSec: 1.4)

        XCTAssertEqual(delegate.jumps.count, 1)
        XCTAssertEqual(delegate.jumps[0].heightM, 9.80665 * 1.4 * 1.4 / 8, accuracy: 0.2)
    }

    /// A kite jump must NOT take the free-fall path: the rider is never
    /// unloaded past freeFallG, so the window stays the measured flight.
    /// throwHeightScale is the observable — it only ever multiplies a ballistic
    /// event, so doubling it must leave a kite jump untouched.
    func testKiteJumpDoesNotTakeTheFreeFallPath() {
        var doubled = V16Config()
        doubled.throwHeightScale = 2.0

        let plain = CaptureDelegate(), scaled = CaptureDelegate()
        let a = JumpEngineV16(), b = JumpEngineV16(doubled)
        a.delegate = plain
        b.delegate = scaled
        feedSyntheticJump(into: a)
        feedSyntheticJump(into: b)

        XCTAssertEqual(plain.jumps.count, 1)
        XCTAssertEqual(scaled.jumps.count, 1)
        XCTAssertEqual(plain.jumps[0].heightM, scaled.jumps[0].heightM, accuracy: 0.001)

        // ...while a genuine ballistic event does respond to it.
        let throwPlain = CaptureDelegate(), throwScaled = CaptureDelegate()
        let c = JumpEngineV16(), d = JumpEngineV16(doubled)
        c.delegate = throwPlain
        d.delegate = throwScaled
        feedThrow(into: c, freeFallSec: 1.4)
        feedThrow(into: d, freeFallSec: 1.4)
        XCTAssertEqual(throwScaled.jumps.first?.heightM ?? 0,
                       2 * (throwPlain.jumps.first?.heightM ?? 0), accuracy: 0.01)
    }

    // MARK: 16.2 change B — the anchor stays on the take-off

    /// popClusterSec governs how far t0 may WALK FORWARD onto a stronger pop.
    /// On a thrown watch the ordering inverts — the release is 3-6 g and the
    /// CATCH is 15-23 g about a second later — so at the old 2.0 s the anchor
    /// landed on the landing and the shelf scan started after the flight was
    /// over. At 0.8 s the 15 g catch cannot capture the take-off.
    func testAnchorStaysOnTheReleaseWhenTheCatchIsFarStronger() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feedThrow(into: engine, freeFallSec: 1.4, catchG: 15.0)

        XCTAssertEqual(delegate.jumps.count, 1)
        XCTAssertEqual(delegate.jumps[0].takeoffT, 0.0, accuracy: 0.1,
                       "t0 walked onto the catch — popClusterSec regressed")
        XCTAssertEqual(delegate.jumps[0].yankG, 2.0, accuracy: 0.1)
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

        feedSyntheticJump(into: engine, flush: false)

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
    /// candidate — a takeoff's pop burst measures 0.80 s median on the goldens,
    /// which is exactly what 16.2 set the window to.
    func testMultiplePopsOfOneTakeoffProduceOneJump() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feed(into: engine) { t in
            if t >= 0 && t < 0.02 { return 2.0 }
            if t >= 0.30 && t < 0.32 { return 2.6 }   // second, stronger pop
            if t >= 0.60 && t < 0.62 { return 2.2 }   // third
            if t >= 0 && t < 1.6 { return 0.57 }
            if t >= 1.6 && t < 2.4 { return -0.45 }
            return 0
        }

        XCTAssertEqual(delegate.jumps.count, 1)
    }

    // MARK: 16.2 change E — the immediate path honours dedup

    /// Two candidates both over immediateReportM inside dedupSec used to BOTH
    /// fire, because the immediate path never consulted lastEmit. That produced
    /// the 4.39 m "phantom" 3.4 s after the real 4.24 m jump on smallLog: one
    /// take-off delivered twice. A rider needs well over 5 s between real jumps.
    func testImmediateReportPathDropsADuplicateInsideDedup() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate
        var events: [String] = []
        engine.onDebug = { _, event in events.append(event) }

        feed(into: engine, until: 20.0) { t in
            for t0 in [0.0, 3.4] {   // 3.4 s apart, inside dedupSec = 6.0
                if t >= t0 && t < t0 + 0.02 { return 2.0 }
                if t >= t0 && t < t0 + 2.0 { return 0.57 }
                if t >= t0 + 2.0 && t < t0 + 2.8 { return -0.45 }
            }
            return 0
        }

        XCTAssertEqual(delegate.jumps.count, 1)
        XCTAssertGreaterThanOrEqual(delegate.jumps[0].heightM, V16Config().immediateReportM)
        XCTAssertTrue(events.contains { $0.contains("DROP") && $0.contains("duplicate of delivered") })
    }

    // MARK: 16.2 change F — the airtime floor

    /// A RESOLVED flight shorter than minAirtimeSec is a watch knock. The gate
    /// is dormant at the shipped 1.5 s — the landing rule cannot resolve a
    /// flight that short (0.7 s of shelf + 0.6 s of dip + landOffsetSec already
    /// exceeds it) — so it is exercised here by raising the floor above a
    /// fixture that does resolve.
    func testResolvedFlightUnderTheAirtimeFloorIsRejected() {
        var cfg = V16Config()
        cfg.minAirtimeSec = 4.0

        let delegate = CaptureDelegate()
        let engine = JumpEngineV16(cfg)
        engine.delegate = delegate
        var events: [String] = []
        engine.onDebug = { _, event in events.append(event) }

        feedSyntheticJump(into: engine, cfg: cfg)   // resolves a 3.4 s flight

        XCTAssertTrue(delegate.jumps.isEmpty)
        XCTAssertTrue(events.contains { $0.contains("reason=airtimeTooShort") })
    }

    // MARK: 16.2 change G — the displacement origin

    /// `gpsPoint(near: t0 - 1.0)` was used for BOTH the take-off speed and the
    /// displacement origin. Sampling the origin 1 s early folded a whole second
    /// of riding into every jump — ~8 m at 30 km/h, and +12.8 m of measured bias
    /// on smallLog. Speed still samples early, deliberately: that is the entry
    /// velocity before the pop bleeds it off.
    func testDistanceSamplesItsOriginAtTakeoffNotASecondEarlier() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feedSyntheticJump(into: engine, gpsSpeedMS: 10)

        XCTAssertEqual(delegate.jumps.count, 1)
        guard let distance = delegate.jumps[0].distanceM,
              let airtime = delegate.jumps[0].airtimeSec else {
            return XCTFail("no GPS-derived distance")
        }
        // 10 m/s in a straight line: the flight alone, not the flight plus the
        // second of riding before it (which would read ~10 m longer).
        XCTAssertEqual(distance, 10 * airtime, accuracy: 1.5)
        XCTAssertEqual(delegate.jumps[0].takeoffSpeedMS ?? 0, 10, accuracy: 0.5)
    }

    // MARK: Extended payload — the flight-path anchors

    /// The phone cannot draw the arc from one point and a scalar distance. The
    /// landing and apex positions plus the rise fraction are what take the
    /// drawn path from 8.09 m of error to 4.55 m, and all three come out of
    /// work `evaluate()` already does.
    func testFlightAnchorsAreReportedWhenGPSAndALandingExist() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feedSyntheticJump(into: engine, gpsSpeedMS: 10)

        XCTAssertEqual(delegate.jumps.count, 1)
        let jump = delegate.jumps[0]
        XCTAssertNotNil(jump.landLat)
        XCTAssertNotNil(jump.landLng)
        XCTAssertNotNil(jump.apexLat)
        XCTAssertNotNil(jump.apexLng)

        // Due east at a constant speed, so the apex fix must sit BETWEEN the
        // take-off and the landing rather than at either end.
        guard let apexLng = jump.apexLng, let landLng = jump.landLng else { return }
        XCTAssertGreaterThan(apexLng, 0)
        XCTAssertLessThan(apexLng, landLng)

        // A physical apex sits inside the flight, not at an edge.
        guard let rise = jump.riseFraction else { return XCTFail("no rise fraction") }
        XCTAssertGreaterThan(rise, 0.05)
        XCTAssertLessThan(rise, 0.95)
    }

    /// No landing means no flight window, so there is no apex and no landing
    /// fix. The phone renders nothing rather than a guess — the engine must
    /// send nil, never a default.
    func testFlightAnchorsAreNilWhenTheLandingIsUnresolved() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feedUnresolvedLanding(into: engine, gpsSpeedMS: 10)

        XCTAssertEqual(delegate.jumps.count, 1)
        let jump = delegate.jumps[0]
        XCTAssertNil(jump.airtimeSec)
        XCTAssertNil(jump.distanceM)
        XCTAssertNil(jump.landLat)
        XCTAssertNil(jump.landLng)
        XCTAssertNil(jump.apexLat)
        XCTAssertNil(jump.apexLng)
        XCTAssertNil(jump.riseFraction)
        XCTAssertNil(jump.rotationRevs)
        XCTAssertNil(jump.landingImpactG)
        // ...but the edge load is measured entirely BEFORE the pop, so it
        // survives an unresolved landing.
        XCTAssertNotNil(jump.edgeLoadG)
    }

    // MARK: Extended payload — the rider diagnostics

    /// The rotation index is |omega| integrated over the flight, in revolutions.
    /// A constant 2*pi rad/s over a resolved flight of T seconds must therefore
    /// read T revolutions.
    func testRotationIndexIntegratesGyroOverTheFlight() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feedSyntheticJump(into: engine, gyroRadS: 2 * Double.pi)

        XCTAssertEqual(delegate.jumps.count, 1)
        guard let revs = delegate.jumps[0].rotationRevs,
              let airtime = delegate.jumps[0].airtimeSec else {
            return XCTFail("no rotation index")
        }
        XCTAssertEqual(revs, airtime, accuracy: 0.1)
    }

    /// The edge load is the mean load over the 1.5 s BEFORE the pop — the carve
    /// into the send. historySec is 14.0 s, so the ring already holds it.
    func testEdgeLoadMeasuresTheCarveBeforeThePop() {
        func edgeLoad(carveG: Double) -> Double? {
            let delegate = CaptureDelegate()
            let engine = JumpEngineV16()
            engine.delegate = delegate
            feedSyntheticJump(into: engine, carveG: carveG)
            return delegate.jumps.first?.edgeLoadG
        }
        // A rider hanging on the edge reads that load; one drifting flat reads ~0.
        XCTAssertEqual(edgeLoad(carveG: 0.70) ?? 0, 0.70, accuracy: 0.05)
        XCTAssertEqual(edgeLoad(carveG: 0.0) ?? -1, 0.0, accuracy: 0.05)
    }

    /// Landing impact is the peak load around touchdown. ⚠️ The window runs to
    /// landingT + 0.7 s but a big jump is finalised the moment `now` reaches
    /// the landing, so the tail is usually unsampled — the value is "peak load
    /// at touchdown", not a fixed-support statistic. What must hold either way
    /// is that a slam reads higher than a soft landing.
    func testLandingImpactSeparatesASlamFromASoftLanding() {
        func impact(slamG: Double) -> Double? {
            let delegate = CaptureDelegate()
            let engine = JumpEngineV16()
            engine.delegate = delegate
            feedSyntheticJump(into: engine, slamG: slamG)
            return delegate.jumps.first?.landingImpactG
        }
        guard let soft = impact(slamG: 0), let slam = impact(slamG: 2.5) else {
            return XCTFail("no landing impact")
        }
        XCTAssertGreaterThan(slam, soft + 1.0)
    }

    // MARK: 16.3 change 1 — the settle fallback

    /// When the descent is never ARRESTED but the rider ends up supported again
    /// — specific force back to ~1 g and staying there — that instant is the
    /// landing. It matters far more than a missing airtime: without a window
    /// the height falls back to the matched filter, and on the five GAVRI jumps
    /// that never resolved that was the difference between 0.77 m and 0.20 m of
    /// error. Here the same fixture reads 1.43 m (the matched filter's floor
    /// output, i.e. no information) with the fallback off and measures a real
    /// height with it on.
    func testSettleFallbackSuppliesAWindowWhenTheArrestRuleCannot() {
        func run(_ cfg: V16Config) -> V16Jump? {
            let delegate = CaptureDelegate()
            let engine = JumpEngineV16(cfg)
            engine.delegate = delegate
            // Unloaded flight, then straight back to normal support: no
            // sustained DESCENT for the arrest rule to find the end of.
            feed(into: engine) { t in
                if t >= 0 && t < 0.02 { return 2.0 }
                if t >= 0 && t < 2.6 { return 0.57 }
                return 0
            }
            return delegate.jumps.first
        }

        var off = V16Config()
        off.landSettleFallback = false

        guard let withFallback = run(V16Config()), let without = run(off) else {
            return XCTFail("fixture stopped emitting")
        }
        XCTAssertNotNil(withFallback.airtimeSec)
        XCTAssertEqual(withFallback.heightSource, .flight)
        XCTAssertNil(without.airtimeSec)
        XCTAssertEqual(without.heightSource, .matched)
        XCTAssertGreaterThan(withFallback.heightM, without.heightM + 1.0)

        // The settled run STARTS where support resumes, so the landing lands on
        // the end of the flight, not landSettleMinSec past it.
        XCTAssertEqual(withFallback.airtimeSec ?? 0, 2.6, accuracy: 0.15)
    }

    // MARK: 16.3 change 2 — the phantom filter

    /// An unresolved ARREST landing plus a short lift shelf is a take-off that
    /// was never followed by a kite flight. Either sign alone is common in real
    /// jumps, so only the conjunction fires — and it reads the arrest rule
    /// specifically, not "do we have a landing", because the settle fallback
    /// often supplies a window for exactly these events and the height still
    /// uses it. Measured over six logs: removes 8 phantoms, costs zero real
    /// jumps, and takes the suite's tallest phantom 2.54 -> 1.56 m.
    func testPhantomFilterRejectsAnIncompleteFlight() {
        func run(_ cfg: V16Config) -> (jumps: Int, events: [String]) {
            let delegate = CaptureDelegate()
            let engine = JumpEngineV16(cfg)
            engine.delegate = delegate
            var events: [String] = []
            engine.onDebug = { _, event in events.append(event) }
            // Shelf measures 1.10 s and the height 1.43 m, so the second clause
            // (short-and-small) is the one that fires.
            feed(into: engine, until: 8.0) { t in
                if t >= 0 && t < 0.02 { return 2.0 }
                if t >= 0 && t < 1.2 { return 0.57 }
                if t >= 1.2 { return -0.45 }   // descends to the end of the feed
                return 0
            }
            return (delegate.jumps.count, events)
        }

        let on = run(V16Config())
        XCTAssertEqual(on.jumps, 0)
        XCTAssertTrue(on.events.contains { $0.contains("reason=incompleteFlight") })

        var off = V16Config()
        off.phantomFilter = false
        XCTAssertEqual(run(off).jumps, 1, "the filter, not some other gate, is what removed it")
    }

    /// The filter must never reach a bench throw. A thrown watch is CAUGHT — a
    /// deceleration the arrest rule resolves trivially — so `fromArrest` is
    /// true and the test is skipped no matter how short the shelf is.
    func testPhantomFilterLeavesBenchThrowsAlone() {
        let delegate = CaptureDelegate()
        let engine = JumpEngineV16()
        engine.delegate = delegate

        feedThrow(into: engine, freeFallSec: 1.4, catchG: 15.0)

        XCTAssertEqual(delegate.jumps.count, 1)
        XCTAssertNotNil(delegate.jumps[0].airtimeSec)
    }

    // MARK: Helpers

    /// A take-off whose descent is never arrested, and which survives the 16.3
    /// phantom filter: the shelf runs past phantomShelfWideSec, so neither
    /// clause fires and the nil-airtime SENTINEL still reaches the delegate.
    /// That sentinel is load-bearing downstream — see the note in
    /// JumpDetectorV16.makeJump — so it has to stay under test.
    private func feedUnresolvedLanding(into engine: JumpEngineV16, gpsSpeedMS: Double? = nil) {
        feed(into: engine, until: 8.0, gpsSpeedMS: gpsSpeedMS) { t in
            if t >= 0 && t < 0.02 { return 2.0 }
            if t >= 0 && t < 1.6 { return 0.57 }
            if t >= 1.6 { return -0.45 }   // descends to the end of the feed
            return 0
        }
    }

    /// Pop, sustained UNLOAD shelf (the flight), water arrest. With the
    /// defaults it measures ~4.2 m over a 3.4 s resolved flight — big air, so
    /// it also exercises the immediate-report path.
    ///
    /// `unloadG` is world-vertical userAcceleration during the flight, in g and
    /// in the engine's sign convention (positive = unloaded; see the note at
    /// the top of this file). It is what the height integral actually measures:
    /// an endpoint-anchored double integral of -az over the flight, so a
    /// constant unload of `u` over a flight of T seconds peaks at u*g0*T^2/8.
    /// Under the 16.1 matched filter this amplitude barely mattered and a
    /// PRE-POP unweight was needed to make a fixture big; in 16.2 the arc is
    /// the measurement.
    /// `carveG` loads the rider for the 1.5 s before the pop (negative az —
    /// pressed INTO the water, the opposite of the flight's unload) and
    /// `slamG` adds a touchdown spike, so the diagnostics have something to
    /// measure. `gyroRadS` runs for the whole feed.
    private func feedSyntheticJump(
        into engine: JumpEngineV16,
        unloadG: Double = 0.57,
        flightSec: Double = 2.0,
        heightLeadInG: Double? = nil,
        attitudeDropout: ClosedRange<Double>? = nil,
        gpsSpeedMS: Double? = nil,
        gyroRadS: Double = 0,
        carveG: Double = 0,
        slamG: Double = 0,
        cfg: V16Config = V16Config(),
        flush: Bool = true
    ) {
        // The reported landing is the end of the descent run + landOffsetSec,
        // i.e. ~0.6 s past where the descent stops, so a touchdown load has to
        // run from the end of the descent through the settle to overlap the
        // impact window at all.
        let touchdown = flightSec + 0.8
        feed(into: engine,
             attitudeDropout: attitudeDropout,
             gpsSpeedMS: gpsSpeedMS,
             gyroRadS: gyroRadS,
             flush: flush,
             loadG: slamG > 0 ? { t, azG in
                 t >= touchdown && t < touchdown + 0.6 ? slamG : abs(azG)
             } : nil) { t in
            if t >= 0 && t < 0.02 { return 2.0 }
            if t >= 0 && t < flightSec { return unloadG }
            if t >= flightSec && t < flightSec + 0.8 { return -0.45 }
            if let heightLeadInG, t >= -0.3 && t < 0 { return heightLeadInG }
            if t >= -1.5 && t < 0 { return -carveG }
            return 0
        }
    }

    /// A watch thrown and caught: a modest release pop, TRUE free fall, then a
    /// catch that is several times stronger than the release, then the settle.
    /// This is the bench test the 16.2 package added — 3 of 4 real throws are
    /// detected and their height lands within 0.02 m of g*T^2/8.
    private func feedThrow(into engine: JumpEngineV16,
                           freeFallSec: Double,
                           catchG: Double = 3.0) {
        feed(into: engine, loadG: { t, azG in
            if t >= 0.02 && t < freeFallSec { return 1.0 }              // free fall: |ua| = 1 g
            if t >= freeFallSec && t < freeFallSec + 0.04 { return catchG }
            return abs(azG)
        }) { t in
            if t >= 0 && t < 0.02 { return 2.0 }                        // release
            if t >= 0 && t < freeFallSec { return 1.0 }                 // az = +1 g in free fall
            if t >= freeFallSec && t < freeFallSec + 0.04 { return -catchG }
            if t >= freeFallSec + 0.04 && t < freeFallSec + 0.8 { return -0.45 }
            return 0
        }
    }

    /// Feeds a 50 Hz stream — the watch's real rate, and the rate at which the
    /// boxSmooth bug is live (0.1 s = 5 samples per bin).
    ///
    /// The quaternion is identity, so device Z IS world Z and `accelerationZ`
    /// is the world-vertical channel in g directly. `loadG` defaults to
    /// |accelerationZ|, which is what purely vertical motion implies; the throw
    /// fixture overrides it because free fall reads 1 g of |userAcceleration|.
    private func feed(
        into engine: JumpEngineV16,
        attitudeDropout: ClosedRange<Double>? = nil,
        until end: Double = 18.0,
        gpsSpeedMS: Double? = nil,
        gyroRadS: Double = 0,
        flush: Bool = true,
        loadG: ((Double, Double) -> Double)? = nil,
        accelerationZ: (Double) -> Double
    ) {
        let hz = 50.0
        var t = -3.0
        var nextGpsT = -3.0
        while t <= end {
            let azG = accelerationZ(t)
            let hasAttitude = !(attitudeDropout?.contains(t) ?? false)
            engine.addIMU(
                t: t,
                loadG: loadG?(t, azG) ?? abs(azG),
                gyroRadS: gyroRadS,
                accel: (0, 0, azG),
                quat: hasAttitude ? (1, 0, 0, 0) : nil
            )
            if let gpsSpeedMS, t >= nextGpsT {
                // Straight line due east from the equator at a constant speed,
                // so haversine distance is exactly speed x elapsed time.
                engine.addGPS(t: t, lat: 0, lng: (t + 3.0) * gpsSpeedMS / 111_319.49, speedMS: gpsSpeedMS)
                nextGpsT += 0.1
            }
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
