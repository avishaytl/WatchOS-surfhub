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
    private let altimeter = CMAltimeter()
    private let queue = OperationQueue()
    private let altimeterQueue = OperationQueue()
    private var batchedSensorManager: CMBatchedSensorManager?
    private var usingBatchedDeviceMotion = false
    private var didFallbackFromBatchedError = false
    
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
    
    init() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        altimeterQueue.maxConcurrentOperationCount = 1
        altimeterQueue.qualityOfService = .userInteractive
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
        altimeter.stopRelativeAltitudeUpdates()
        stopAbsoluteAltitudeUpdatesIfAvailable()
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
        altimeter.stopRelativeAltitudeUpdates()
        stopAbsoluteAltitudeUpdatesIfAvailable()
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
        if !CMAltimeter.isRelativeAltitudeAvailable() {
            print("Relative altitude not available on this device")
            startAbsoluteAltitudeIfAvailable()
            return
        }

        altimeter.startRelativeAltitudeUpdates(to: altimeterQueue) { [weak self] data, error in
            guard let self = self, let data = data else {
                if let error = error {
                    print("Altimeter error: \(error.localizedDescription)")
                }
                return
            }
            // CMAltimeter gives pressure in kPa; convert to hPa (mbar).
            let pressureHPa = data.pressure.doubleValue * 10.0
            self.currentPressure = pressureHPa
            self.currentRelativeAltitude = data.relativeAltitude.doubleValue
            self.currentBarometerTimestamp = data.timestamp
            SessionLogger.shared.logBarometer(
                t: data.timestamp,
                relativeAltitudeM: data.relativeAltitude.doubleValue,
                pressureHPa: pressureHPa
            )
        }
        print("Barometer tracking started")

        startAbsoluteAltitudeIfAvailable()
    }

    private func startAbsoluteAltitudeIfAvailable() {
        guard #available(watchOS 8.0, iOS 15.0, *) else { return }
        guard CMAltimeter.isAbsoluteAltitudeAvailable() else {
            print("Absolute altitude not available on this device")
            return
        }

        altimeter.startAbsoluteAltitudeUpdates(to: altimeterQueue) { [weak self] data, error in
            guard let self = self, let data = data else {
                if let error = error {
                    print("Absolute altitude error: \(error.localizedDescription)")
                }
                return
            }
            let receivedT = ProcessInfo.processInfo.systemUptime
            self.currentAbsoluteAltitudeSnapshot = (
                data.altitude,
                data.accuracy,
                data.precision,
                data.timestamp
            )
            SessionLogger.shared.logAbsoluteAltitude(
                t: data.timestamp,
                altitudeM: data.altitude,
                accuracyM: data.accuracy,
                precisionM: data.precision
            )
            self.onAbsoluteAltitude?(
                data.timestamp,
                receivedT,
                data.altitude,
                data.accuracy,
                data.precision
            )
        }
        print("Absolute altitude tracking started")
    }

    private func stopAbsoluteAltitudeUpdatesIfAvailable() {
        guard #available(watchOS 8.0, iOS 15.0, *) else { return }
        altimeter.stopAbsoluteAltitudeUpdates()
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
