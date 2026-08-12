//
//  MotionManager.swift
//  iSurf-Watch
//
//  Manages IMU sensor data (accelerometer + gyroscope), preferring
//  CMBatchedSensorManager high-rate device motion when available and falling
//  back to CMMotionManager at 50 Hz.
//  and barometric pressure from CMAltimeter.
//

import Foundation
import CoreMotion
import Combine

struct MotionPipelineHealth {
    let timestamp: TimeInterval
    let windowSec: Double
    let absoluteIntervalSec: Double
    let imuSource: String
    let imuSourceHz: Double
    let imuProcessedHz: Double
    let relativeAltitudeHz: Double
    let absoluteAltitudeSourceHz: Double
    let absoluteAltitudeProcessedHz: Double
    let waterUpdateHz: Double
    let imuGapSec: Double?
    let relativeAltitudeGapSec: Double?
    let absoluteAltitudeGapSec: Double?
    let absoluteQueueLatencyAverageMs: Double
    let absoluteQueueLatencyMaximumMs: Double

    var warnings: [String] {
        var result: [String] = []
        if let imuGapSec, imuGapSec >= 2 { result.append("imuCallbackGap") }
        if let absoluteAltitudeGapSec,
           absoluteAltitudeGapSec >= max(3, absoluteIntervalSec * 4) {
            result.append("absoluteCallbackGap")
        }
        if absoluteQueueLatencyMaximumMs >= 250 { result.append("absoluteQueueDelay") }
        if imuSourceHz >= 10, imuProcessedHz < imuSourceHz * 0.5 {
            result.append("imuProcessingBacklog")
        }
        return result
    }
}

private final class MotionPipelineMonitor {
    private let lock = NSLock()
    private var windowStartT = ProcessInfo.processInfo.systemUptime
    private var sessionStartT = ProcessInfo.processInfo.systemUptime
    private var imuSourceCount = 0
    private var imuProcessedCount = 0
    private var relativeCount = 0
    private var absoluteSourceCount = 0
    private var absoluteProcessedCount = 0
    private var waterCount = 0
    private var absoluteLatencyTotalMs = 0.0
    private var absoluteLatencyMaximumMs = 0.0
    private var absoluteLatencyCount = 0
    private var lastIMUT: TimeInterval?
    private var lastRelativeT: TimeInterval?
    private var lastAbsoluteT: TimeInterval?
    private var absoluteIntervalSec = 0.5
    private var imuSource = "not-started"
    // False while the absolute stream is deliberately off (.onDemand outside a
    // jump window) so a silent stream is not reported as a callback gap.
    private var absoluteStreamExpected = true

    func reset(at now: TimeInterval, absoluteIntervalSec: Double) {
        lock.lock()
        windowStartT = now
        sessionStartT = now
        imuSourceCount = 0
        imuProcessedCount = 0
        relativeCount = 0
        absoluteSourceCount = 0
        absoluteProcessedCount = 0
        waterCount = 0
        absoluteLatencyTotalMs = 0
        absoluteLatencyMaximumMs = 0
        absoluteLatencyCount = 0
        lastIMUT = nil
        lastRelativeT = nil
        lastAbsoluteT = nil
        self.absoluteIntervalSec = absoluteIntervalSec
        imuSource = "not-started"
        absoluteStreamExpected = true
        lock.unlock()
    }

    func noteAbsoluteStreamExpected(_ expected: Bool, at t: TimeInterval) {
        lock.lock()
        if expected && !absoluteStreamExpected {
            // Fresh gap baseline when an on-demand window opens, so the idle
            // period before the window doesn't count as a callback gap.
            lastAbsoluteT = t
        }
        absoluteStreamExpected = expected
        lock.unlock()
    }

    func setIMUSource(_ source: String) {
        lock.lock()
        imuSource = source
        lock.unlock()
    }

    func noteIMUSource(count: Int, at t: TimeInterval) {
        lock.lock()
        imuSourceCount += max(0, count)
        lastIMUT = t
        lock.unlock()
    }

    func noteIMUProcessed() {
        lock.lock()
        imuProcessedCount += 1
        lock.unlock()
    }

    func noteRelative(at t: TimeInterval) {
        lock.lock()
        relativeCount += 1
        lastRelativeT = t
        lock.unlock()
    }

    func noteAbsoluteSource(at t: TimeInterval) {
        lock.lock()
        absoluteSourceCount += 1
        lastAbsoluteT = t
        lock.unlock()
    }

    func noteAbsoluteProcessed(queueLatencySec: Double) {
        let latencyMs = max(0, queueLatencySec) * 1_000
        lock.lock()
        absoluteProcessedCount += 1
        absoluteLatencyCount += 1
        absoluteLatencyTotalMs += latencyMs
        absoluteLatencyMaximumMs = max(absoluteLatencyMaximumMs, latencyMs)
        lock.unlock()
    }

    func noteWater() {
        lock.lock()
        waterCount += 1
        lock.unlock()
    }

    func snapshot(at now: TimeInterval) -> MotionPipelineHealth {
        lock.lock()
        let elapsed = max(0.001, now - windowStartT)
        let imuGapSec = max(0, now - (lastIMUT ?? sessionStartT))
        let relativeAltitudeGapSec = max(0, now - (lastRelativeT ?? sessionStartT))
        let absoluteAltitudeGapSec: Double? = absoluteStreamExpected
            ? max(0, now - (lastAbsoluteT ?? sessionStartT))
            : nil
        let result = MotionPipelineHealth(
            timestamp: now,
            windowSec: elapsed,
            absoluteIntervalSec: absoluteIntervalSec,
            imuSource: imuSource,
            imuSourceHz: Double(imuSourceCount) / elapsed,
            imuProcessedHz: Double(imuProcessedCount) / elapsed,
            relativeAltitudeHz: Double(relativeCount) / elapsed,
            absoluteAltitudeSourceHz: Double(absoluteSourceCount) / elapsed,
            absoluteAltitudeProcessedHz: Double(absoluteProcessedCount) / elapsed,
            waterUpdateHz: Double(waterCount) / elapsed,
            imuGapSec: imuGapSec,
            relativeAltitudeGapSec: relativeAltitudeGapSec,
            absoluteAltitudeGapSec: absoluteAltitudeGapSec,
            absoluteQueueLatencyAverageMs: absoluteLatencyCount == 0
                ? 0
                : absoluteLatencyTotalMs / Double(absoluteLatencyCount),
            absoluteQueueLatencyMaximumMs: absoluteLatencyMaximumMs
        )
        windowStartT = now
        imuSourceCount = 0
        imuProcessedCount = 0
        relativeCount = 0
        absoluteSourceCount = 0
        absoluteProcessedCount = 0
        waterCount = 0
        absoluteLatencyTotalMs = 0
        absoluteLatencyMaximumMs = 0
        absoluteLatencyCount = 0
        lock.unlock()
        return result
    }
}

class MotionManager: ObservableObject {
    private let motionManager = CMMotionManager()
    // Keep relative and absolute altitude on separate CMAltimeter instances and
    // callback queues. Besides isolating the two Core Motion subscriptions, this
    // lets the absolute stream be recreated without disturbing the raw pressure
    // stream that the watchdog uses as an independent liveness signal.
    private let relativeAltimeter = CMAltimeter()
    private var absoluteAltimeter: CMAltimeter?
    private let queue = OperationQueue()
    private let motionProcessingQueue = DispatchQueue(
        label: "com.kiters.motion.processing",
        qos: .userInitiated
    )
    private let relativeAltimeterQueue = OperationQueue()
    private let absoluteAltimeterQueue = OperationQueue()
    private let altimeterControlQueue = DispatchQueue(
        label: "com.kiters.altimeter.control",
        qos: .userInitiated
    )
    private var batchedSensorManager: CMBatchedSensorManager?
    private var usingBatchedDeviceMotion = false
    private var didFallbackFromBatchedError = false

    /// How the absolute-altitude stream is acquired for the session.
    /// `.continuous` starts it at session start and keeps the freeze watchdog
    /// (including V16's diagnostic stream). `.onDemand` keeps it OFF until the jump engine
    /// opens a window via `beginAbsoluteAltitudeWindow` and stops it again on
    /// `endAbsoluteAltitudeWindow` (V14). `.continuousNoWatchdog` runs the
    /// stream start-to-stop with NO watchdog restarts (V15, spec P4: every
    /// observed freeze was a competing consumer, and restarts only added
    /// degenerate warm-up records — the fix is the single-consumer contract,
    /// not supervision). Set by SessionManager before the session starts.
    enum AbsoluteAcquisitionMode {
        case continuous
        case continuousNoWatchdog
        case onDemand
    }

    // All fields below are confined to altimeterControlQueue.
    private var altitudeSessionActive = false
    private var absoluteAcquisitionMode: AbsoluteAcquisitionMode = .continuous
    private var absoluteStreamGeneration = 0
    private var absoluteStreamStartedT: TimeInterval?
    private var lastAbsoluteReceivedT: TimeInterval?
    private var lastAbsoluteChangedT: TimeInterval?
    private var lastAbsoluteHealthValueM: Double?
    private var latestRelativeReceivedT: TimeInterval?
    private var latestRelativeHealthValueM: Double?
    private var relativeValueAtAbsoluteChangeM: Double?
    private var absoluteRestartAttempts = 0
    private var didLogRestartExhaustion = false
    private var altimeterWatchdog: DispatchSourceTimer?
    private var relativeTimestampNormalizer = AltimeterTimestampNormalizer()
    private var absoluteTimestampNormalizer = AltimeterTimestampNormalizer()
    private var absoluteProcessingIntervalSec = 0.5
    private var lastAbsoluteProcessedReceivedT: TimeInterval?

    private let pipelineMonitor = MotionPipelineMonitor()
    private let pipelineHealthQueue = DispatchQueue(label: "com.kiters.motion.health", qos: .utility)
    private var pipelineHealthTimer: DispatchSourceTimer?

    private static let absoluteValueChangeEpsilonM = 0.01
    private static let absoluteFreezeGraceSec = 10.0
    private static let absoluteCallbackTimeoutSec = 8.0
    private static let relativeFreshnessSec = 4.0
    private static let relativeMovementForRestartM = 0.75
    private static let maxAbsoluteRestartAttempts = 3
    
    @Published var isTracking = false
    @Published var currentAcceleration: CMAcceleration?
    @Published var currentRotation: CMRotationRate?
    
    var isDeviceMotionAvailable: Bool {
        motionManager.isDeviceMotionAvailable || CMBatchedSensorManager.isDeviceMotionSupported
    }
    var isBarometerAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }
    
    // Fallback IMU data (50 Hz). CMBatchedSensorManager reports its own rate,
    // typically 200 Hz on supported Apple Watch hardware.
    private let sampleRate = 50.0 // Hz
    
    // Sample buffer for batch processing
    private var sampleBuffer: [IMUSample] = []
    private let bufferSize = 250 // Send every 250 samples (~5 seconds at 50Hz)
    
    // Barometer state — updated by CMAltimeter on its own queue and ZOH-held
    // onto the 50Hz IMU stream. watchOS does not expose a barometer interval.
    private let baroLock = NSLock()
    private var _currentPressure: Double? = nil
    private var _currentRelativeAltitude: Double? = nil
    private var _currentBarometerTimestamp: TimeInterval? = nil
    private var _currentAbsoluteAltitude: Double? = nil
    private var _currentAbsoluteAltitudeAccuracy: Double? = nil
    private var _currentAbsoluteAltitudePrecision: Double? = nil
    private var _currentAbsoluteAltitudeTimestamp: TimeInterval? = nil
    
    private var currentPressure: Double? {
        get { baroLock.lock(); defer { baroLock.unlock() }; return _currentPressure }
        set { baroLock.lock(); defer { baroLock.unlock() }; _currentPressure = newValue }
    }

    private var currentRelativeAltitude: Double? {
        get { baroLock.lock(); defer { baroLock.unlock() }; return _currentRelativeAltitude }
        set { baroLock.lock(); defer { baroLock.unlock() }; _currentRelativeAltitude = newValue }
    }

    private var currentBarometerTimestamp: TimeInterval? {
        get { baroLock.lock(); defer { baroLock.unlock() }; return _currentBarometerTimestamp }
        set { baroLock.lock(); defer { baroLock.unlock() }; _currentBarometerTimestamp = newValue }
    }

    private var currentAbsoluteAltitudeSnapshot: (alt: Double?, accuracy: Double?, precision: Double?, timestamp: TimeInterval?) {
        get {
            baroLock.lock()
            defer { baroLock.unlock() }
            return (
                _currentAbsoluteAltitude,
                _currentAbsoluteAltitudeAccuracy,
                _currentAbsoluteAltitudePrecision,
                _currentAbsoluteAltitudeTimestamp
            )
        }
        set {
            baroLock.lock()
            _currentAbsoluteAltitude = newValue.alt
            _currentAbsoluteAltitudeAccuracy = newValue.accuracy
            _currentAbsoluteAltitudePrecision = newValue.precision
            _currentAbsoluteAltitudeTimestamp = newValue.timestamp
            baroLock.unlock()
        }
    }

    // Water submersion state is updated by WaterSubmersionManager and ZOH-held
    // onto every IMU sample.
    private let submersionLock = NSLock()
    private var _currentSubmersion: WaterSubmersionSnapshot = .unknown

    private var currentSubmersion: WaterSubmersionSnapshot {
        get { submersionLock.lock(); defer { submersionLock.unlock() }; return _currentSubmersion }
        set { submersionLock.lock(); defer { submersionLock.unlock() }; _currentSubmersion = newValue }
    }

    // CoreMotion timestamps are seconds since boot. Keep one wall/boot bridge so
    // every stream's Date fallback maps back to the same monotonic clock.
    private let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
    
    // Callbacks
    var onIMUSample: ((IMUSample) -> Void)?
    var onIMUBatch: (([IMUSample]) -> Void)?
    var onAbsoluteAltitude: ((_ sensorT: TimeInterval,
                              _ receivedT: TimeInterval,
                              _ altitudeM: Double,
                              _ accuracyM: Double?,
                              _ precisionM: Double?) -> Void)?
    var onAbsoluteAltitudeStreamRestart: ((_ reason: String) -> Void)?
    var onIMUStreamRecovery: ((_ reason: String) -> Void)?
    var onPipelineHealth: ((MotionPipelineHealth) -> Void)?

    /// CMLogItem.timestamp has appeared in two clock domains on watchOS builds:
    /// seconds-since-boot and seconds-since-2001. Anchor an unfamiliar domain to
    /// receipt uptime once, then preserve the sensor's deltas on a monotonic axis.
    private struct AltimeterTimestampNormalizer {
        private var baseSensorT: TimeInterval?
        private var baseReceivedT: TimeInterval?

        mutating func reset() {
            baseSensorT = nil
            baseReceivedT = nil
        }

        mutating func normalize(sensorT: TimeInterval,
                                receivedT: TimeInterval) -> TimeInterval {
            guard receivedT.isFinite else { return sensorT }
            guard sensorT.isFinite else { return receivedT }
            if abs(sensorT - receivedT) <= 60 {
                return sensorT
            }

            if baseSensorT == nil || baseReceivedT == nil {
                baseSensorT = sensorT
                baseReceivedT = receivedT
            }

            guard let baseSensorT, let baseReceivedT else { return receivedT }
            let normalized = baseReceivedT + (sensorT - baseSensorT)
            // Re-anchor if Core Motion changed its timestamp epoch mid-stream.
            if !normalized.isFinite || abs(normalized - receivedT) > 10 {
                self.baseSensorT = sensorT
                self.baseReceivedT = receivedT
                return receivedT
            }
            return normalized
        }
    }
    
    init() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        relativeAltimeterQueue.maxConcurrentOperationCount = 1
        relativeAltimeterQueue.qualityOfService = .userInitiated
        absoluteAltimeterQueue.maxConcurrentOperationCount = 1
        absoluteAltimeterQueue.qualityOfService = .userInitiated
    }
    
    /// `absoluteProcessingIntervalOverrideSec`: bypasses the user's V13
    /// throttle setting entirely (spec V15-FIX §3 F5). V15 is calibrated for
    /// the barometer's native ~3 Hz cadence — the shared V13 setting
    /// defaults to 0.5 s (2 Hz) and, measured in the field, effectively
    /// throttled V15's abs stream to a fixed ~1 Hz, leaving only 3–4 arc
    /// points per jump (borderline against `minArcPoints=3`) even when the
    /// channel was otherwise healthy. Pass 0 for "every callback, full rate".
    func startTracking(preferBatched: Bool = true, absoluteProcessingIntervalOverrideSec: Double? = nil) {
        guard isDeviceMotionAvailable else {
            print("❌ Device motion not available")
            return
        }

        guard !isTracking else { return }

        didFallbackFromBatchedError = false
        let absoluteInterval = absoluteProcessingIntervalOverrideSec ?? V13Settings.normalizedAbsoluteAltitudeSampleInterval(
            UserDefaults.standard.object(forKey: V13Settings.absoluteAltitudeSampleIntervalSec) == nil
                ? V13Config().absoluteAltitudeSampleIntervalSec
                : UserDefaults.standard.double(forKey: V13Settings.absoluteAltitudeSampleIntervalSec)
        )
        pipelineMonitor.reset(
            at: ProcessInfo.processInfo.systemUptime,
            absoluteIntervalSec: absoluteInterval
        )
        startBarometer(absoluteProcessingIntervalSec: absoluteInterval)

        isTracking = true
        motionProcessingQueue.sync {
            sampleBuffer.removeAll(keepingCapacity: true)
            let startedBatched = preferBatched && startBatchedDeviceMotionIfAvailable()
            if !startedBatched {
                startFallbackDeviceMotion()
            }
        }

        startPipelineHealthTimer()
        let source = usingBatchedDeviceMotion
            ? "CMBatchedSensorManager \(batchedSensorManager?.deviceMotionDataFrequency ?? 0)Hz"
            : "CMMotionManager \(Int(sampleRate))Hz"
        print("Motion tracking started via \(source) (baro: \(isBarometerAvailable ? "ON" : "OFF"))")
    }
    
    func stopTracking() {
        isTracking = false
        stopPipelineHealthTimer()
        motionProcessingQueue.sync {
            stopBatchedDeviceMotion()
            motionManager.stopDeviceMotionUpdates()
            flushSampleBuffer()
        }
        stopBarometer()
        
        currentPressure = nil
        currentRelativeAltitude = nil
        currentBarometerTimestamp = nil
        currentAbsoluteAltitudeSnapshot = (nil, nil, nil, nil)
        currentSubmersion = .unknown
        print("Motion tracking stopped")
    }
    
    func pauseTracking() {
        isTracking = false
        stopPipelineHealthTimer()
        motionProcessingQueue.sync {
            stopBatchedDeviceMotion()
            motionManager.stopDeviceMotionUpdates()
            flushSampleBuffer()
        }
        stopBarometer()
        currentAbsoluteAltitudeSnapshot = (nil, nil, nil, nil)
        print("Motion tracking paused")
    }
    
    func resumeTracking(preferBatched: Bool = true) {
        startTracking(preferBatched: preferBatched)
        print("Motion tracking resumed")
    }

    func updateSubmersion(_ snapshot: WaterSubmersionSnapshot) {
        currentSubmersion = snapshot
        pipelineMonitor.noteWater()
    }

    func upgradeToBatchedIfAvailable() {
        motionProcessingQueue.async { [weak self] in
            guard let self,
                  self.isTracking,
                  !self.usingBatchedDeviceMotion,
                  CMBatchedSensorManager.isDeviceMotionSupported else { return }

            self.motionManager.stopDeviceMotionUpdates()
            if self.startBatchedDeviceMotionIfAvailable() {
                print("Motion tracking upgraded to CMBatchedSensorManager \(self.batchedSensorManager?.deviceMotionDataFrequency ?? 0)Hz")
            } else {
                self.startFallbackDeviceMotion()
            }
        }
    }

    private func startBatchedDeviceMotionIfAvailable() -> Bool {
        guard CMBatchedSensorManager.isDeviceMotionSupported else { return false }

        let status = CMBatchedSensorManager.authorizationStatus
        guard status != .denied, status != .restricted else {
            print("Batched device motion unavailable: authorization \(status.rawValue)")
            return false
        }

        let manager = CMBatchedSensorManager()
        batchedSensorManager = manager
        usingBatchedDeviceMotion = true

        manager.startDeviceMotionUpdates { [weak self] motions, error in
            guard let self = self else { return }
            if let error {
                self.requestBatchedMotionFallback(
                    reason: "error: \(error.localizedDescription)"
                )
                return
            }
            guard let motions, !motions.isEmpty else { return }
            let receivedT = ProcessInfo.processInfo.systemUptime
            self.pipelineMonitor.noteIMUSource(count: motions.count, at: receivedT)
            self.motionProcessingQueue.async { [weak self] in
                guard let self else { return }
                for motion in motions {
                    self.processMotionData(motion)
                }
            }
        }

        pipelineMonitor.setIMUSource("CMBatchedSensorManager")

        return true
    }

    private func requestBatchedMotionFallback(reason: String) {
        motionProcessingQueue.async { [weak self] in
            guard let self,
                  self.isTracking,
                  self.usingBatchedDeviceMotion,
                  !self.didFallbackFromBatchedError else { return }

            self.didFallbackFromBatchedError = true
            self.stopBatchedDeviceMotion()
            self.startFallbackDeviceMotion()
            let message = "CMBatchedSensorManager -> CMMotionManager; \(reason)"
            print("Motion tracking recovery: \(message)")
            self.onIMUStreamRecovery?(message)
        }
    }

    private func stopBatchedDeviceMotion() {
        batchedSensorManager?.stopDeviceMotionUpdates()
        batchedSensorManager = nil
        usingBatchedDeviceMotion = false
    }

    private func startFallbackDeviceMotion() {
        guard motionManager.isDeviceMotionAvailable else {
            print("Fallback device motion not available")
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / sampleRate
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self = self, let motion = motion else {
                if let error = error {
                    print("Motion error: \(error.localizedDescription)")
                }
                return
            }

            let receivedT = ProcessInfo.processInfo.systemUptime
            self.pipelineMonitor.noteIMUSource(count: 1, at: receivedT)
            self.motionProcessingQueue.async { [weak self] in
                self?.processMotionData(motion)
            }
        }
        usingBatchedDeviceMotion = false
        pipelineMonitor.setIMUSource("CMMotionManager")
    }

    private func startBarometer(absoluteProcessingIntervalSec: Double) {
        altimeterControlQueue.sync {
            altitudeSessionActive = true
            self.absoluteProcessingIntervalSec = absoluteProcessingIntervalSec
            lastAbsoluteProcessedReceivedT = nil
            relativeTimestampNormalizer.reset()
            absoluteTimestampNormalizer.reset()
            resetAltitudeHealthLocked()

            if CMAltimeter.isRelativeAltitudeAvailable() {
                startRelativeAltitudeLocked()
            } else {
                print("Relative altitude not available on this device")
            }

            switch absoluteAcquisitionMode {
            case .continuous:
                startAbsoluteAltitudeLocked(reason: "sessionStart")
                startAltimeterWatchdogLocked()
                SessionLogger.shared.logEvent(
                    "Absolute altitude acquisition: continuous supervised stream"
                )
            case .continuousNoWatchdog:
                startAbsoluteAltitudeLocked(reason: "sessionStart")
                SessionLogger.shared.logEvent("Absolute altitude acquisition: continuous single-consumer, no watchdog restarts")
            case .onDemand:
                // The stream stays off until the jump engine opens a window;
                // the freeze watchdog has nothing to supervise in this mode.
                pipelineMonitor.noteAbsoluteStreamExpected(false, at: ProcessInfo.processInfo.systemUptime)
                SessionLogger.shared.logEvent("Absolute altitude acquisition: onDemand (stream off until a jump window opens)")
            }
        }
    }

    /// Selects the absolute-altitude acquisition mode for the next session.
    /// Call before `startTracking`.
    func setAbsoluteAcquisitionMode(_ mode: AbsoluteAcquisitionMode) {
        altimeterControlQueue.sync {
            absoluteAcquisitionMode = mode
        }
    }

    /// On-demand window control (`.onDemand` mode only): the V14 engine opens
    /// the window at takeoff and closes it once the landing baseline is
    /// confirmed stable.
    func beginAbsoluteAltitudeWindow(reason: String) {
        altimeterControlQueue.async { [weak self] in
            guard let self, self.altitudeSessionActive,
                  self.absoluteAcquisitionMode == .onDemand,
                  self.absoluteAltimeter == nil else { return }
            self.startAbsoluteAltitudeLocked(reason: "window \(reason)")
        }
    }

    func endAbsoluteAltitudeWindow(reason: String) {
        altimeterControlQueue.async { [weak self] in
            guard let self, self.absoluteAcquisitionMode == .onDemand,
                  self.absoluteAltimeter != nil else { return }
            if #available(watchOS 8.0, iOS 15.0, *) {
                self.absoluteAltimeter?.stopAbsoluteAltitudeUpdates()
            }
            self.absoluteAltimeter = nil
            self.absoluteStreamGeneration += 1
            self.currentAbsoluteAltitudeSnapshot = (nil, nil, nil, nil)
            self.pipelineMonitor.noteAbsoluteStreamExpected(false, at: ProcessInfo.processInfo.systemUptime)
            SessionLogger.shared.logEvent("Absolute altitude window closed (\(reason))")
        }
    }

    /// Must run on altimeterControlQueue.
    private func startRelativeAltitudeLocked() {
        relativeAltimeter.startRelativeAltitudeUpdates(to: relativeAltimeterQueue) { [weak self] data, error in
            let receivedT = ProcessInfo.processInfo.systemUptime
            self?.pipelineMonitor.noteRelative(at: receivedT)
            self?.altimeterControlQueue.async { [weak self] in
                guard let self, self.altitudeSessionActive else { return }
                if let error {
                    print("Altimeter error: \(error.localizedDescription)")
                }
                guard let data else { return }

                let sensorT = self.relativeTimestampNormalizer.normalize(
                    sensorT: data.timestamp,
                    receivedT: receivedT
                )
                let relativeAltitudeM = data.relativeAltitude.doubleValue
                // CMAltimeter gives pressure in kPa; convert to hPa (mbar).
                let pressureHPa = data.pressure.doubleValue * 10.0
                self.currentPressure = pressureHPa
                self.currentRelativeAltitude = relativeAltitudeM
                self.currentBarometerTimestamp = sensorT
                self.noteRelativeAltitudeLocked(
                    receivedT: receivedT,
                    relativeAltitudeM: relativeAltitudeM
                )
                SessionLogger.shared.logBarometer(
                    t: sensorT,
                    relativeAltitudeM: relativeAltitudeM,
                    pressureHPa: pressureHPa
                )
            }
        }
        print("Barometer tracking started")
    }

    /// Must run on altimeterControlQueue.
    private func startAbsoluteAltitudeLocked(reason: String) {
        guard #available(watchOS 8.0, iOS 15.0, *) else { return }
        guard CMAltimeter.isAbsoluteAltitudeAvailable() else {
            print("Absolute altitude not available on this device")
            return
        }

        absoluteStreamGeneration += 1
        let generation = absoluteStreamGeneration
        let manager = CMAltimeter()
        absoluteAltimeter = manager
        let streamStartT = ProcessInfo.processInfo.systemUptime
        absoluteStreamStartedT = streamStartT
        pipelineMonitor.noteAbsoluteStreamExpected(true, at: streamStartT)
        lastAbsoluteReceivedT = nil
        lastAbsoluteChangedT = nil
        lastAbsoluteHealthValueM = nil
        lastAbsoluteProcessedReceivedT = nil
        relativeValueAtAbsoluteChangeM = latestRelativeHealthValueM
        absoluteTimestampNormalizer.reset()

        manager.startAbsoluteAltitudeUpdates(to: absoluteAltimeterQueue) { [weak self] data, error in
            let receivedT = ProcessInfo.processInfo.systemUptime
            self?.pipelineMonitor.noteAbsoluteSource(at: receivedT)
            self?.altimeterControlQueue.async { [weak self] in
                guard let self,
                      self.altitudeSessionActive,
                      generation == self.absoluteStreamGeneration else { return }
                if let error {
                    print("Absolute altitude error: \(error.localizedDescription)")
                    SessionLogger.shared.logEvent("Absolute altitude error: \(error.localizedDescription)")
                }
                guard let data else { return }

                let sensorT = self.absoluteTimestampNormalizer.normalize(
                    sensorT: data.timestamp,
                    receivedT: receivedT
                )
                self.noteAbsoluteAltitudeLocked(
                    receivedT: receivedT,
                    altitudeM: data.altitude,
                    accuracyM: data.accuracy
                )
                self.currentAbsoluteAltitudeSnapshot = (
                    data.altitude,
                    data.accuracy,
                    data.precision,
                    sensorT
                )
                SessionLogger.shared.logAbsoluteAltitude(
                    t: sensorT,
                    altitudeM: data.altitude,
                    accuracyM: data.accuracy,
                    precisionM: data.precision
                )
                let shouldProcess = self.lastAbsoluteProcessedReceivedT == nil
                    || receivedT - (self.lastAbsoluteProcessedReceivedT ?? 0)
                        >= self.absoluteProcessingIntervalSec - 0.005
                guard shouldProcess else { return }
                self.lastAbsoluteProcessedReceivedT = receivedT
                let processedT = ProcessInfo.processInfo.systemUptime
                self.pipelineMonitor.noteAbsoluteProcessed(
                    queueLatencySec: processedT - receivedT
                )
                self.onAbsoluteAltitude?(
                    sensorT,
                    receivedT,
                    data.altitude,
                    data.accuracy,
                    data.precision
                )
            }
        }
        print("Absolute altitude tracking started (\(reason), generation=\(generation))")
    }

    private func stopBarometer() {
        altimeterControlQueue.sync {
            altitudeSessionActive = false
            altimeterWatchdog?.cancel()
            altimeterWatchdog = nil
            relativeAltimeter.stopRelativeAltitudeUpdates()
            if #available(watchOS 8.0, iOS 15.0, *) {
                absoluteAltimeter?.stopAbsoluteAltitudeUpdates()
            }
            absoluteAltimeter = nil
            absoluteStreamGeneration += 1
            relativeTimestampNormalizer.reset()
            absoluteTimestampNormalizer.reset()
            lastAbsoluteProcessedReceivedT = nil
            resetAltitudeHealthLocked()
        }
    }

    /// Must run on altimeterControlQueue.
    private func resetAltitudeHealthLocked() {
        absoluteStreamStartedT = nil
        lastAbsoluteReceivedT = nil
        lastAbsoluteChangedT = nil
        lastAbsoluteHealthValueM = nil
        latestRelativeReceivedT = nil
        latestRelativeHealthValueM = nil
        relativeValueAtAbsoluteChangeM = nil
        absoluteRestartAttempts = 0
        didLogRestartExhaustion = false
    }

    /// Must run on altimeterControlQueue.
    private func noteRelativeAltitudeLocked(receivedT: TimeInterval,
                                            relativeAltitudeM: Double) {
        guard receivedT.isFinite, relativeAltitudeM.isFinite else { return }
        latestRelativeReceivedT = receivedT
        latestRelativeHealthValueM = relativeAltitudeM
        if relativeValueAtAbsoluteChangeM == nil {
            relativeValueAtAbsoluteChangeM = relativeAltitudeM
        }
    }

    /// Must run on altimeterControlQueue.
    private func noteAbsoluteAltitudeLocked(receivedT: TimeInterval,
                                            altitudeM: Double,
                                            accuracyM: Double?) {
        guard receivedT.isFinite, altitudeM.isFinite else { return }
        lastAbsoluteReceivedT = receivedT

        // Accuracy around 500 m is Core Motion's re-anchor sentinel. It is a
        // callback, but not evidence that the altitude estimate is responsive.
        if let accuracyM, accuracyM.isFinite, accuracyM >= 100 {
            return
        }

        guard let previous = lastAbsoluteHealthValueM else {
            lastAbsoluteHealthValueM = altitudeM
            lastAbsoluteChangedT = receivedT
            relativeValueAtAbsoluteChangeM = latestRelativeHealthValueM
            return
        }

        if abs(altitudeM - previous) >= Self.absoluteValueChangeEpsilonM {
            lastAbsoluteHealthValueM = altitudeM
            lastAbsoluteChangedT = receivedT
            relativeValueAtAbsoluteChangeM = latestRelativeHealthValueM
            absoluteRestartAttempts = 0
            didLogRestartExhaustion = false
        }
    }

    /// Must run on altimeterControlQueue.
    private func startAltimeterWatchdogLocked() {
        altimeterWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: altimeterControlQueue)
        timer.schedule(deadline: .now() + 4, repeating: 2, leeway: .milliseconds(400))
        timer.setEventHandler { [weak self] in
            self?.evaluateAbsoluteAltitudeHealthLocked()
        }
        altimeterWatchdog = timer
        timer.resume()
    }

    /// Must run on altimeterControlQueue.
    private func evaluateAbsoluteAltitudeHealthLocked() {
        guard altitudeSessionActive,
              CMAltimeter.isAbsoluteAltitudeAvailable(),
              let startedT = absoluteStreamStartedT else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - startedT >= Self.absoluteFreezeGraceSec,
              let relativeReceivedT = latestRelativeReceivedT,
              now - relativeReceivedT <= Self.relativeFreshnessSec,
              let relativeNow = latestRelativeHealthValueM,
              let relativeAnchor = relativeValueAtAbsoluteChangeM else { return }

        let relativeMovement = abs(relativeNow - relativeAnchor)
        guard relativeMovement >= Self.relativeMovementForRestartM else { return }

        let callbackGap = now - (lastAbsoluteReceivedT ?? startedT)
        let unchangedFor = now - (lastAbsoluteChangedT ?? startedT)
        let callbacksStopped = callbackGap >= Self.absoluteCallbackTimeoutSec
        let valueFrozen = callbackGap <= Self.relativeFreshnessSec
            && unchangedFor >= Self.absoluteFreezeGraceSec
        guard callbacksStopped || valueFrozen else { return }

        let relativeMovementText = String(format: "%.2f", relativeMovement)

        guard absoluteRestartAttempts < Self.maxAbsoluteRestartAttempts else {
            if !didLogRestartExhaustion {
                didLogRestartExhaustion = true
                SessionLogger.shared.logEvent(
                    "Absolute altitude watchdog exhausted restarts; relativeDelta=\(relativeMovementText)m"
                )
            }
            return
        }

        absoluteRestartAttempts += 1
        let callbackGapText = String(format: "%.1f", callbackGap)
        let unchangedForText = String(format: "%.1f", unchangedFor)
        let reason = callbacksStopped
            ? "callbacksStopped gap=\(callbackGapText)s"
            : "valueFrozen unchanged=\(unchangedForText)s"
        let detail = "\(reason) relativeDelta=\(relativeMovementText)m attempt=\(absoluteRestartAttempts)"
        if #available(watchOS 8.0, iOS 15.0, *) {
            absoluteAltimeter?.stopAbsoluteAltitudeUpdates()
        }
        absoluteAltimeter = nil
        currentAbsoluteAltitudeSnapshot = (nil, nil, nil, nil)
        SessionLogger.shared.logEvent("Absolute altitude watchdog restart: \(detail)")
        onAbsoluteAltitudeStreamRestart?(detail)
        startAbsoluteAltitudeLocked(reason: "watchdog")
    }

    private func processMotionData(_ motion: CMDeviceMotion) {
        pipelineMonitor.noteIMUProcessed()
        let submersion = currentSubmersion
        let pressure = currentPressure
        let relativeAltitude = currentRelativeAltitude
        let barometerTimestamp = currentBarometerTimestamp
        let absoluteAltitude = currentAbsoluteAltitudeSnapshot
        let attitude = motion.attitude.quaternion
        let sample = IMUSample(
            timestamp: date(for: motion),
            accelerationX: motion.userAcceleration.x,
            accelerationY: motion.userAcceleration.y,
            accelerationZ: motion.userAcceleration.z,
            rotationX: motion.rotationRate.x,
            rotationY: motion.rotationRate.y,
            rotationZ: motion.rotationRate.z,
            gravity: Vector3(
                x: motion.gravity.x,
                y: motion.gravity.y,
                z: motion.gravity.z
            ),
            pressure: pressure,
            motionTimestamp: motion.timestamp,
            relativeAltitude: relativeAltitude,
            barometerTimestamp: barometerTimestamp,
            absoluteAltitude: absoluteAltitude.alt,
            absoluteAltitudeAccuracy: absoluteAltitude.accuracy,
            absoluteAltitudePrecision: absoluteAltitude.precision,
            absoluteAltitudeTimestamp: absoluteAltitude.timestamp,
            attitudeQuaternion: MotionQuaternion(
                w: attitude.w,
                x: attitude.x,
                y: attitude.y,
                z: attitude.z
            ),
            submerged: submersion.submerged,
            waterDepth: submersion.waterDepthM,
            waterPressure: submersion.waterPressureHPa
        )
        
        // Immediate callback for real-time processing (jump detection)
        // Runs on the OperationQueue background thread — no main thread touch.
        onIMUSample?(sample)
        
        // Add to buffer for storage
        sampleBuffer.append(sample)
        
        if sampleBuffer.count >= bufferSize {
            onIMUBatch?(sampleBuffer)
            sampleBuffer.removeAll()
        }
    }

    /// Must run on motionProcessingQueue.
    private func flushSampleBuffer() {
        guard !sampleBuffer.isEmpty else { return }
        onIMUBatch?(sampleBuffer)
        sampleBuffer.removeAll(keepingCapacity: true)
    }

    private func startPipelineHealthTimer() {
        pipelineHealthQueue.sync {
            pipelineHealthTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: pipelineHealthQueue)
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let health = self.pipelineMonitor.snapshot(
                    at: ProcessInfo.processInfo.systemUptime
                )
                self.onPipelineHealth?(health)
                if health.imuSource == "CMBatchedSensorManager",
                   (health.imuGapSec ?? 0) >= 3 {
                    self.requestBatchedMotionFallback(
                        reason: String(
                            format: "silent callback gap %.2fs",
                            health.imuGapSec ?? 0
                        )
                    )
                }
            }
            pipelineHealthTimer = timer
            timer.resume()
        }
    }

    private func stopPipelineHealthTimer() {
        pipelineHealthQueue.sync {
            pipelineHealthTimer?.cancel()
            pipelineHealthTimer = nil
        }
    }

    private func date(for motion: CMDeviceMotion) -> Date {
        Date(timeIntervalSince1970: bootWallClock + motion.timestamp)
    }
    
    // MARK: - Utility Methods
    
    /// Get current acceleration magnitude
    func getAccelerationMagnitude() -> Double {
        guard let accel = currentAcceleration else { return 0 }
        return sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z)
    }
    
    /// Get current rotation magnitude (rad/s)
    func getRotationMagnitude() -> Double {
        guard let rotation = currentRotation else { return 0 }
        return sqrt(rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z)
    }
    
    /// Check if device is available for motion tracking
    static var isAvailable: Bool {
        return CMMotionManager().isDeviceMotionAvailable
    }
}
