//
//  MotionManager.swift
//  iSurf-Watch
//
//  Manages IMU sensor data (accelerometer + gyroscope) at 50Hz
//  and barometric pressure from CMAltimeter.
//

import Foundation
import CoreMotion
import Combine

class MotionManager: ObservableObject {
    private let motionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let queue = OperationQueue()
    
    @Published var isTracking = false
    @Published var currentAcceleration: CMAcceleration?
    @Published var currentRotation: CMRotationRate?
    
    var isDeviceMotionAvailable: Bool { motionManager.isDeviceMotionAvailable }
    var isBarometerAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }
    
    // High-frequency IMU data (50Hz)
    private let sampleRate = 50.0 // Hz
    
    // Sample buffer for batch processing
    private var sampleBuffer: [IMUSample] = []
    private let bufferSize = 250 // Send every 250 samples (~5 seconds at 50Hz)
    
    // Barometer state — updated at ~1Hz by CMAltimeter
    private let baroLock = NSLock()
    private var _currentPressure: Double? = nil
    
    private var currentPressure: Double? {
        get { baroLock.lock(); defer { baroLock.unlock() }; return _currentPressure }
        set { baroLock.lock(); defer { baroLock.unlock() }; _currentPressure = newValue }
    }
    
    // Callbacks
    var onIMUSample: ((IMUSample) -> Void)?
    var onIMUBatch: (([IMUSample]) -> Void)?
    
    init() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }
    
    func startTracking() {
        guard motionManager.isDeviceMotionAvailable else {
            print("❌ Device motion not available")
            return
        }
        
        // Configure motion manager
        motionManager.deviceMotionUpdateInterval = 1.0 / sampleRate
        
        // Start device motion updates (includes accelerometer, gyroscope, and gravity)
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self = self, let motion = motion else {
                if let error = error {
                    print("❌ Motion error: \(error.localizedDescription)")
                }
                return
            }
            
            self.processMotionData(motion)
        }
        
        // Start barometer if available
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, error in
                guard let self = self, let data = data else {
                    if let error = error {
                        print("❌ Altimeter error: \(error.localizedDescription)")
                    }
                    return
                }
                // CMAltimeter gives pressure in kPa — convert to hPa (mbar)
                let pressureHPa = data.pressure.doubleValue * 10.0
                self.currentPressure = pressureHPa
            }
            print("🌡️ Barometer tracking started")
        } else {
            print("⚠️ Barometer not available on this device")
        }
        
        isTracking = true
        print("🎯 Motion tracking started at \(sampleRate)Hz (baro: \(isBarometerAvailable ? "ON" : "OFF"))")
    }
    
    func stopTracking() {
        motionManager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        isTracking = false
        
        // Flush remaining buffer
        if !sampleBuffer.isEmpty {
            onIMUBatch?(sampleBuffer)
            sampleBuffer.removeAll()
        }
        
        currentPressure = nil
        print("🎯 Motion tracking stopped")
    }
    
    func pauseTracking() {
        motionManager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        isTracking = false
        print("⏸️ Motion tracking paused")
    }
    
    func resumeTracking() {
        startTracking()
        print("▶️ Motion tracking resumed")
    }
    
    private func processMotionData(_ motion: CMDeviceMotion) {
        let sample = IMUSample(
            timestamp: Date(),
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
            pressure: currentPressure
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
