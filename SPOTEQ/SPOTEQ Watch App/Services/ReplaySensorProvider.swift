//
//  ReplaySensorProvider.swift
//  SPOTEQ Watch App
//
//  Streaming KSLG v2 decoder and drift-free replay scheduler. The decoder
//  preserves file order and the original per-record timestamps. The scheduler
//  always targets a fixed ContinuousClock origin, so timer jitter cannot
//  accumulate over a long session.
//

import Foundation

enum ReplayLogError: LocalizedError {
    case unreadable
    case invalidMagic
    case unsupportedVersion(UInt8)
    case truncated(offset: Int)
    case unknownRecord(tag: UInt8, offset: Int)
    case invalidHeader

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The replay log could not be read."
        case .invalidMagic:
            return "This is not a KSLG session log."
        case .unsupportedVersion(let version):
            return "KSLG version \(version) is not supported by on-watch replay."
        case .truncated(let offset):
            return "The replay log is truncated near byte \(offset)."
        case .unknownRecord(let tag, let offset):
            return "Unknown KSLG record \(tag) near byte \(offset)."
        case .invalidHeader:
            return "The KSLG header is invalid."
        }
    }
}

struct ReplayLogHeader: Decodable {
    let session: String?
    let date: String?
    let engineVersion: String?
    let sampleRateHz: Int?
    let t0BootUs: UInt64?
    let wallClockAtT0Ms: Int64?
}

struct ReplayLogStreamCounts {
    var motion = 0
    var rawAcceleration = 0
    var barometer = 0
    var absoluteAltitude = 0
    var gps = 0
    var submersion = 0
    var diagnostic = 0

    var total: Int {
        motion + rawAcceleration + barometer + absoluteAltitude
            + gps + submersion + diagnostic
    }
}

struct ReplayLogSummary {
    let header: ReplayLogHeader
    let durationNs: UInt64
    let counts: ReplayLogStreamCounts
    let outOfOrderRecordCount: Int
    let duplicateTimestampCount: Int
    let maximumGapNs: UInt64
}

struct TimedSensorProviderEvent {
    let sequence: Int
    /// Timestamp stored by the recording, on its original monotonic clock.
    let sourceTimestampNs: UInt64
    /// Session-relative timestamp used for progress and deterministic mapping.
    let timelineTimestampNs: UInt64
    /// Nondecreasing deadline. Out-of-order records remain in file order and
    /// are delivered immediately when their original deadline is already past.
    let scheduledTimestampNs: UInt64
    let event: SensorProviderEvent
}

final class ReplaySessionLog {
    let url: URL
    let data: Data
    let payloadOffset: Int
    let summary: ReplayLogSummary

    private init(url: URL, data: Data, payloadOffset: Int, summary: ReplayLogSummary) {
        self.url = url
        self.data = data
        self.payloadOffset = payloadOffset
        self.summary = summary
    }

    static func load(from url: URL) throws -> ReplaySessionLog {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw ReplayLogError.unreadable
        }
        guard data.count >= 7 else { throw ReplayLogError.truncated(offset: 0) }
        guard data[0] == 0x4b, data[1] == 0x53, data[2] == 0x4c, data[3] == 0x47 else {
            throw ReplayLogError.invalidMagic
        }
        let version = data[4]
        guard version == 2 else { throw ReplayLogError.unsupportedVersion(version) }

        let headerLength = Int(Self.readUInt16(data, 5))
        let payloadOffset = 7 + headerLength
        guard payloadOffset <= data.count else {
            throw ReplayLogError.truncated(offset: 7)
        }
        guard let header = try? JSONDecoder().decode(
            ReplayLogHeader.self,
            from: data.subdata(in: 7..<payloadOffset)
        ) else {
            throw ReplayLogError.invalidHeader
        }

        var cursor = payloadOffset
        var counts = ReplayLogStreamCounts()
        var lastTimestampUs: UInt64?
        var durationUs: UInt64 = 0
        var maximumGapUs: UInt64 = 0
        var outOfOrder = 0
        var duplicates = 0

        while cursor < data.count {
            let info = try recordInfo(data, at: cursor)
            switch info.tag {
            case 3: counts.motion += 1
            case 4: counts.rawAcceleration += 1
            case 5: counts.barometer += 1
            case 6: counts.absoluteAltitude += 1
            case 7: counts.gps += 1
            case 8: counts.submersion += 1
            default: counts.diagnostic += 1
            }

            durationUs = max(durationUs, info.timestampUs)
            if let lastTimestampUs {
                if info.timestampUs < lastTimestampUs {
                    outOfOrder += 1
                } else if info.timestampUs == lastTimestampUs {
                    duplicates += 1
                } else {
                    maximumGapUs = max(maximumGapUs, info.timestampUs - lastTimestampUs)
                }
            }
            lastTimestampUs = info.timestampUs
            cursor += info.length
        }

        let summary = ReplayLogSummary(
            header: header,
            durationNs: durationUs.multipliedReportingOverflow(by: 1_000).partialValue,
            counts: counts,
            outOfOrderRecordCount: outOfOrder,
            duplicateTimestampCount: duplicates,
            maximumGapNs: maximumGapUs.multipliedReportingOverflow(by: 1_000).partialValue
        )
        return ReplaySessionLog(
            url: url,
            data: data,
            payloadOffset: payloadOffset,
            summary: summary
        )
    }

    func makeDecoder() -> ReplayEventDecoder {
        ReplayEventDecoder(log: self)
    }

    fileprivate struct RecordInfo {
        let tag: UInt8
        let timestampUs: UInt64
        let length: Int
    }

    fileprivate static func recordInfo(_ data: Data, at offset: Int) throws -> RecordInfo {
        guard offset < data.count else { throw ReplayLogError.truncated(offset: offset) }
        let tag = data[offset]
        let fixedLength: Int
        var variableLength = 0

        switch tag {
        case 3: fixedLength = 29       // MOTION
        case 4: fixedLength = 15       // RAWACC
        case 5: fixedLength = 17       // BARO
        case 6: fixedLength = 21       // ABSALT
        case 7: fixedLength = 29       // GPS
        case 8: fixedLength = 12       // SUBMERSION
        case 9:                        // EVENT
            fixedLength = 12
            guard offset + fixedLength <= data.count else {
                throw ReplayLogError.truncated(offset: offset)
            }
            variableLength = Int(readUInt16(data, offset + 10))
        case 10:                       // SYNC
            fixedLength = 19
            guard offset + fixedLength <= data.count else {
                throw ReplayLogError.truncated(offset: offset)
            }
            variableLength = Int(readUInt16(data, offset + 17))
        case 11: fixedLength = 16      // STATUS
        case 12:                       // V13_AUDIT
            fixedLength = 13
            guard offset + fixedLength <= data.count else {
                throw ReplayLogError.truncated(offset: offset)
            }
            variableLength = Int(readUInt32(data, offset + 9))
        default:
            throw ReplayLogError.unknownRecord(tag: tag, offset: offset)
        }

        let length = fixedLength + variableLength
        guard length >= fixedLength, offset + length <= data.count else {
            throw ReplayLogError.truncated(offset: offset)
        }
        return RecordInfo(
            tag: tag,
            timestampUs: readUInt64(data, offset + 1),
            length: length
        )
    }

    fileprivate static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    fileprivate static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(readUInt16(data, offset))
            | (UInt32(readUInt16(data, offset + 2)) << 16)
    }

    fileprivate static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(readUInt32(data, offset))
            | (UInt64(readUInt32(data, offset + 4)) << 32)
    }

    fileprivate static func readInt16(_ data: Data, _ offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(data, offset))
    }

    fileprivate static func readInt32(_ data: Data, _ offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(data, offset))
    }
}

/// Stateful, forward-only decoder. It holds only the latest ZOH sensor values;
/// the full decoded session is never materialized in watch memory.
final class ReplayEventDecoder {
    private let log: ReplaySessionLog
    private var offset: Int
    private var sequence = 0
    private var lastScheduledNs: UInt64 = 0
    private var latestBarometer: BarometerSensorReading?
    private var latestAbsolute: AbsoluteAltitudeSensorReading?
    private var latestSubmersion: WaterSubmersionSnapshot = .unknown

    init(log: ReplaySessionLog) {
        self.log = log
        offset = log.payloadOffset
    }

    var isAtEnd: Bool { offset >= log.data.count }

    func next() throws -> TimedSensorProviderEvent? {
        guard offset < log.data.count else { return nil }
        let data = log.data
        let info = try ReplaySessionLog.recordInfo(data, at: offset)
        let timelineNs = info.timestampUs.multipliedReportingOverflow(by: 1_000).partialValue
        let scheduledNs = max(lastScheduledNs, timelineNs)
        lastScheduledNs = scheduledNs
        let sourceUs = (log.summary.header.t0BootUs ?? 0)
            .addingReportingOverflow(info.timestampUs).partialValue
        let sourceNs = sourceUs.multipliedReportingOverflow(by: 1_000).partialValue
        let t = Double(info.timestampUs) / 1_000_000.0
        let event: SensorProviderEvent

        switch info.tag {
        case 3:
            let q = MotionQuaternion(
                w: scaledInt16(data, offset + 21, scale: 10_000) ?? 1,
                x: scaledInt16(data, offset + 23, scale: 10_000) ?? 0,
                y: scaledInt16(data, offset + 25, scale: 10_000) ?? 0,
                z: scaledInt16(data, offset + 27, scale: 10_000) ?? 0
            )
            let gravity = Self.gravityVector(from: q)
            let sample = IMUSample(
                timestamp: Date(timeIntervalSince1970: t),
                accelerationX: scaledInt16(data, offset + 9, scale: 1_000) ?? 0,
                accelerationY: scaledInt16(data, offset + 11, scale: 1_000) ?? 0,
                accelerationZ: scaledInt16(data, offset + 13, scale: 1_000) ?? 0,
                rotationX: scaledInt16(data, offset + 15, scale: 1_000) ?? 0,
                rotationY: scaledInt16(data, offset + 17, scale: 1_000) ?? 0,
                rotationZ: scaledInt16(data, offset + 19, scale: 1_000) ?? 0,
                gravity: gravity,
                pressure: latestBarometer?.pressureHPa,
                motionTimestamp: t,
                relativeAltitude: latestBarometer?.relativeAltitudeM,
                barometerTimestamp: latestBarometer?.sensorT,
                absoluteAltitude: latestAbsolute?.altitudeM,
                absoluteAltitudeAccuracy: latestAbsolute?.accuracyM,
                absoluteAltitudePrecision: latestAbsolute?.precisionM,
                absoluteAltitudeTimestamp: latestAbsolute?.sensorT,
                attitudeQuaternion: q,
                submerged: latestSubmersion.submerged,
                waterDepth: latestSubmersion.waterDepthM,
                waterPressure: latestSubmersion.waterPressureHPa
            )
            event = .motion(sample)

        case 4:
            let x = scaledInt16(data, offset + 9, scale: 1_000) ?? 0
            let y = scaledInt16(data, offset + 11, scale: 1_000) ?? 0
            let z = scaledInt16(data, offset + 13, scale: 1_000) ?? 0
            event = .diagnostic(
                timestamp: t,
                message: String(format: "rawAccel x=%.3f y=%.3f z=%.3f", x, y, z)
            )

        case 5:
            let reading = BarometerSensorReading(
                sensorT: t,
                relativeAltitudeM: scaledInt32(data, offset + 9, scale: 1_000) ?? 0,
                pressureHPa: scaledInt32(data, offset + 13, scale: 1_000) ?? 0
            )
            latestBarometer = reading
            event = .barometer(reading)

        case 6:
            let reading = AbsoluteAltitudeSensorReading(
                sensorT: t,
                receivedT: t,
                altitudeM: scaledInt32(data, offset + 9, scale: 1_000) ?? 0,
                accuracyM: scaledInt32(data, offset + 13, scale: 1_000),
                precisionM: scaledInt32(data, offset + 17, scale: 1_000)
            )
            latestAbsolute = reading
            event = .absoluteAltitude(reading)

        case 7:
            let speedRaw = ReplaySessionLog.readUInt16(data, offset + 17)
            let courseRaw = ReplaySessionLog.readUInt16(data, offset + 19)
            let hAccRaw = ReplaySessionLog.readUInt16(data, offset + 21)
            let vAccRaw = ReplaySessionLog.readUInt16(data, offset + 23)
            event = .gps(GPSPoint(
                timestamp: Date(timeIntervalSince1970: t),
                latitude: Double(ReplaySessionLog.readInt32(data, offset + 9)) / 10_000_000,
                longitude: Double(ReplaySessionLog.readInt32(data, offset + 13)) / 10_000_000,
                altitude: scaledInt32(data, offset + 25, scale: 1_000) ?? 0,
                speed: speedRaw == UInt16.max ? 0 : Double(speedRaw) / 100,
                course: courseRaw == UInt16.max ? -1 : Double(courseRaw) / 10,
                horizontalAccuracy: hAccRaw == UInt16.max ? -1 : Double(hAccRaw) / 10,
                verticalAccuracy: vAccRaw == UInt16.max ? -1 : Double(vAccRaw) / 10
            ))

        case 8:
            let kind = data[offset + 9]
            let scale = kind == 0 ? 1.0 : 100.0
            let value = scaledInt16(data, offset + 10, scale: scale)
            switch kind {
            case 0:
                latestSubmersion.submerged = value.map { $0 >= 0.5 }
                if latestSubmersion.submerged == false {
                    latestSubmersion.waterDepthM = nil
                    latestSubmersion.waterPressureHPa = nil
                }
            case 1:
                latestSubmersion.waterDepthM = value
            default:
                break
            }
            event = .submersion(SubmersionSensorReading(
                sensorT: t,
                snapshot: latestSubmersion
            ))

        case 9:
            let state = data[offset + 9]
            let length = Int(ReplaySessionLog.readUInt16(data, offset + 10))
            let message = Self.string(data, range: (offset + 12)..<(offset + 12 + length))
            event = .diagnostic(timestamp: t, message: "event state=\(state) \(message)")

        case 10:
            let length = Int(ReplaySessionLog.readUInt16(data, offset + 17))
            let label = Self.string(data, range: (offset + 19)..<(offset + 19 + length))
            event = .diagnostic(timestamp: t, message: "sync \(label)")

        case 11:
            let thermal = data[offset + 9]
            let lowPower = data[offset + 10] != 0
            event = .diagnostic(
                timestamp: t,
                message: "status thermal=\(thermal) lowPower=\(lowPower)"
            )

        case 12:
            event = .diagnostic(timestamp: t, message: "v13Audit")

        default:
            throw ReplayLogError.unknownRecord(tag: info.tag, offset: offset)
        }

        offset += info.length
        let result = TimedSensorProviderEvent(
            sequence: sequence,
            sourceTimestampNs: sourceNs,
            timelineTimestampNs: timelineNs,
            scheduledTimestampNs: scheduledNs,
            event: event
        )
        sequence += 1
        return result
    }

    private func scaledInt16(_ data: Data, _ offset: Int, scale: Double) -> Double? {
        let value = ReplaySessionLog.readInt16(data, offset)
        guard value != Int16.min else { return nil }
        return Double(value) / scale
    }

    private func scaledInt32(_ data: Data, _ offset: Int, scale: Double) -> Double? {
        let value = ReplaySessionLog.readInt32(data, offset)
        guard value != Int32.min else { return nil }
        return Double(value) / scale
    }

    private static func string(_ data: Data, range: Range<Int>) -> String {
        String(data: data.subdata(in: range), encoding: .utf8) ?? ""
    }

    /// CMQuaternion describes device attitude. Applying its inverse rotation
    /// to reference-frame down (0, 0, -1) reconstructs Core Motion's gravity
    /// vector without inventing or resampling a sensor channel.
    private static func gravityVector(from quaternion: MotionQuaternion) -> Vector3 {
        let magnitude = sqrt(
            quaternion.w * quaternion.w
                + quaternion.x * quaternion.x
                + quaternion.y * quaternion.y
                + quaternion.z * quaternion.z
        )
        guard magnitude > 0.0001 else { return Vector3(x: 0, y: 0, z: -1) }
        let w = quaternion.w / magnitude
        let x = quaternion.x / magnitude
        let y = quaternion.y / magnitude
        let z = quaternion.z / magnitude
        return Vector3(
            x: 2 * (w * y - x * z),
            y: -2 * (w * x + y * z),
            z: 2 * (x * x + y * y) - 1
        )
    }
}

enum ReplayProviderState: Equatable {
    case stopped
    case playing
    case paused
    case finished
    case failed(String)
}

final class ReplaySensorProvider: SensorProvider {
    var onEvent: ((SensorProviderEvent) -> Void)?
    var onTimedEvent: ((TimedSensorProviderEvent) -> Void)?
    var onStateChange: ((ReplayProviderState) -> Void)?

    private let log: ReplaySessionLog
    private let lock = NSLock()
    private var decoder: ReplayEventDecoder
    private var pendingEvent: TimedSensorProviderEvent?
    private var stateStorage: ReplayProviderState = .stopped
    private var statisticsStorage = SensorProviderStatistics()
    private var playheadTimelineNs: UInt64 = 0
    private var playheadScheduledNs: UInt64 = 0
    private var speedStorage = 1.0
    private var generation = 0
    private var task: Task<Void, Never>?

    init(log: ReplaySessionLog) {
        self.log = log
        decoder = log.makeDecoder()
    }

    var state: ReplayProviderState {
        lock.lock()
        defer { lock.unlock() }
        return stateStorage
    }

    var speed: Double {
        lock.lock()
        defer { lock.unlock() }
        return speedStorage
    }

    var currentTime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(playheadTimelineNs) / 1_000_000_000
    }

    var currentTimelineNs: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return playheadTimelineNs
    }

    var statistics: SensorProviderStatistics {
        lock.lock()
        defer { lock.unlock() }
        return statisticsStorage
    }

    func start() {
        lock.lock()
        guard stateStorage != .playing else {
            lock.unlock()
            return
        }
        generation += 1
        let runGeneration = generation
        stateStorage = .playing
        let anchorScheduledNs = playheadScheduledNs
        let runSpeed = speedStorage
        let previousTask = task
        let clock = ContinuousClock()
        let anchorInstant = clock.now
        let newTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.run(
                generation: runGeneration,
                speed: runSpeed,
                anchorScheduledNs: anchorScheduledNs,
                anchorInstant: anchorInstant,
                clock: clock
            )
        }
        task = newTask
        lock.unlock()
        previousTask?.cancel()
        onStateChange?(.playing)
    }

    func pause() {
        lock.lock()
        guard stateStorage == .playing else {
            lock.unlock()
            return
        }
        generation += 1
        stateStorage = .paused
        let oldTask = task
        task = nil
        lock.unlock()
        oldTask?.cancel()
        onStateChange?(.paused)
    }

    func stop() {
        lock.lock()
        generation += 1
        let oldTask = task
        task = nil
        decoder = log.makeDecoder()
        pendingEvent = nil
        playheadTimelineNs = 0
        playheadScheduledNs = 0
        statisticsStorage = SensorProviderStatistics()
        stateStorage = .stopped
        lock.unlock()
        oldTask?.cancel()
        onStateChange?(.stopped)
    }

    func restart() {
        stop()
        start()
    }

    func setSpeed(_ newSpeed: Double) {
        let normalized = min(10, max(1, newSpeed))
        let wasPlaying = state == .playing
        if wasPlaying { pause() }
        lock.lock()
        speedStorage = normalized
        lock.unlock()
        if wasPlaying { start() }
    }

    /// Installs a decoder already advanced by the controller's deterministic
    /// state rebuild. Playback resumes from the first event after `playhead`.
    func installPosition(
        decoder: ReplayEventDecoder,
        pendingEvent: TimedSensorProviderEvent?,
        playheadTimelineNs: UInt64,
        playheadScheduledNs: UInt64,
        rebuiltStatistics: SensorProviderStatistics
    ) {
        pause()
        lock.lock()
        generation += 1
        self.decoder = decoder
        self.pendingEvent = pendingEvent
        self.playheadTimelineNs = playheadTimelineNs
        self.playheadScheduledNs = playheadScheduledNs
        statisticsStorage = rebuiltStatistics
        stateStorage = .paused
        lock.unlock()
        onStateChange?(.paused)
    }

    private func run(
        generation runGeneration: Int,
        speed runSpeed: Double,
        anchorScheduledNs: UInt64,
        anchorInstant: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async {
        while !Task.isCancelled {
            let timedEvent: TimedSensorProviderEvent
            do {
                guard let next = try nextPendingEvent(generation: runGeneration) else {
                    finish(generation: runGeneration)
                    return
                }
                timedEvent = next
            } catch {
                fail(error, generation: runGeneration)
                return
            }

            let sourceDelta = timedEvent.scheduledTimestampNs >= anchorScheduledNs
                ? timedEvent.scheduledTimestampNs - anchorScheduledNs
                : 0
            let scaledDelta = Double(sourceDelta) / runSpeed
            let delayNs = Int64(min(scaledDelta, Double(Int64.max)).rounded())
            let deadline = anchorInstant.advanced(by: .nanoseconds(delayNs))

            do {
                try await clock.sleep(until: deadline, tolerance: .microseconds(100))
            } catch {
                return
            }
            guard claim(timedEvent, generation: runGeneration, deadline: deadline, clock: clock) else {
                return
            }

            onTimedEvent?(timedEvent)
            onEvent?(timedEvent.event)
        }
    }

    private func nextPendingEvent(generation runGeneration: Int) throws -> TimedSensorProviderEvent? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == runGeneration, stateStorage == .playing else { return nil }
        if let pendingEvent { return pendingEvent }
        let next = try decoder.next()
        pendingEvent = next
        return next
    }

    private func claim(
        _ timedEvent: TimedSensorProviderEvent,
        generation runGeneration: Int,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == runGeneration,
              stateStorage == .playing,
              pendingEvent?.sequence == timedEvent.sequence else { return false }

        pendingEvent = nil
        playheadTimelineNs = timedEvent.timelineTimestampNs
        playheadScheduledNs = timedEvent.scheduledTimestampNs
        statisticsStorage.deliveredEvents += 1
        switch timedEvent.event {
        case .motion: statisticsStorage.motionSamples += 1
        case .barometer: statisticsStorage.barometerSamples += 1
        case .absoluteAltitude: statisticsStorage.absoluteAltitudeSamples += 1
        case .gps: statisticsStorage.gpsSamples += 1
        case .submersion: statisticsStorage.submersionSamples += 1
        default: break
        }

        let lateThreshold = deadline.advanced(by: .milliseconds(5))
        let now = clock.now
        if now > lateThreshold {
            let lateness = deadline.duration(to: now)
            let components = lateness.components
            let milliseconds = Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
            statisticsStorage.lateEvents += 1
            statisticsStorage.maximumLatenessMs = max(
                statisticsStorage.maximumLatenessMs,
                milliseconds
            )
        }
        return true
    }

    private func finish(generation runGeneration: Int) {
        lock.lock()
        guard generation == runGeneration, stateStorage == .playing else {
            lock.unlock()
            return
        }
        stateStorage = .finished
        task = nil
        lock.unlock()
        onStateChange?(.finished)
    }

    private func fail(_ error: Error, generation runGeneration: Int) {
        let message = error.localizedDescription
        lock.lock()
        guard generation == runGeneration else {
            lock.unlock()
            return
        }
        stateStorage = .failed(message)
        task = nil
        lock.unlock()
        onStateChange?(.failed(message))
    }
}
