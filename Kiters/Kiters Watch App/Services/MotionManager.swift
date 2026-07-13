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

class MotionManager: ObservableObject {
    private let motionManager = CMMotionManager()
    // Keep relative and absolute altitude on separate CMAltimeter instances and
    // callback queues. Besides isolating the two Core Motion subscriptions, this
    // lets the absolute stream be recreated without disturbing the raw pressure
    // stream that the watchdog uses as an independent liveness signal.
    private let relativeAltimeter = CMAltimeter()
    private var absoluteAltimeter: CMAltimeter?
    private let queue = OperationQueue()
    private let relativeAltimeterQueue = OperationQueue()
    private let absoluteAltimeterQueue = OperationQueue()
    private let altimeterControlQueue = DispatchQueue(
        label: "com.kiters.altimeter.control",
        qos: .userInitiated
    )
    private var batchedSensorManager: CMBatchedSensorManager?
    private var usingBatchedDeviceMotion = false
    private var didFallbackFromBatchedError = false

    // All fields below are confined to altimeterControlQueue.
    private var altitudeSessionActive = false
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
    
    func startTracking(preferBatched: Bool = true) {
        guard isDeviceMotionAvailable else {
            print("❌ Device motion not available")
            return
        }

        guard !isTracking else { return }

        sampleBuffer.removeAll(keepingCapacity: true)
        didFallbackFromBatchedError = false
        startBarometer()

        var startedBatched = false
        if preferBatched {
            startedBatched = startBatchedDeviceMotionIfAvailable()
        }

        if !startedBatched {
            startFallbackDeviceMotion()
        }

        isTracking = true
        let source = usingBatchedDeviceMotion
            ? "CMBatchedSensorManager \(batchedSensorManager?.deviceMotionDataFrequency ?? 0)Hz"
            : "CMMotionManager \(Int(sampleRate))Hz"
        print("Motion tracking started via \(source) (baro: \(isBarometerAvailable ? "ON" : "OFF"))")
    }
    
    func stopTracking() {
        stopBatchedDeviceMotion()
        motionManager.stopDeviceMotionUpdates()
        stopBarometer()
        isTracking = false
        
        // Flush remaining buffer
        if !sampleBuffer.isEmpty {
            onIMUBatch?(sampleBuffer)
            sampleBuffer.removeAll()
        }
        
        currentPressure = nil
        currentRelativeAltitude = nil
        currentBarometerTimestamp = nil
        currentAbsoluteAltitudeSnapshot = (nil, nil, nil, nil)
        currentSubmersion = .unknown
        print("Motion tracking stopped")
    }
    
    func pauseTracking() {
        stopBatchedDeviceMotion()
        motionManager.stopDeviceMotionUpdates()
        stopBarometer()
        isTracking = false
        currentAbsoluteAltitudeSnapshot = (nil, nil, nil, nil)
        print("Motion tracking paused")
    }
    
    func resumeTracking(preferBatched: Bool = true) {
        startTracking(preferBatched: preferBatched)
        print("Motion tracking resumed")
    }

    func updateSubmersion(_ snapshot: WaterSubmersionSnapshot) {
        currentSubmersion = snapshot
    }

    func upgradeToBatchedIfAvailable() {
        guard isTracking, !usingBatchedDeviceMotion else { return }
        guard CMBatchedSensorManager.isDeviceMotionSupported else { return }

        motionManager.stopDeviceMotionUpdates()
        if startBatchedDeviceMotionIfAvailable() {
            print("Motion tracking upgraded to CMBatchedSensorManager \(batchedSensorManager?.deviceMotionDataFrequency ?? 0)Hz")
        } else {
            startFallbackDeviceMotion()
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
                self.handleBatchedMotionError(error)
                return
            }
            guard let motions, !motions.isEmpty else { return }
            for motion in motions {
                self.processMotionData(motion)
            }
        }

        return true
    }

    private func handleBatchedMotionError(_ error: Error) {
        print("Batched device motion error: \(error.localizedDescription)")
        guard !didFallbackFromBatchedError else { return }
        didFallbackFromBatchedError = true
        stopBatchedDeviceMotion()
        startFallbackDeviceMotion()
        print("Motion tracking fell back to CMMotionManager \(Int(sampleRate))Hz")
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

            self.processMotionData(motion)
        }
        usingBatchedDeviceMotion = false
    }

    private func startBarometer() {
        altimeterControlQueue.sync {
            altitudeSessionActive = true
            relativeTimestampNormalizer.reset()
            absoluteTimestampNormalizer.reset()
            resetAltitudeHealthLocked()

            if CMAltimeter.isRelativeAltitudeAvailable() {
                startRelativeAltitudeLocked()
            } else {
                print("Relative altitude not available on this device")
            }

            startAbsoluteAltitudeLocked(reason: "sessionStart")
            startAltimeterWatchdogLocked()
        }
    }

    /// Must run on altimeterControlQueue.
    private func startRelativeAltitudeLocked() {
        relativeAltimeter.startRelativeAltitudeUpdates(to: relativeAltimeterQueue) { [weak self] data, error in
            let receivedT = ProcessInfo.processInfo.systemUptime
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
        absoluteStreamStartedT = ProcessInfo.processInfo.systemUptime
        lastAbsoluteReceivedT = nil
        lastAbsoluteChangedT = nil
        lastAbsoluteHealthValueM = nil
        relativeValueAtAbsoluteChangeM = latestRelativeHealthValueM
        absoluteTimestampNormalizer.reset()

        manager.startAbsoluteAltitudeUpdates(to: absoluteAltimeterQueue) { [weak self] data, error in
            let receivedT = ProcessInfo.processInfo.systemUptime
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
