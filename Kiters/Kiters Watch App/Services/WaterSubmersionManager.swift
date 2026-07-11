//
//  WaterSubmersionManager.swift
//  Kiters Watch App
//
//  Thin wrapper around CMWaterSubmersionManager. It keeps the latest water
//  state in app-native units so MotionManager can stamp it onto each IMU sample.
//

import Foundation
import CoreMotion

struct WaterSubmersionSnapshot {
    var submerged: Bool?
    var waterDepthM: Double?
    var waterPressureHPa: Double?

    static let unknown = WaterSubmersionSnapshot(
        submerged: nil,
        waterDepthM: nil,
        waterPressureHPa: nil
    )
}

final class WaterSubmersionManager: NSObject, ObservableObject {
    @Published private(set) var snapshot: WaterSubmersionSnapshot = .unknown

    var onSnapshot: ((WaterSubmersionSnapshot) -> Void)?

    private let lock = NSLock()
    private var snapshotStorage: WaterSubmersionSnapshot = .unknown
    private var manager: CMWaterSubmersionManager?

    var currentSnapshot: WaterSubmersionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotStorage
    }

    var isAvailable: Bool {
        CMWaterSubmersionManager.waterSubmersionAvailable
    }

    func start() {
        guard CMWaterSubmersionManager.waterSubmersionAvailable else {
            publish(.unknown)
            print("Water submersion not available on this device")
            return
        }

        let manager = CMWaterSubmersionManager()
        manager.delegate = self
        self.manager = manager
        print("Water submersion tracking started")
    }

    func stop() {
        manager?.delegate = nil
        manager = nil
        publish(.unknown)
        print("Water submersion tracking stopped")
    }

    private func publish(_ next: WaterSubmersionSnapshot) {
        lock.lock()
        snapshotStorage = next
        lock.unlock()

        onSnapshot?(next)
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = next
        }
    }

    private func update(submerged: Bool?,
                        depthM: Double? = nil,
                        pressureHPa: Double? = nil) {
        let previous = currentSnapshot
        publish(WaterSubmersionSnapshot(
            submerged: submerged ?? previous.submerged,
            waterDepthM: depthM,
            waterPressureHPa: pressureHPa
        ))
    }

    private func submerged(from state: CMWaterSubmersionEvent.State) -> Bool? {
        switch state {
        case .unknown:
            return nil
        case .notSubmerged:
            return false
        case .submerged:
            return true
        @unknown default:
            return nil
        }
    }

    private func submerged(from state: CMWaterSubmersionMeasurement.DepthState) -> Bool? {
        switch state {
        case .unknown, .sensorDepthError:
            return nil
        case .notSubmerged:
            return false
        case .submergedShallow, .submergedDeep, .approachingMaxDepth, .pastMaxDepth:
            return true
        @unknown default:
            return nil
        }
    }
}

extension WaterSubmersionManager: CMWaterSubmersionManagerDelegate {
    func manager(_ manager: CMWaterSubmersionManager, didUpdate event: CMWaterSubmersionEvent) {
        let state = submerged(from: event.state)
        if let state {
            SessionLogger.shared.logSubmersion(
                t: ProcessInfo.processInfo.systemUptime,
                kind: 0,
                value: state ? 1 : 0
            )
        }
        update(submerged: state)
    }

    func manager(_ manager: CMWaterSubmersionManager, didUpdate measurement: CMWaterSubmersionMeasurement) {
        let depth = measurement.depth?.converted(to: .meters).value
        let pressure = measurement.pressure?.converted(to: .hectopascals).value
        if let depth {
            SessionLogger.shared.logSubmersion(
                t: ProcessInfo.processInfo.systemUptime,
                kind: 1,
                value: depth
            )
        }
        update(
            submerged: submerged(from: measurement.submersionState),
            depthM: depth,
            pressureHPa: pressure
        )
    }

    func manager(_ manager: CMWaterSubmersionManager, didUpdate measurement: CMWaterTemperature) {
        SessionLogger.shared.logSubmersion(
            t: ProcessInfo.processInfo.systemUptime,
            kind: 2,
            value: measurement.temperature.converted(to: .celsius).value
        )
    }

    func manager(_ manager: CMWaterSubmersionManager, errorOccurred error: any Error) {
        publish(.unknown)
        print("Water submersion error: \(error.localizedDescription)")
    }
}
