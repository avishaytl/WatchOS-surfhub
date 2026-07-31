//
//  SensorProvider.swift
//  Kiters Watch App
//
//  The single acquisition boundary used by the live session and the on-watch
//  replay lab. Jump detectors consume app-native sensor events and never need
//  to know whether Core Motion/Core Location or a recorded KSLG stream produced
//  them.
//

import Foundation

struct BarometerSensorReading {
    let sensorT: TimeInterval
    let relativeAltitudeM: Double
    let pressureHPa: Double
}

struct AbsoluteAltitudeSensorReading {
    let sensorT: TimeInterval
    let receivedT: TimeInterval
    let altitudeM: Double
    let accuracyM: Double?
    let precisionM: Double?
}

struct SubmersionSensorReading {
    let sensorT: TimeInterval
    let snapshot: WaterSubmersionSnapshot
}

enum SensorProviderEvent {
    case motion(IMUSample)
    case motionBatch([IMUSample])
    case barometer(BarometerSensorReading)
    case absoluteAltitude(AbsoluteAltitudeSensorReading)
    case gps(GPSPoint)
    case gpsBatch([GPSPoint])
    case submersion(SubmersionSensorReading)
    case absoluteAltitudeStreamRestart(String)
    case imuStreamRecovery(String)
    case pipelineHealth(MotionPipelineHealth)
    case diagnostic(timestamp: TimeInterval, message: String)
}

struct SensorProviderStatistics {
    var deliveredEvents = 0
    var motionSamples = 0
    var barometerSamples = 0
    var absoluteAltitudeSamples = 0
    var gpsSamples = 0
    var submersionSamples = 0
    var lateEvents = 0
    var maximumLatenessMs = 0.0
}

protocol SensorProvider: AnyObject {
    var onEvent: ((SensorProviderEvent) -> Void)? { get set }
    var currentTime: TimeInterval { get }
    var statistics: SensorProviderStatistics { get }

    func start()
    func pause()
    func stop()
}

/// Production provider. It owns no algorithm state: it only translates the
/// existing acquisition managers into the shared event stream.
final class LiveSensorProvider: SensorProvider {
    var onEvent: ((SensorProviderEvent) -> Void)?

    private let motionManager: MotionManager
    private let locationManager: LocationManager
    private let waterSubmersionManager: WaterSubmersionManager
    private let lock = NSLock()
    private var statisticsStorage = SensorProviderStatistics()
    private var lastBarometerT: TimeInterval?

    init(
        motionManager: MotionManager,
        locationManager: LocationManager,
        waterSubmersionManager: WaterSubmersionManager
    ) {
        self.motionManager = motionManager
        self.locationManager = locationManager
        self.waterSubmersionManager = waterSubmersionManager
        connectCallbacks()
    }

    var currentTime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    var statistics: SensorProviderStatistics {
        lock.lock()
        defer { lock.unlock() }
        return statisticsStorage
    }

    /// Starts the session-owned GPS stream. Motion has a separate staged start
    /// because batched 200 Hz device motion can only begin after the workout is
    /// active on watchOS.
    func start() {
        resetStatistics()
        locationManager.startTracking()
    }

    func startMotion(
        preferBatched: Bool,
        absoluteProcessingIntervalOverrideSec: Double?
    ) {
        waterSubmersionManager.start()
        motionManager.startTracking(
            preferBatched: preferBatched,
            absoluteProcessingIntervalOverrideSec: absoluteProcessingIntervalOverrideSec
        )
    }

    func upgradeMotionToBatchedIfAvailable() {
        motionManager.upgradeToBatchedIfAvailable()
    }

    func pause() {
        locationManager.pauseTracking()
        motionManager.pauseTracking()
        waterSubmersionManager.stop()
    }

    func resumeLocation() {
        locationManager.resumeTracking()
    }

    func stop() {
        locationManager.stopTracking()
        motionManager.stopTracking()
        waterSubmersionManager.stop()
    }

    func prewarmLocation() {
        locationManager.prewarm()
    }

    func stopLocationPrewarm() {
        locationManager.stopPrewarm()
    }

    func setAbsoluteAcquisitionMode(_ mode: MotionManager.AbsoluteAcquisitionMode) {
        motionManager.setAbsoluteAcquisitionMode(mode)
    }

    func beginAbsoluteAltitudeWindow(reason: String) {
        motionManager.beginAbsoluteAltitudeWindow(reason: reason)
    }

    func endAbsoluteAltitudeWindow(reason: String) {
        motionManager.endAbsoluteAltitudeWindow(reason: reason)
    }

    private func connectCallbacks() {
        locationManager.onLocationUpdate = { [weak self] point in
            self?.publish(.gps(point)) {
                $0.gpsSamples += 1
            }
        }
        locationManager.onLocationBatch = { [weak self] batch in
            self?.publish(.gpsBatch(batch))
        }

        motionManager.onIMUSample = { [weak self] sample in
            guard let self else { return }
            if let sensorT = sample.barometerTimestamp,
               let relativeAltitudeM = sample.relativeAltitude,
               let pressureHPa = sample.pressure,
               self.shouldPublishBarometer(sensorT: sensorT) {
                self.publish(.barometer(BarometerSensorReading(
                    sensorT: sensorT,
                    relativeAltitudeM: relativeAltitudeM,
                    pressureHPa: pressureHPa
                ))) {
                    $0.barometerSamples += 1
                }
            }
            self.publish(.motion(sample)) {
                $0.motionSamples += 1
            }
        }
        motionManager.onIMUBatch = { [weak self] batch in
            self?.publish(.motionBatch(batch))
        }
        motionManager.onAbsoluteAltitude = { [weak self] sensorT, receivedT, altitudeM, accuracyM, precisionM in
            self?.publish(.absoluteAltitude(AbsoluteAltitudeSensorReading(
                sensorT: sensorT,
                receivedT: receivedT,
                altitudeM: altitudeM,
                accuracyM: accuracyM,
                precisionM: precisionM
            ))) {
                $0.absoluteAltitudeSamples += 1
            }
        }
        motionManager.onAbsoluteAltitudeStreamRestart = { [weak self] reason in
            self?.publish(.absoluteAltitudeStreamRestart(reason))
        }
        motionManager.onIMUStreamRecovery = { [weak self] reason in
            self?.publish(.imuStreamRecovery(reason))
        }
        motionManager.onPipelineHealth = { [weak self] health in
            self?.publish(.pipelineHealth(health))
        }

        waterSubmersionManager.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.motionManager.updateSubmersion(snapshot)
            self.publish(.submersion(SubmersionSensorReading(
                sensorT: ProcessInfo.processInfo.systemUptime,
                snapshot: snapshot
            ))) {
                $0.submersionSamples += 1
            }
        }
    }

    private func shouldPublishBarometer(sensorT: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard lastBarometerT.map({ sensorT > $0 }) ?? true else { return false }
        lastBarometerT = sensorT
        return true
    }

    private func resetStatistics() {
        lock.lock()
        statisticsStorage = SensorProviderStatistics()
        lastBarometerT = nil
        lock.unlock()
    }

    private func publish(
        _ event: SensorProviderEvent,
        update: ((inout SensorProviderStatistics) -> Void)? = nil
    ) {
        lock.lock()
        statisticsStorage.deliveredEvents += 1
        update?(&statisticsStorage)
        lock.unlock()
        onEvent?(event)
    }
}
