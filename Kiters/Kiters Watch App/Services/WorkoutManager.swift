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
import WatchKit
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

    // WKExtendedRuntimeSession keeps the process alive for network I/O when the
    // screen turns off, even before HKWorkoutSession transitions to .running.
    // Without it, URLSession.shared tasks created right after session start can
    // be frozen by watchOS before the first POST completes — the primary cause of
    // cloud uploads working in Xcode (debugger keeps process alive) but failing
    // silently on TestFlight.
    private var extendedSession: WKExtendedRuntimeSession?

    /// Dedicated live heart-rate stream. The HKLiveWorkoutBuilder statistics
    /// callback can be slow or silent on-device, so we also run an anchored
    /// query that pushes every new HR sample straight to the UI.
    private var heartRateQuery: HKAnchoredObjectQuery?
    private let heartRateUnit = HKUnit(from: "count/min")
    
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

        // Ensure HealthKit authorization is settled BEFORE starting the session
        // and the heart-rate stream. Starting the workout before read access is
        // granted is a common cause of live BPM staying at "--" on device.
        let typesToShare: Set<HKSampleType> = [HKObjectType.workoutType()]
        let typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!
        ]
        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { [weak self] _, error in
            if let error = error {
                print("❌ HealthKit auth error (startWorkout): \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                self?.beginWorkout(sport: sport)
            }
        }
    }

    private func beginWorkout(sport: Sport) {
        guard workoutSession == nil else {
            print("⚠️ WorkoutManager: workout already running")
            return
        }
        print("💪 WorkoutManager: starting HKWorkoutSession for \(sport.displayName)")

        // Start the extended runtime session BEFORE the HK workout so that
        // network tasks (cloud start POST) can complete even if the screen goes
        // off before HKWorkoutSession transitions to .running.
        let ext = WKExtendedRuntimeSession()
        ext.delegate = self
        ext.start()
        extendedSession = ext
        print("⏱️ Extended runtime session started")

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

            // Explicitly enable heart-rate collection — water-sports activity types
            // don't have it turned on automatically by HKLiveWorkoutDataSource.
            if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
                builder.dataSource?.enableCollection(for: hrType, predicate: nil)
            }

            workoutSession = session
            workoutBuilder = builder

            session.startActivity(with: Date())
            builder.beginCollection(withStart: Date()) { success, error in
                if let error = error {
                    print("❌ Workout builder start error: \(error.localizedDescription)")
                } else {
                    print("✅ HealthKit workout started")
                }
            }
        } catch {
            print("❌ Failed to create workout session: \(error.localizedDescription)")
        }
    }

    // MARK: - Live Heart-Rate Stream

    /// Streams heart-rate samples directly via HKAnchoredObjectQuery so live BPM
    /// shows even if the workout builder's statistics callback is delayed/silent.
    private func startHeartRateStream() {
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }

        // Only consider samples from now on (ignore historical data).
        let predicate = HKQuery.predicateForSamples(withStart: Date(), end: nil, options: .strictStartDate)

        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, error in
            if let error = error {
                print("❌ Heart-rate query error: \(error.localizedDescription)")
                return
            }
            self?.process(heartRateSamples: samples)
        }

        let query = HKAnchoredObjectQuery(type: hrType,
                                          predicate: predicate,
                                          anchor: nil,
                                          limit: HKObjectQueryNoLimit,
                                          resultsHandler: handler)
        query.updateHandler = handler

        heartRateQuery = query
        healthStore.execute(query)
        print("❤️ Heart-rate stream started")
    }

    private func process(heartRateSamples samples: [HKSample]?) {
        guard let samples = samples as? [HKQuantitySample], let latest = samples.last else { return }
        let bpm = latest.quantity.doubleValue(for: heartRateUnit)
        DispatchQueue.main.async { [weak self] in
            self?.heartRate = bpm
        }
        print("❤️ Heart rate (stream): \(Int(bpm)) BPM")
    }

    private func stopHeartRateStream() {
        if let query = heartRateQuery {
            healthStore.stop(query)
            heartRateQuery = nil
            print("❤️ Heart-rate stream stopped")
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
        stopHeartRateStream()
        guard let session = workoutSession, let builder = workoutBuilder else {
            extendedSession?.invalidate()
            extendedSession = nil
            completion(nil)
            return
        }

        session.end()
        builder.endCollection(withEnd: Date()) { [weak self] success, error in
            guard let self = self else { completion(nil); return }
            if let error = error {
                print("❌ Workout end error: \(error.localizedDescription)")
                self.extendedSession?.invalidate()
                self.extendedSession = nil
                completion(nil)
                return
            }
            builder.finishWorkout { workout, error in
                DispatchQueue.main.async {
                    self.isActive = false
                    self.workoutSession = nil
                    self.workoutBuilder = nil
                    // Keep extendedSession alive a bit longer so the end-of-session
                    // POST can complete before we release background time.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        self.extendedSession?.invalidate()
                        self.extendedSession = nil
                        print("⏱️ Extended runtime session ended")
                    }
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
            // Start the HR stream the moment the session is confirmed running.
            // This is more reliable than starting it speculatively in beginWorkout().
            if toState == .running {
                self.startHeartRateStream()
            }
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

// MARK: - WKExtendedRuntimeSessionDelegate
extension WorkoutManager: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        print("⏱️ Extended runtime session is running")
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        print("⏱️ Extended runtime session will expire")
    }

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?) {
        print("⏱️ Extended runtime session invalidated — reason: \(reason.rawValue)")
        if let error { print("⏱️ Error: \(error.localizedDescription)") }
        DispatchQueue.main.async { self.extendedSession = nil }
    }
}

// MARK: - Sport Extension
extension Sport {
    var healthKitActivityType: HKWorkoutActivityType {
        switch self {
        case .kiteboarding: return .surfingSports
        }
    }
}
