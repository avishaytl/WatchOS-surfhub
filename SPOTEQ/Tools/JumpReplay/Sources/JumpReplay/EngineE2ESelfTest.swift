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

            try testSessionLoggerWritesStructuredV13Audit()
            print("✓ SessionLogger writes and reloads structured V13 audit", to: &stdout)

            try testSessionLoggerPreviewReadsStatusRecord()
            print("✓ SessionLogger preview reads complete KSLG v2 status records", to: &stdout)

            try testV11WatchAdapterFullJump()
            print("✓ v11 watch-adapter E2E synthetic jump", to: &stdout)

            try testV12WatchAdapterInstantAndRefinedJump()
            print("✓ v12 watch-adapter E2E synthetic jump + refinement", to: &stdout)

            try testV13WatchAdapterPostLandingJump()
            print("✓ v13 watch-adapter E2E synthetic jump (post-landing classification)", to: &stdout)

            try testV13UserHeightSettingOnlyChangesCountThreshold()
            print("✓ v13 user height setting is isolated from internal detection thresholds", to: &stdout)

            try testV13BarometerOnlyJumpWithoutGPSOrIMUSpike()
            print("✓ v13 accepts a barometer-only jump without GPS or IMU spike", to: &stdout)

            try testV13BarometerJumpSurvivesPostLandingAltitudeDip()
            print("✓ v13 lands on baseline return before a post-landing altitude dip", to: &stdout)

            try testV13RejectsAltitudeDipRecovery()
            print("✓ v13 rejects pressure-dip recovery with no physical jump", to: &stdout)

            try testV13AcceptsUncappedThirtyTwoMetreArc()
            print("✓ v13 accepts an uncapped progressive 32 m arc", to: &stdout)

            try testV13RejectsTwentySixMetreRectangularNoise()
            print("✓ v13 rejects a 26 m pulse without a physical arc", to: &stdout)

            try testV13RejectsTwentySixMetreArcThatIsTooFast()
            print("✓ v13 rejects a progressive 26 m arc with impossible timing", to: &stdout)

            try testV13ResetsOnAccuracyReanchorBelowLegacyAltitudeThreshold()
            print("✓ v13 isolates a 9.94 m re-anchor signalled by accuracy", to: &stdout)

            try testV13ResetsOnCumulativeDatumShift()
            print("✓ v13 isolates a cumulative sub-threshold datum shift", to: &stdout)

            try testV14CleanJumpPrefersRelativeHeight()
            print("✓ v14 clean jump: relative height preferred over a healthy absolute cross-check", to: &stdout)

            try testV14FrozenAbsoluteFallsBackToRelative()
            print("✓ v14 frozen absolute channel falls back to relative height", to: &stdout)

            try testV14WaterDipOpensNoJumpAndKeepsBaselineSane()
            print("✓ v14 water dip opens no jump and cannot poison the baseline", to: &stdout)

            try testV14DetectsWithoutAnyGPS()
            print("✓ v14 detects fully without GPS; GPS metrics stay empty", to: &stdout)

            try testV14RiseBelowUserSettingIsNotCounted()
            print("✓ v14 rise below the user's counted-height setting is rejected", to: &stdout)
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
            .appendingPathComponent("spoteq-v12-loader-\(UUID().uuidString).csv")
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
            .appendingPathComponent("spoteq-v12-loader-\(UUID().uuidString).kslog")
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
        var audit = V13AuditRecord(
            monotonicTime: Double(t0BootUs) / 1_000_000.0,
            stage: "takeoff",
            action: "evaluateCandidate",
            decision: "waiting",
            reason: "sensorWarmup",
            values: ["absoluteAltitudeM": 12.345],
            conditions: [
                .init(id: "sensorWarmup", actual: 1, comparator: ">=", expected: 8, passed: false, unit: "s")
            ]
        )
        audit.sequence = 1
        audit.sessionID = "kslg2-fixture"
        appendAudit(&data, tUs: 0, record: audit)
        appendMotion(&data, tUs: 0, ax: 0.1, ay: 0.2, az: 0.3)
        appendMotion(&data, tUs: 5_000, ax: 0.2, ay: 0.1, az: 0.4)
        appendAbsAlt(&data, tUs: 10_000_000, altitudeM: 12.5, accuracyM: 1.5, precisionM: 0.2)
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
        try require(log.v13AuditRecords.count == 1, "KSLG v2 should decode V13 audit tag 12")
        try require(log.v13AuditRecords[0].action == "evaluateCandidate",
                    "KSLG v2 should preserve the V13 audit action")
        try require(log.v13AuditRecords[0].conditions.first?.passed == false,
                    "KSLG v2 should preserve failed V13 conditions")
        try require(abs(log.timelineDurationSec - 10) < 0.000_001,
                    "KSLG v2 duration should include altitude after motion stops; got \(log.timelineDurationSec)")
    }

    private static func testSessionLoggerWritesStructuredV13Audit() throws {
        let logger = SessionLogger.shared
        let sessionID = "audit-\(UUID().uuidString)"
        let t = ProcessInfo.processInfo.systemUptime
        logger.start(
            sessionId: sessionID,
            mode: .standard,
            sensorOnly: true,
            engine: .v13Pure,
            v13Config: V13Config()
        )
        guard let url = logger.mostRecentLogURL() else {
            throw Failure(description: "SessionLogger should expose the V13 audit fixture URL")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let audit = V13CalculationLogService.shared
        audit.beginSession(sessionID: sessionID, t: t)
        audit.configure(V13Config(), t: t + 0.001)
        audit.attachSink { logger.logV13Audit($0) }
        audit.record(V13AuditRecord(
            monotonicTime: t,
            stage: "result",
            action: "emitJump",
            decision: "accepted",
            candidateID: 7,
            values: ["heightM": 2.4, "airtimeSec": 2.1]
        ))
        audit.endSession(t: t + 1, durationSec: 1, reportedJumpCount: 1)
        logger.logMotionSample(IMUSample(
            timestamp: Date(),
            accelerationX: 0.1,
            accelerationY: 0.2,
            accelerationZ: 0.3,
            rotationX: 0,
            rotationY: 0,
            rotationZ: 0,
            gravity: Vector3(x: 0, y: 0, z: -1),
            pressure: nil,
            motionTimestamp: t
        ))
        logger.stop()
        audit.detachSink()

        let loaded = try Loader.load(url)
        try require(loaded.v13AuditRecords.first?.kind == "schema",
                    "SessionLogger fixture should preserve the self-describing V13 schema")
        try require(loaded.v13AuditRecords.first?.definitions.isEmpty == false,
                    "SessionLogger fixture should preserve V13 parameter explanations")
        try require(loaded.v13AuditRecords.contains(where: { $0.candidateID == 7 }),
                    "SessionLogger should preserve V13 candidate ids")
        try require(loaded.v13AuditRecords.first(where: { $0.candidateID == 7 })?.values["heightM"] == 2.4,
                    "SessionLogger should preserve V13 calculated values")
        try require(loaded.v13AuditRecords.last?.kind == "summary",
                    "SessionLogger fixture should preserve the V13 end-of-session summary")
    }

    private static func testSessionLoggerPreviewReadsStatusRecord() throws {
        let logger = SessionLogger.shared
        logger.start(
            sessionId: "status-\(UUID().uuidString)",
            mode: .standard,
            sensorOnly: true,
            engine: .v14Hybrid
        )
        guard let url = logger.mostRecentLogURL() else {
            throw Failure(description: "SessionLogger should expose the status preview fixture URL")
        }
        logger.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        var status = Data()
        appendStatus(&status, tUs: 1_000_000, batteryPct: 88, baroSource: 2, baroHz: 1.0)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: status)
        try handle.close()

        let preview = logger.buildShareText(for: url, fileSize: "test", maxChars: 100_000)
        try require(preview.contains("STATUS,1.000000"),
                    "SessionLogger preview should decode a status record without crashing")
        try require(preview.contains("baroHz=1.00"),
                    "SessionLogger preview should preserve the complete status payload")
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

    private static func appendAudit(_ data: inout Data, tUs: UInt64, record: V13AuditRecord) {
        let payload = try! JSONEncoder().encode(record)
        data.append(12)
        appendUInt64(&data, tUs)
        appendUInt32(&data, UInt32(payload.count))
        data.append(payload)
    }

    private static func appendStatus(_ data: inout Data,
                                     tUs: UInt64,
                                     batteryPct: Int16,
                                     baroSource: UInt8,
                                     baroHz: Double) {
        data.append(11)
        appendUInt64(&data, tUs)
        data.append(0) // thermal
        data.append(0) // low power
        appendInt16(&data, batteryPct)
        data.append(baroSource)
        appendUInt16(&data, UInt16((baroHz * 100).rounded()))
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
    /// watch adapter. One arc (pop at 12 s, apex ≈ 2.57 m, impact at 15 s) must be
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

        let takeoff = 12.0
        let landing = 15.0
        let dt = 0.02
        var nextAltT = 0.0
        var t = 0.0
        while t <= 22.0 {
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

    /// V13 detection is absolute-barometer based: no GPS fix and no IMU spike
    /// must still emit a jump when the altitude arc clears the baseline average.
    private static func testV13BarometerOnlyJumpWithoutGPSOrIMUSpike() throws {
        let detector = JumpDetectorV13()
        detector.synchronousAnalysis = true
        detector.sessionId = "e2e-v13-sensor-only"

        var jumps: [Jump] = []
        detector.onJumpDetected = { jumps.append($0) }
        detector.reset(mode: .standard)

        let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        func date(_ t: TimeInterval) -> Date {
            Date(timeIntervalSince1970: bootWallClock + t)
        }

        let takeoff = 12.0
        let landing = 15.0
        let dt = 0.02
        var nextAltT = 0.0
        var t = 0.0
        while t <= 22.0 {
            let accel = 0.15
            let gyro = 0.3

            var absAlt: Double?
            if t + 1e-9 >= nextAltT {
                let u = min(max((t - takeoff) / (landing - takeoff), 0), 1)
                let height = t < takeoff ? 0 : max(0, sin(.pi * u)) * 2.6
                absAlt = 40 + height
                nextAltT += 1.0 / 3.0
            }

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
            detector.processSample(sample)
            t += dt
        }

        let late = detector.endSession()
        for jump in late {
            jumps.append(jump)
        }

        try require(jumps.count == 1, "v13 barometer-only jump should emit exactly one jump, got \(jumps.count)")
        let jump = jumps[0]
        try require(jump.height >= 2.0, "v13 barometer-only height should match the altitude arc, got \(jump.height)")
        try require(abs(jump.airtime - 3.0) <= 0.45, "v13 barometer-only airtime should match the arc, got \(jump.airtime)")
        try require(jump.jumpDistance == 0, "v13 barometer-only jump should not invent GPS distance, got \(jump.jumpDistance)")
    }

    private static func testV13UserHeightSettingOnlyChangesCountThreshold() throws {
        let defaults = UserDefaults.standard
        let keys = [
            V13Settings.minCountedHeightM,
            V13Settings.candidateRiseM,
            V13Settings.takeoffWindowSec,
            V13Settings.landingDescentM,
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        defaults.set(2.0, forKey: V13Settings.minCountedHeightM)
        defaults.removeObject(forKey: V13Settings.candidateRiseM)
        defaults.removeObject(forKey: V13Settings.takeoffWindowSec)
        defaults.removeObject(forKey: V13Settings.landingDescentM)

        let detector = JumpDetectorV13()
        detector.synchronousAnalysis = true
        detector.reset(mode: .standard)
        let config = detector.effectiveConfiguration

        try require(config.minCountedHeightM == 2.0,
                    "v13 should load the user's 2 m counted-height preference")
        try require(config.candidateRiseM == 1.0,
                    "user counted height must not alter the 1 m candidate rise")
        try require(config.takeoffWindowSec == 1.0,
                    "user counted height must not alter the 1 s takeoff window")
        try require(config.landingDescentM == 0.5,
                    "user counted height must not alter the 0.5 m landing descent")
    }

    /// A real absolute-altitude jump can return to the takeoff baseline and then
    /// suffer a wet-port/splash dip. V13 must close the jump on baseline return
    /// instead of waiting for a late stable window that would exceed max airtime.
    private static func testV13BarometerJumpSurvivesPostLandingAltitudeDip() throws {
        let detector = JumpDetectorV13()
        detector.synchronousAnalysis = true
        detector.sessionId = "e2e-v13-jump-then-dip"

        var jumps: [Jump] = []
        detector.onJumpDetected = { jumps.append($0) }
        detector.reset(mode: .standard)

        let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        func date(_ t: TimeInterval) -> Date {
            Date(timeIntervalSince1970: bootWallClock + t)
        }

        let takeoff = 12.0
        let landing = 14.0
        let dt = 0.02
        var nextAltT = 0.0
        var t = 0.0
        while t <= 32.0 {
            var absAlt: Double?
            if t + 1e-9 >= nextAltT {
                if t >= takeoff, t <= landing {
                    let u = min(max((t - takeoff) / (landing - takeoff), 0), 1)
                    absAlt = 80.0 + sin(.pi * u) * 2.4
                } else if t > landing, t < 28.0 {
                    absAlt = 78.0 + sin((t - landing) * .pi / 2.0) * 2.0
                } else {
                    absAlt = 80.0
                }
                nextAltT += 1.0 / 3.0
            }

            let sample = IMUSample(
                timestamp: date(t),
                accelerationX: 0.15,
                accelerationY: 0,
                accelerationZ: 0,
                rotationX: 0.3,
                rotationY: 0,
                rotationZ: 0,
                gravity: Vector3(x: 0, y: 0, z: -1),
                pressure: nil,
                motionTimestamp: t,
                absoluteAltitude: absAlt,
                absoluteAltitudeTimestamp: absAlt != nil ? t : nil
            )
            detector.processSample(sample)
            t += dt
        }

        let late = detector.endSession()
        for jump in late {
            jumps.append(jump)
        }

        try require(jumps.count == 1, "v13 jump followed by altitude dip should emit exactly one jump, got \(jumps.count)")
        let jump = jumps[0]
        try require(jump.height >= 2.0, "v13 post-dip jump height should match the altitude arc, got \(jump.height)")
        try require(jump.airtime <= 3.0, "v13 should land on baseline return before the dip, got airtime \(jump.airtime)")
        try require(jump.jumpDistance == 0, "v13 post-dip jump should not invent GPS distance, got \(jump.jumpDistance)")
    }

    /// A wet pressure port can push altitude several metres down and then
    /// recover while the wrist is moving. That recovery used to be selected as
    /// the lowest takeoff point by the historical scanner and emitted as a
    /// jump. A robust pre-event baseline must keep this at zero detections.
    private static func testV13RejectsAltitudeDipRecovery() throws {
        let detector = JumpDetectorV13()
        detector.synchronousAnalysis = true
        detector.sessionId = "e2e-v13-dip-recovery"

        var jumps: [Jump] = []
        detector.onJumpDetected = { jumps.append($0) }
        detector.reset(mode: .standard)

        let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        func date(_ t: TimeInterval) -> Date {
            Date(timeIntervalSince1970: bootWallClock + t)
        }

        let dt = 0.02
        var nextAltT = 0.0
        var t = 0.0
        while t <= 30.0 {
            let accel = (t >= 17.0 && t <= 19.0) ? 2.4 : 0.2
            let gyro = (t >= 17.0 && t <= 19.0) ? 4.8 : 0.3
            var absAlt: Double?
            if t + 1e-9 >= nextAltT {
                switch t {
                case 0..<16: absAlt = 100.0
                case 16..<17: absAlt = 97.0
                case 17..<18: absAlt = 98.5
                default: absAlt = 100.0
                }
                nextAltT += 1.0 / 3.0
            }

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
                speed: 7.0,
                altitude: 0,
                latitude: 32.0,
                longitude: 34.0 + t * 0.00002,
                course: 90,
                horizontalAccuracy: 4,
                timestamp: sample.timestamp
            )
            detector.processSample(sample)
            t += dt
        }

        let late = detector.endSession()
        try require(jumps.isEmpty, "v13 must reject altitude dip recovery, got \(jumps.count) jump(s)")
        try require(late.isEmpty, "v13 dip recovery should not leave a flush result")
    }

    /// Height is not a rejection or clamping signal. This deliberately sparse
    /// 1 Hz fixture starts with a 16 m sample-to-sample rise (above the removed
    /// 12 m datum gate) and reaches 32 m (above the removed 30 m result cap).
    /// Its progressive ascent/descent and clean baseline return make it valid.
    private static func testV13AcceptsUncappedThirtyTwoMetreArc() throws {
        let detector = JumpDetectorV13()
        detector.synchronousAnalysis = true
        detector.reset(mode: .standard)

        var jumps: [Jump] = []
        detector.onJumpDetected = { jumps.append($0) }

        func feed(t: TimeInterval, altitudeM: Double) {
            detector.processAbsoluteAltitude(
                sensorT: t,
                receivedT: t,
                altitudeM: altitudeM,
                accuracyM: 5.0,
                precisionM: 0.5
            )
        }

        for second in 0...12 {
            feed(t: Double(second), altitudeM: 100.0)
        }
        feed(t: 13.0, altitudeM: 116.0)
        feed(t: 14.0, altitudeM: 127.71)
        feed(t: 15.0, altitudeM: 132.0)
        feed(t: 16.0, altitudeM: 127.71)
        feed(t: 17.0, altitudeM: 116.0)
        feed(t: 18.0, altitudeM: 100.0)

        try require(detector.altitudeStreamResetCount == 0,
                    "v13 must not treat a 16 m rise as a datum reset")
        try require(jumps.count == 1,
                    "v13 should accept one progressive 32 m arc, got \(jumps.count)")
        try require(abs(jumps[0].height - 32.0) <= 0.05,
                    "v13 must report the measured height without a cap, got \(jumps[0].height)")
    }

    /// A large value is not automatically a jump either. A one-frame climb to
    /// a 26 m plateau and one-frame return has no intermediate ascent/descent
    /// samples and is therefore a sensor pulse, despite its four-second span.
    private static func testV13RejectsTwentySixMetreRectangularNoise() throws {
        let detector = JumpDetectorV13()
        detector.synchronousAnalysis = true
        detector.reset(mode: .standard)

        var jumps: [Jump] = []
        detector.onJumpDetected = { jumps.append($0) }

        func feed(t: TimeInterval, altitudeM: Double) {
            detector.processAbsoluteAltitude(
                sensorT: t,
                receivedT: t,
                altitudeM: altitudeM,
                accuracyM: 5.0,
                precisionM: 0.5
            )
        }

        for second in 0...12 {
            feed(t: Double(second), altitudeM: 100.0)
        }
        feed(t: 13.0, altitudeM: 126.0)
        feed(t: 14.0, altitudeM: 126.0)
        feed(t: 15.0, altitudeM: 126.0)
        feed(t: 16.0, altitudeM: 100.0)

        try require(detector.altitudeStreamResetCount == 0,
                    "v13 should classify the 26 m pulse by arc quality, not a height reset")
        try require(jumps.isEmpty,
                    "v13 must reject a 26 m value without a progressive arc, got \(jumps.count) jump(s)")
    }

    /// Intermediate samples alone are not enough: this pulse has three clean
    /// ascent and descent steps, but completes 26 m in 2.0 seconds. It must fail
    /// the height/airtime coherence check rather than being accepted for shape.
    private static func testV13RejectsTwentySixMetreArcThatIsTooFast() throws {
        let detector = JumpDetectorV13()
        detector.synchronousAnalysis = true
        detector.reset(mode: .standard)

        var jumps: [Jump] = []
        detector.onJumpDetected = { jumps.append($0) }

        func feed(t: TimeInterval, altitudeM: Double) {
            detector.processAbsoluteAltitude(
                sensorT: t,
                receivedT: t,
                altitudeM: altitudeM,
                accuracyM: 5.0,
                precisionM: 0.5
            )
        }

        for second in 0...11 {
            feed(t: Double(second), altitudeM: 100.0)
        }
        feed(t: 12.0, altitudeM: 108.0)
        feed(t: 12.2, altitudeM: 118.0)
        feed(t: 12.4, altitudeM: 126.0)
        feed(t: 12.6, altitudeM: 118.0)
        feed(t: 12.8, altitudeM: 108.0)
        feed(t: 13.0, altitudeM: 100.0)

        try require(detector.altitudeStreamResetCount == 0,
                    "v13 should evaluate the fast 26 m arc without a magnitude reset")
        try require(jumps.isEmpty,
                    "v13 must reject a physically incoherent 26 m arc, got \(jumps.count) jump(s)")
    }

    /// Regression for the 21:25:55 callback: altitude moved 61.36 -> 51.43 m
    /// (9.94 m, below the historical 12 m guard) while accuracy moved
    /// 4.82 -> 7.57 m. The accuracy discontinuity must split the datum epochs.
    private static func testV13ResetsOnAccuracyReanchorBelowLegacyAltitudeThreshold() throws {
        let detector = JumpDetectorV13()
        detector.synchronousAnalysis = true
        detector.reset(mode: .standard)

        func feed(t: TimeInterval, altitudeM: Double, accuracyM: Double) {
            detector.processAbsoluteAltitude(
                sensorT: t,
                receivedT: t,
                altitudeM: altitudeM,
                accuracyM: accuracyM,
                precisionM: 0.5
            )
        }

        feed(t: 0.000, altitudeM: 61.471, accuracyM: 4.820)
        feed(t: 1.003, altitudeM: 61.363, accuracyM: 4.821)
        feed(t: 2.006, altitudeM: 51.427, accuracyM: 7.569)

        try require(detector.altitudeStreamResetCount == 1,
                    "v13 should reset once for the 9.94 m accuracy re-anchor, got \(detector.altitudeStreamResetCount)")
        try require(detector.lastAltitudeStreamResetReason?.hasPrefix("absoluteAccuracyStep") == true,
                    "v13 should attribute the reset to accuracy, got \(detector.lastAltitudeStreamResetReason ?? "nil")")
    }

    /// Some Core Motion recalibrations arrive as a staircase rather than one
    /// >12 m step. Three downward 3 m corrections must be treated as one 9 m
    /// datum move while the detector is still riding.
    private static func testV13ResetsOnCumulativeDatumShift() throws {
        let detector = JumpDetectorV13()
        detector.synchronousAnalysis = true
        detector.reset(mode: .standard)

        func feed(t: TimeInterval, altitudeM: Double) {
            detector.processAbsoluteAltitude(
                sensorT: t,
                receivedT: t,
                altitudeM: altitudeM,
                accuracyM: 5.0,
                precisionM: 0.5
            )
        }

        feed(t: 0.000, altitudeM: 100.0)
        feed(t: 0.333, altitudeM: 100.0)
        feed(t: 0.666, altitudeM: 100.0)
        feed(t: 0.999, altitudeM: 97.0)
        feed(t: 1.332, altitudeM: 94.0)
        feed(t: 1.665, altitudeM: 91.0)

        try require(detector.altitudeStreamResetCount == 1,
                    "v13 should reset once for a cumulative 9 m datum shift, got \(detector.altitudeStreamResetCount)")
        try require(detector.lastAltitudeStreamResetReason?.hasPrefix("absoluteDatumCumulative") == true,
                    "v13 should attribute the reset to cumulative datum movement, got \(detector.lastAltitudeStreamResetReason ?? "nil")")
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

    // MARK: - V14 hybrid engine scenarios

    /// Synthetic sensor world for the V14 detector: 50 Hz IMU with a
    /// gravity-projected load profile, relative altitude at a real barometer
    /// cadence, a 1 Hz direct absolute stream, optional GPS and submersion.
    private struct V14Scenario {
        var duration: TimeInterval = 30
        var gpsSpeed: Double?
        var loadAt: (TimeInterval) -> Double = { _ in 1.0 }
        var relAltAt: (TimeInterval) -> Double = { _ in 0.0 }
        var relCadenceSec: TimeInterval = 0.5
        var absAltAt: ((TimeInterval) -> Double)?
    }

    private static func runV14Scenario(_ s: V14Scenario) -> (jumps: [Jump], states: [JumpDetector.JumpState], detector: JumpDetectorV14) {
        let v14Keys = [
            "v13MinRiseM", "v14BaselineWindowSec", "v14PopG", "v14RequirePop",
            "v14UnweightG", "v14UnweightSec", "v14LandingImpactG",
            "v14FlightLoadCeilingG", "v14FlightEndHoldSec", "v14LandingStableSec",
            "v14LandingStableBandM", "v14MinAirtimeSec", "v14MaxFlightSec",
            "v14AllowBallisticHeight"
        ]
        v14Keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }

        let detector = JumpDetectorV14()
        detector.synchronousAnalysis = true
        detector.sessionId = "e2e-v14"

        var jumps: [Jump] = []
        var states: [JumpDetector.JumpState] = []
        detector.onJumpDetected = { jumps.append($0) }
        detector.onStateChanged = { states.append($0) }
        detector.reset(mode: .standard)

        let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        func date(_ t: TimeInterval) -> Date {
            Date(timeIntervalSince1970: bootWallClock + t)
        }

        let dt = 0.02
        var nextRelT: TimeInterval = 0
        var nextAbsT: TimeInterval = 0
        var nextGpsT: TimeInterval = 0
        var t: TimeInterval = 0
        while t <= s.duration {
            if let speed = s.gpsSpeed, t + 1e-9 >= nextGpsT {
                detector.updateGPS(
                    speed: speed, altitude: 0,
                    latitude: 32.0, longitude: 34.0 + t * 0.00003,
                    course: 90, horizontalAccuracy: 4, timestamp: date(t)
                )
                nextGpsT += 1.0
            }

            var relAlt: Double?
            var relT: TimeInterval?
            if t + 1e-9 >= nextRelT {
                relAlt = s.relAltAt(t)
                relT = t
                nextRelT += s.relCadenceSec
            }

            // Vertical load L maps to userAcceleration z via L = −az + 1
            // under gravity (0, 0, −1).
            let az = 1.0 - s.loadAt(t)
            let sample = IMUSample(
                timestamp: date(t),
                accelerationX: 0, accelerationY: 0, accelerationZ: az,
                rotationX: 0.6, rotationY: 0, rotationZ: 0,
                gravity: Vector3(x: 0, y: 0, z: -1),
                pressure: nil,
                motionTimestamp: t,
                relativeAltitude: relAlt,
                barometerTimestamp: relT
            )
            detector.processSample(sample)

            // The direct absolute stream ticks at 1 Hz; the detector must drop
            // every sample outside the on-demand jump window.
            if let absAltAt = s.absAltAt, t + 1e-9 >= nextAbsT {
                detector.processAbsoluteAltitude(
                    sensorT: t, receivedT: t,
                    altitudeM: absAltAt(t), accuracyM: 2.0, precisionM: 0.5
                )
                nextAbsT += 1.0
            }
            t += dt
        }

        jumps.append(contentsOf: detector.endSession())
        return (jumps, states, detector)
    }

    /// Pop → sustained unweight → impact, the V14 takeoff/landing signature.
    private static func v14JumpLoad(t: TimeInterval, takeoff: TimeInterval, landing: TimeInterval) -> Double {
        if t >= takeoff - 0.12, t < takeoff { return 2.4 }
        if t >= takeoff, t < landing { return 0.05 }
        if t >= landing, t < landing + 0.1 { return 3.2 }
        return 1.0
    }

    private static func v14Arc(t: TimeInterval, takeoff: TimeInterval, landing: TimeInterval, apexM: Double) -> Double {
        guard t > takeoff, t < landing else { return 0 }
        let p = (t - takeoff) / (landing - takeoff)
        return apexM * 4 * p * (1 - p)
    }

    private static func testV14CleanJumpPrefersRelativeHeight() throws {
        // Both channels are healthy and agree on the same 2.0 m arc. Per the
        // relative-height upgrade, relative altitude is the primary height
        // source even when absolute is available and healthy — absolute is
        // now an opportunistic fallback / diagnostic value only, never
        // preferred. See V14_RELATIVE_HEIGHT_UPGRADE_PLAN.md §10.
        var s = V14Scenario()
        s.gpsSpeed = 8.0
        s.loadAt = { v14JumpLoad(t: $0, takeoff: 12.0, landing: 13.5) }
        s.relAltAt = { v14Arc(t: $0, takeoff: 12.0, landing: 13.5, apexM: 2.0) }
        s.absAltAt = { t in
            if t > 12.0, t < 13.5 {
                return 100.0 + v14Arc(t: t, takeoff: 12.0, landing: 13.5, apexM: 2.0)
            }
            return 100.0 + (Int(t) % 2 == 0 ? 0.02 : -0.02)
        }

        let run = runV14Scenario(s)
        try require(run.states.contains(.airborne), "v14 should flag the flight as airborne")
        try require(run.jumps.count == 1, "v14 clean jump should emit exactly one jump, got \(run.jumps.count)")
        let jump = run.jumps[0]
        try require(jump.heightSource == "relativeAltitude",
                    "v14 height should prefer the relative channel even with a healthy absolute cross-check, got \(jump.heightSource ?? "nil")")
        try require(abs(jump.height - 2.0) <= 0.5, "v14 relative height should match the arc, got \(jump.height)")
        try require(abs(jump.airtime - 1.4) <= 0.3, "v14 airtime should match the unweight span, got \(jump.airtime)")
        try require(jump.confidence >= 65, "v14 confidence should be reasonably high on a confirmed landing, got \(jump.confidence)")
        try require((jump.detectionConfidence ?? 0) >= 60,
                    "v14 detection confidence (IMU signature only) should be solid, got \(jump.detectionConfidence ?? -1)")
        try require((jump.heightConfidence ?? 0) > 0,
                    "v14 height confidence should be positive for a well-measured relative height")
        try require(!run.detector.isAbsoluteWindowOpen,
                    "v14 must stop the absolute stream after the landing baseline is confirmed")
    }

    private static func testV14FrozenAbsoluteFallsBackToRelative() throws {
        var s = V14Scenario()
        s.gpsSpeed = 8.0
        s.loadAt = { v14JumpLoad(t: $0, takeoff: 12.0, landing: 13.5) }
        s.relAltAt = { v14Arc(t: $0, takeoff: 12.0, landing: 13.5, apexM: 2.0) }
        s.absAltAt = { _ in 100.0 }   // OS-frozen: bit-identical forever

        let run = runV14Scenario(s)
        try require(run.jumps.count == 1, "v14 frozen-absolute jump should still emit, got \(run.jumps.count)")
        let jump = run.jumps[0]
        try require(jump.heightSource == "relativeAltitude",
                    "v14 should fall back to the relative channel, got \(jump.heightSource ?? "nil")")
        try require(abs(jump.height - 2.0) <= 0.5, "v14 relative height should match the arc, got \(jump.height)")
    }

    private static func testV14WaterDipOpensNoJumpAndKeepsBaselineSane() throws {
        var s = V14Scenario()
        s.duration = 32
        s.gpsSpeed = 8.0
        // Splash at t=10.8: brief unweight while the wrist is underwater opens
        // a candidate (V14 no longer gates takeoff on submersion — a real
        // jump can start from a wet wrist), but its ballistic height
        // contradicts the flat relative arc and it is rejected on physics.
        // Real jump at t=18 with a frozen absolute channel: its relative
        // height must be measured against a baseline the −30 m dip could not
        // poison.
        s.loadAt = { t in
            if t >= 10.8, t < 11.3 { return 0.1 }
            return v14JumpLoad(t: t, takeoff: 18.0, landing: 19.5)
        }
        s.relAltAt = { t in
            if t >= 10.4, t < 10.9 { return -30.0 }   // one barometer tick under water
            return v14Arc(t: t, takeoff: 18.0, landing: 19.5, apexM: 2.0)
        }
        s.absAltAt = { _ in 100.0 }

        let run = runV14Scenario(s)
        try require(run.jumps.count == 1,
                    "v14 should reject the submerged splash on physics and keep the real jump, got \(run.jumps.count)")
        let jump = run.jumps[0]
        try require(abs(jump.height - 2.0) <= 0.5,
                    "v14 baseline must survive the −30 m dip (median + spike filter), got height \(jump.height)")
    }

    private static func testV14DetectsWithoutAnyGPS() throws {
        var s = V14Scenario()
        s.gpsSpeed = nil                              // no GPS fix, ever
        s.loadAt = { v14JumpLoad(t: $0, takeoff: 12.0, landing: 13.5) }
        s.relAltAt = { v14Arc(t: $0, takeoff: 12.0, landing: 13.5, apexM: 2.0) }
        s.absAltAt = { t in
            if t > 12.0, t < 13.5 {
                return 100.0 + v14Arc(t: t, takeoff: 12.0, landing: 13.5, apexM: 2.0)
            }
            return 100.0 + (Int(t) % 2 == 0 ? 0.02 : -0.02)
        }

        let run = runV14Scenario(s)
        try require(run.jumps.count == 1, "v14 must detect without GPS, got \(run.jumps.count)")
        let jump = run.jumps[0]
        try require(jump.jumpDistance == 0, "v14 distance must stay empty without GPS, got \(jump.jumpDistance)")
        try require(jump.takeoffSpeed == nil, "v14 takeoff speed must stay nil without GPS")
        try require(jump.height >= 1.0, "v14 height should still be measured without GPS, got \(jump.height)")
    }

    private static func testV14RiseBelowUserSettingIsNotCounted() throws {
        var s = V14Scenario()
        s.gpsSpeed = 8.0
        // 0.7 s hop with a 0.4 m arc and a dead absolute channel: every height
        // source lands under the 1.0 m counted-height setting.
        s.loadAt = { v14JumpLoad(t: $0, takeoff: 12.0, landing: 12.7) }
        s.relAltAt = { v14Arc(t: $0, takeoff: 12.0, landing: 12.7, apexM: 0.4) }
        s.absAltAt = { _ in 100.0 }

        let run = runV14Scenario(s)
        try require(run.jumps.isEmpty,
                    "v14 must not count a rise below the user's setting, got \(run.jumps.count)")
    }
}
