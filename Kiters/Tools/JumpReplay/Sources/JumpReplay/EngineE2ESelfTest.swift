import Foundation

enum EngineE2ESelfTest {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(_ stdout: inout StdoutStream) -> Bool {
        do {
            try testLoaderPreservesV12Metadata()
            print("✓ replay loader preserves v12 sample metadata", to: &stdout)

            try testLoaderReadsKSLG2Streams()
            print("✓ replay loader reads KSLG v2 stream records", to: &stdout)

            try testV11WatchAdapterFullJump()
            print("✓ v11 watch-adapter E2E synthetic jump", to: &stdout)

            try testV12WatchAdapterInstantAndRefinedJump()
            print("✓ v12 watch-adapter E2E synthetic jump + refinement", to: &stdout)

            try testV13WatchAdapterPostLandingJump()
            print("✓ v13 watch-adapter E2E synthetic jump (post-landing classification)", to: &stdout)
            return true
        } catch {
            fputs("engine E2E self-test failed: \(error)\n", stderr)
            return false
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    private static func testLoaderPreservesV12Metadata() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiters-v12-loader-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let csv = """
        t,ax,ay,az,gvX,gvY,gvZ,gx,gy,gz,baro,spd,motionT,relAlt,baroT,submerged,waterDepthM,waterPressureHPa,evt
        1800000000.0,0.1,0.2,0.3,0,0,-1,0.01,0.02,0.03,1013.25,8.4,123.4,1.25,120.0,true,0.7,1020.5,V12_META
        """
        try csv.write(to: url, atomically: true, encoding: .utf8)

        let log = try Loader.load(url, forceFormat: nil)
        try require(log.samples.count == 1, "loader metadata fixture should produce one sample")
        let sample = log.samples[0]
        try require(log.format == .onDevice, "loader should detect on-device CSV format")
        try require(sample.motionTimestamp == 123.4, "loader should preserve motionTimestamp")
        try require(sample.relativeAltitude == 1.25, "loader should preserve relativeAltitude")
        try require(sample.barometerTimestamp == 120.0, "loader should preserve barometerTimestamp")
        try require(sample.submerged == true, "loader should preserve submerged state")
        try require(sample.waterDepth == 0.7, "loader should preserve water depth")
        try require(sample.waterPressure == 1020.5, "loader should preserve water pressure")
    }

    private static func testLoaderReadsKSLG2Streams() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiters-v12-loader-\(UUID().uuidString).kslog")
        defer { try? FileManager.default.removeItem(at: url) }

        let t0BootUs: UInt64 = 804_928_694_000_000
        let header = #"{"t0BootUs":804928694000000}"#.data(using: .utf8)!
        var data = Data()
        data.append(contentsOf: [0x4b, 0x53, 0x4c, 0x47, 2])
        appendUInt16(&data, UInt16(header.count))
        data.append(header)

        appendGPS(&data, tUs: 0, speedMS: 8.4)
        appendBaro(&data, tUs: 0, relAltM: 1.25, pressureHPa: 1013.25)
        appendAbsAlt(&data, tUs: 0, altitudeM: 12.345, accuracyM: 1.5, precisionM: 0.2)
        appendMotion(&data, tUs: 0, ax: 0.1, ay: 0.2, az: 0.3)
        appendMotion(&data, tUs: 5_000, ax: 0.2, ay: 0.1, az: 0.4)
        try data.write(to: url)

        let log = try Loader.load(url, forceFormat: nil)
        try require(log.samples.count == 2, "KSLG v2 fixture should decode two motion samples")
        try require(log.format == .onDevice, "KSLG v2 fixture should be on-device format")

        let first = log.samples[0]
        let second = log.samples[1]
        try require(abs((first.motionTimestamp ?? 0) - Double(t0BootUs) / 1_000_000.0) < 0.000_001,
                    "KSLG v2 should reconstruct raw boot-clock motion timestamp")
        try require(abs((second.motionTimestamp ?? 0) - (Double(t0BootUs) / 1_000_000.0 + 0.005)) < 0.000_001,
                    "KSLG v2 should preserve 200 Hz motion spacing")
        try require(first.relativeAltitude == 1.25, "KSLG v2 should preserve relativeAltitude")
        try require(first.pressure == 1013.25, "KSLG v2 should preserve pressure")
        try require(first.absoluteAltitude == 12.345, "KSLG v2 should preserve absoluteAltitude")
        try require(first.absoluteAltitudeAccuracy == 1.5, "KSLG v2 should preserve abs accuracy")
        try require(first.absoluteAltitudePrecision == 0.2, "KSLG v2 should preserve abs precision")
        try require(first.absoluteAltitudeTimestamp == first.motionTimestamp,
                    "KSLG v2 should preserve abs altitude timestamp")
        try require(log.speeds[0] == 8.4, "KSLG v2 should ZOH GPS speed onto motion rows")
    }

    private static func appendMotion(_ data: inout Data,
                                     tUs: UInt64,
                                     ax: Double,
                                     ay: Double,
                                     az: Double) {
        data.append(3)
        appendUInt64(&data, tUs)
        appendInt16(&data, scaledInt16(ax, 1000))
        appendInt16(&data, scaledInt16(ay, 1000))
        appendInt16(&data, scaledInt16(az, 1000))
        appendInt16(&data, 0)
        appendInt16(&data, 0)
        appendInt16(&data, 0)
        appendInt16(&data, 10_000)
        appendInt16(&data, 0)
        appendInt16(&data, 0)
        appendInt16(&data, 0)
    }

    private static func appendBaro(_ data: inout Data, tUs: UInt64, relAltM: Double, pressureHPa: Double) {
        data.append(5)
        appendUInt64(&data, tUs)
        appendInt32(&data, scaledInt32(relAltM, 1000))
        appendInt32(&data, scaledInt32(pressureHPa, 1000))
    }

    private static func appendAbsAlt(_ data: inout Data,
                                     tUs: UInt64,
                                     altitudeM: Double,
                                     accuracyM: Double,
                                     precisionM: Double) {
        data.append(6)
        appendUInt64(&data, tUs)
        appendInt32(&data, scaledInt32(altitudeM, 1000))
        appendInt32(&data, scaledInt32(accuracyM, 1000))
        appendInt32(&data, scaledInt32(precisionM, 1000))
    }

    private static func appendGPS(_ data: inout Data, tUs: UInt64, speedMS: Double) {
        data.append(7)
        appendUInt64(&data, tUs)
        appendInt32(&data, 0)
        appendInt32(&data, 0)
        appendUInt16(&data, UInt16((speedMS * 100).rounded()))
        appendUInt16(&data, UInt16.max)
        appendUInt16(&data, UInt16.max)
        appendUInt16(&data, UInt16.max)
        appendInt32(&data, Int32.min)
    }

    private static func scaledInt16(_ value: Double, _ scale: Double) -> Int16 {
        Int16(clamping: Int((value * scale).rounded()))
    }

    private static func scaledInt32(_ value: Double, _ scale: Double) -> Int32 {
        Int32(clamping: Int((value * scale).rounded()))
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private static func appendInt16(_ data: inout Data, _ value: Int16) {
        appendUInt16(&data, UInt16(bitPattern: value))
    }

    private static func appendUInt64(_ data: inout Data, _ value: UInt64) {
        appendUInt32(&data, UInt32(value & 0xffff_ffff))
        appendUInt32(&data, UInt32((value >> 32) & 0xffff_ffff))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private static func appendInt32(_ data: inout Data, _ value: Int32) {
        appendUInt32(&data, UInt32(bitPattern: value))
    }

    private static func testV11WatchAdapterFullJump() throws {
        let detector = JumpDetectorV11()
        detector.synchronousAnalysis = true
        detector.sessionId = "e2e-v11"

        var states: [JumpDetector.JumpState] = []
        var jumps: [Jump] = []
        var rich: [JumpResultV11] = []
        detector.onStateChanged = { states.append($0) }
        detector.onJumpDetected = { jumps.append($0) }
        detector.onJumpResultV11 = { rich.append($0) }
        detector.reset(mode: .standard)

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let dt = 1.0 / 50.0
        let duration = 11.0

        var t = 0.0
        while t <= duration {
            let phase: (accelMag: Double, signedLoad: Double, gyro: Double, pressure: Double)
            switch t {
            case 4.00..<4.14:
                phase = (2.45, 1.95, 3.2, 1013.25)
            case 4.14..<6.55:
                let progress = (t - 4.14) / 2.41
                let arc = 4.0 * progress * (1.0 - progress)
                phase = (0.95, 0.04, 0.5, 1013.25 - 0.32 * arc)
            case 6.55..<6.72:
                phase = (3.10, 2.55, 3.6, 1013.25)
            default:
                phase = (0.12, 1.00, 0.18, 1013.25)
            }

            let sample = sampleForSignedLoad(
                at: t0.addingTimeInterval(t),
                accelMag: phase.accelMag,
                signedLoad: phase.signedLoad,
                gyro: phase.gyro,
                pressure: phase.pressure
            )
            detector.updateGPS(
                speed: 8.5,
                altitude: 0,
                latitude: 32.0,
                longitude: 34.0 + t * 0.00002,
                course: 90,
                horizontalAccuracy: 5,
                timestamp: sample.timestamp
            )
            detector.processSample(sample)
            t += dt
        }

        _ = detector.endSession()

        try require(states.contains(.riding), "v11 adapter should enter riding state")
        try require(!rich.isEmpty, "v11 adapter should emit rich engine result. \(v11DebugSummary(detector))")
        try require(jumps.count == 1, "v11 adapter should emit exactly one jump, got \(jumps.count)")
        let jump = jumps[0]
        try require(jump.height >= 1.0, "v11 jump height should be plausible, got \(jump.height)")
        try require(abs(jump.airtime - 2.7) <= 0.35, "v11 airtime should match synthetic arc, got \(jump.airtime)")
        try require(jump.confidence >= 30, "v11 confidence should pass adapter accept gate, got \(jump.confidence)")
    }

    private static func v11DebugSummary(_ detector: JumpDetectorV11) -> String {
        guard !detector.debugSegments.isEmpty else { return "debugSegments=0" }
        return detector.debugSegments.prefix(3).map { segment in
            let reasons = segment.reasonCodes.joined(separator: "/")
            return "segment=\(segment.segmentStart)-\(segment.segmentEnd) decision=\(segment.decision) score=\(segment.score) reasons=\(reasons) metrics=\(segment.metrics)"
        }.joined(separator: " | ")
    }

    private static func testV12WatchAdapterInstantAndRefinedJump() throws {
        let detector = JumpDetectorV12()
        detector.synchronousAnalysis = true
        detector.sessionId = "e2e-v12"

        var states: [JumpDetector.JumpState] = []
        var instant: [Jump] = []
        var refined: [Jump] = []
        var retracted: [String] = []
        detector.onStateChanged = { states.append($0) }
        detector.onJumpDetected = { instant.append($0) }
        detector.onJumpUpdated = { refined.append($0) }
        detector.onJumpRetracted = { retracted.append($0) }
        detector.reset(mode: .standard)

        let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        func date(_ t: TimeInterval) -> Date {
            Date(timeIntervalSince1970: bootWallClock + t)
        }
        // V12 now consumes only the absolute-altitude channel, so the fixture
        // feeds the arc through absoluteAltitude/absoluteAltitudeTimestamp.
        func feed(t: TimeInterval,
                  accel: Double,
                  relAlt: Double? = nil,
                  baroT: TimeInterval? = nil,
                  submerged: Bool? = nil) {
            let sample = IMUSample(
                timestamp: date(t),
                accelerationX: accel,
                accelerationY: 0,
                accelerationZ: 0,
                rotationX: 0,
                rotationY: 0,
                rotationZ: 0,
                gravity: Vector3(x: 0, y: 0, z: -1),
                pressure: nil,
                motionTimestamp: t,
                absoluteAltitude: relAlt,
                absoluteAltitudeTimestamp: baroT,
                submerged: submerged
            )
            detector.updateGPS(
                speed: 8.0,
                altitude: 0,
                latitude: 32.0,
                longitude: 34.0 + t * 0.00003,
                course: 90,
                horizontalAccuracy: 4,
                timestamp: sample.timestamp
            )
            detector.processSample(sample)
        }

        for t in stride(from: 0.0, through: 4.9, by: 0.1) {
            if [0.0, 1.0, 2.0, 3.0, 4.0].contains(where: { abs(t - $0) < 0.0001 }) {
                feed(t: t, accel: 0.08, relAlt: 0, baroT: t)
            } else {
                feed(t: t, accel: 0.08)
            }
        }

        feed(t: 5.0, accel: 2.5)
        for t in stride(from: 5.1, through: 8.1, by: 0.1) {
            if abs(t - 6.0) < 0.0001 {
                feed(t: t, accel: 0.03, relAlt: 1.6, baroT: 6.0)
            } else if abs(t - 7.0) < 0.0001 {
                feed(t: t, accel: 0.03, relAlt: 2.4, baroT: 7.0)
            } else if abs(t - 8.0) < 0.0001 {
                feed(t: t, accel: 0.03, relAlt: 1.6, baroT: 8.0)
            } else {
                feed(t: t, accel: 0.03)
            }
        }
        feed(t: 8.2, accel: 2.1)
        feed(t: 8.4, accel: 0.08, relAlt: 0.2, baroT: 8.4)
        feed(t: 8.9, accel: 0.08, relAlt: 0.1, baroT: 8.9)
        feed(t: 9.5, accel: 0.08, relAlt: 0.0, baroT: 9.5)
        feed(t: 10.5, accel: 0.08, relAlt: 0.0, baroT: 10.5)
        feed(t: 11.3, accel: 0.06)

        _ = detector.endSession()

        try require(states.contains(.riding), "v12 adapter should enter riding state")
        try require(states.contains(.airborne), "v12 adapter should enter airborne state")
        try require(instant.count == 1, "v12 adapter should emit one instant jump, got \(instant.count)")
        try require(refined.count == 1, "v12 adapter should emit one refined jump, got \(refined.count)")
        try require(retracted.isEmpty, "v12 adapter should not retract this valid jump")
        try require(refined[0].id == instant[0].id, "v12 refined jump should update the instant jump id")
        try require(refined[0].height >= 1.5, "v12 refined height should clear display gate, got \(refined[0].height)")
        try require(abs(refined[0].airtime - 3.2) < 0.12, "v12 airtime should use IMU landing evidence, got \(refined[0].airtime)")
    }

    /// Full-stack v13 check: 50 Hz IMU + 3 Hz absolute altitude + GPS through the
    /// watch adapter. One arc (pop at 8 s, apex ≈ 2.57 m, impact at 11 s) must be
    /// classified after landing and emitted exactly once within the 5 s budget.
    private static func testV13WatchAdapterPostLandingJump() throws {
        let detector = JumpDetectorV13()
        detector.synchronousAnalysis = true
        detector.sessionId = "e2e-v13"

        var states: [JumpDetector.JumpState] = []
        var jumps: [Jump] = []
        detector.onStateChanged = { states.append($0) }
        detector.onJumpDetected = { jumps.append($0) }
        detector.reset(mode: .standard)

        let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        func date(_ t: TimeInterval) -> Date {
            Date(timeIntervalSince1970: bootWallClock + t)
        }
        func feed(t: TimeInterval, accel: Double, gyro: Double, absAlt: Double?) {
            let sample = IMUSample(
                timestamp: date(t),
                accelerationX: accel,
                accelerationY: 0,
                accelerationZ: 0,
                rotationX: gyro,
                rotationY: 0,
                rotationZ: 0,
                gravity: Vector3(x: 0, y: 0, z: -1),
                pressure: nil,
                motionTimestamp: t,
                absoluteAltitude: absAlt,
                absoluteAltitudeTimestamp: absAlt != nil ? t : nil
            )
            detector.updateGPS(
                speed: 9.0,
                altitude: 0,
                latitude: 32.0,
                longitude: 34.0 + t * 0.00003,
                course: 90,
                horizontalAccuracy: 4,
                timestamp: sample.timestamp
            )
            detector.processSample(sample)
        }

        let takeoff = 8.0
        let landing = 11.0
        let dt = 0.02
        var nextAltT = 0.0
        var t = 0.0
        while t <= 18.0 {
            var accel = 0.15
            var gyro = 0.3
            if abs(t - takeoff) < 0.015 {
                accel = 2.6; gyro = 4.5              // takeoff pop
            } else if abs(t - landing) < 0.015 {
                accel = 2.9; gyro = 3.0              // landing impact
            } else if t > takeoff, t < landing {
                accel = 0.05; gyro = 1.0             // in flight
            }

            var absAlt: Double?
            if t + 1e-9 >= nextAltT {
                if t > takeoff, t < landing {
                    let p = (t - takeoff) / (landing - takeoff)
                    absAlt = 100.0 + 2.6 * 4 * p * (1 - p)
                } else if t >= landing {
                    let tick = Int(((t - landing) * 3.0).rounded()) % 3
                    absAlt = 100.0 + Double(tick - 1) * 0.01
                } else {
                    absAlt = 100.0
                }
                nextAltT += 1.0 / 3.0
            }
            feed(t: t, accel: accel, gyro: gyro, absAlt: absAlt)
            t += dt
        }

        let late = detector.endSession()

        try require(states.contains(.riding), "v13 adapter should enter riding state")
        try require(states.contains(.airborne), "v13 adapter should flag the open candidate as airborne")
        try require(jumps.count == 1, "v13 adapter should emit exactly one final jump, got \(jumps.count)")
        try require(late.isEmpty, "v13 flush should have nothing pending after emission, got \(late.count)")
        let jump = jumps[0]
        try require(abs(jump.height - 2.57) <= 0.35, "v13 height should match the synthetic apex, got \(jump.height)")
        try require(abs(jump.airtime - 2.9) <= 0.4, "v13 airtime should match the synthetic arc, got \(jump.airtime)")
        try require(jump.confidence >= 60, "v13 confidence should be high on a clean arc, got \(jump.confidence)")
        try require(jump.heightSource == "absoluteAltitude", "v13 height source should be absolute altitude")
        try require(jump.jumpDistance > 2, "v13 should derive a horizontal distance from GPS, got \(jump.jumpDistance)")
    }

    private static func sampleForSignedLoad(at date: Date,
                                            accelMag: Double,
                                            signedLoad: Double,
                                            gyro: Double,
                                            pressure: Double) -> IMUSample {
        let az = 1.0 - signedLoad
        let lateral = max(0, accelMag * accelMag - az * az).squareRoot()
        return IMUSample(
            timestamp: date,
            accelerationX: lateral,
            accelerationY: 0,
            accelerationZ: az,
            rotationX: gyro,
            rotationY: 0,
            rotationZ: 0,
            gravity: Vector3(x: 0, y: 0, z: -1),
            pressure: pressure
        )
    }
}
