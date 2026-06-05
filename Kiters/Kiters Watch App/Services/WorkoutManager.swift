//
//  WorkoutManager.swift
//  iSurf-Watch
//
//  Manages HKWorkoutSession for live heart-rate and calorie data.
//  Requires: HealthKit capability in Xcode → Signing & Capabilities
//            com.apple.developer.healthkit in entitlements
//            NSHealthShareUsageDescription + NSHealthUpdateUsageDescription in Info.plist
//

import Foundation
import HealthKit
import Combine

class WorkoutManager: NSObject, ObservableObject {
    
    // MARK: - Published Metrics
    @Published var isActive = false
    @Published var heartRate: Double = 0
    @Published var activeCalories: Double = 0
    
    // MARK: - Private
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var endCompletion: ((HKWorkout?) -> Void)?
    
    // MARK: - HealthKit Permission
    
    /// Call once to request read/write access. Safe to call multiple times.
    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("━━━━━━ HEALTHKIT ━━━━━━")
            print("❌ HealthKit NOT available on this device")
            print("━━━━━━━━━━━━━━━━━━━━━━━")
            return
        }
        
        let typesToShare: Set<HKSampleType> = [
            HKObjectType.workoutType()
        ]
        let typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!
        ]
        
        print("━━━━━━ HEALTHKIT ━━━━━━")
        print("✅ HealthKit available — requesting authorization...")
        print("━━━━━━━━━━━━━━━━━━━━━━━")
        
        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { success, error in
            if let error = error {
                print("❌ HealthKit auth error: \(error.localizedDescription)")
            } else if success {
                print("✅ HealthKit authorization GRANTED")
            } else {
                print("⚠️ HealthKit authorization DENIED by user")
            }
        }
    }
    
    // MARK: - Workout Control
    
    func startWorkout(sport: Sport) {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("⚠️ WorkoutManager: HealthKit not available")
            return
        }
        print("💪 WorkoutManager: starting HKWorkoutSession for \(sport.displayName)")
        
        let config = HKWorkoutConfiguration()
        config.activityType = sport.healthKitActivityType
        config.locationType = .outdoor
        
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                          workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            
            workoutSession = session
            workoutBuilder = builder
            
            session.startActivity(with: Date())
            builder.beginCollection(withStart: Date()) { success, error in
                if let error = error {
                    print("❌ Workout builder start error: \(error.localizedDescription)")
                } else {
                    DispatchQueue.main.async { self.isActive = true }
                    print("✅ HealthKit workout started")
                }
            }
        } catch {
            print("❌ Failed to create workout session: \(error.localizedDescription)")
        }
    }
    
    func pauseWorkout() {
        workoutSession?.pause()
        print("⏸️ Workout paused")
    }
    
    func resumeWorkout() {
        workoutSession?.resume()
        print("▶️ Workout resumed")
    }
    
    func endWorkout(completion: @escaping (Any?) -> Void) {
        guard let session = workoutSession, let builder = workoutBuilder else {
            completion(nil)
            return
        }
        
        session.end()
        builder.endCollection(withEnd: Date()) { [weak self] success, error in
            guard let self = self else { completion(nil); return }
            if let error = error {
                print("❌ Workout end error: \(error.localizedDescription)")
                completion(nil)
                return
            }
            builder.finishWorkout { workout, error in
                DispatchQueue.main.async {
                    self.isActive = false
                    self.workoutSession = nil
                    self.workoutBuilder = nil
                }
                if let error = error {
                    print("❌ Finish workout error: \(error.localizedDescription)")
                    completion(nil)
                } else {
                    print("✅ Workout saved to HealthKit")
                    completion(workout)
                }
            }
        }
    }
}

// MARK: - HKWorkoutSessionDelegate
extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        print("💪 Workout state: \(fromState.rawValue) → \(toState.rawValue)")
        DispatchQueue.main.async {
            self.isActive = (toState == .running)
        }
    }
    
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didFailWithError error: Error) {
        print("❌ Workout session error: \(error.localizedDescription)")
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate
extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType else { continue }
            
            let stats = workoutBuilder.statistics(for: quantityType)
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch quantityType {
                case HKQuantityType.quantityType(forIdentifier: .heartRate):
                    let bpm = stats?.mostRecentQuantity()?.doubleValue(for: .init(from: "count/min")) ?? 0
                    self.heartRate = bpm
                    print("❤️ Heart rate: \(Int(bpm)) BPM")
                    
                case HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned):
                    let cal = stats?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                    self.activeCalories = cal
                    
                default:
                    break
                }
            }
        }
    }
    
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) { }
}

// MARK: - Sport Extension
extension Sport {
    var healthKitActivityType: HKWorkoutActivityType {
        switch self {
        case .kiteboarding: return .surfingSports
        }
    }
}
