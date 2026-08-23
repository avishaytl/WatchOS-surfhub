//
//  WorkoutManager.swift
//  SPOTEQ
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

/// Delivers the bounded HealthKit summary exactly once even if the framework's
/// end-collection callback races the fallback timeout.
private final class HealthSummaryCompletionGate {
    private let lock = NSLock()
    private var delivered = false
    private let completion: (SessionHealthMetrics) -> Void

    init(completion: @escaping (SessionHealthMetrics) -> Void) {
        self.completion = completion
    }

    @discardableResult
    func deliver(_ summary: SessionHealthMetrics) -> Bool {
        lock.lock()
        guard !delivered else {
            lock.unlock()
            return false
        }
        delivered = true
        lock.unlock()
        DispatchQueue.main.async { self.completion(summary) }
        return true
    }
}

class WorkoutManager: NSObject, ObservableObject {

    // MARK: - Published Metrics
    @Published var isActive = false
    @Published var heartRate: Double = 0
    @Published var activeCalories: Double = 0

    // MARK: - Private
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutSessionGeneration = 0
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var workoutBuilderGeneration = 0
    private var endCompletion: ((HKWorkout?) -> Void)?
    /// Invalidates delayed authorization/query callbacks from an older session.
    /// Accessed on the main thread; background HealthKit callbacks hop to main
    /// before comparing it.
    private var workoutGeneration = 0

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
    /// Aggregate state for the lifecycle `end` upload. Mutated on the main
    /// thread together with the published workout metrics.
    private var sessionHealthMetrics = SessionHealthMetrics()
    
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
        workoutGeneration += 1
        let generation = workoutGeneration

        // Clear the previous workout before authorization/session startup. This
        // also makes an unavailable or denied HealthKit session report nil
        // instead of leaking the previous session's calories or peak HR.
        sessionHealthMetrics.reset()
        heartRate = 0
        activeCalories = 0

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
                guard let self, self.workoutGeneration == generation else { return }
                self.beginWorkout(sport: sport, generation: generation)
            }
        }
    }

    private func beginWorkout(sport: Sport, generation: Int, attempt: Int = 0) {
        guard workoutGeneration == generation else { return }
        guard workoutSession == nil else {
            guard attempt < 24 else {
                print("⚠️ WorkoutManager: previous workout did not release in time")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.beginWorkout(sport: sport, generation: generation, attempt: attempt + 1)
            }
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
            if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
                builder.dataSource?.enableCollection(for: energyType, predicate: nil)
            }

            workoutSession = session
            workoutSessionGeneration = generation
            workoutBuilder = builder
            workoutBuilderGeneration = generation

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
        // A pause/resume transition can report `.running` more than once. The
        // original anchored query spans the pause and must remain the sole one.
        guard heartRateQuery == nil else { return }
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }
        let generation = workoutGeneration

        // Only consider samples from now on (ignore historical data).
        let predicate = HKQuery.predicateForSamples(withStart: Date(), end: nil, options: .strictStartDate)

        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, error in
            if let error = error {
                print("❌ Heart-rate query error: \(error.localizedDescription)")
                return
            }
            self?.process(heartRateSamples: samples, generation: generation)
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

    private func process(heartRateSamples samples: [HKSample]?, generation: Int) {
        guard let samples = samples as? [HKQuantitySample] else { return }
        let values = samples
            .map { $0.quantity.doubleValue(for: heartRateUnit) }
            .filter { $0.isFinite && $0 > 0 }
        guard let bpm = values.last, let batchMaximum = values.max() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.workoutGeneration == generation else { return }
            self.heartRate = bpm
            self.sessionHealthMetrics.recordHeartRate(batchMaximum)
            print("❤️ Heart rate (stream): \(Int(bpm.rounded())) BPM")
        }
    }

    /// Full-session aggregate snapshot at the moment the rider ends the
    /// session. Reading the builder statistics here closes any gap left by a
    /// delayed delegate callback without waiting for `finishWorkout`.
    func healthMetricsSnapshot() -> SessionHealthMetrics {
        var snapshot = sessionHealthMetrics
        snapshot.recordHeartRate(heartRate)
        snapshot.recordActiveCalories(activeCalories)
        return healthMetrics(from: workoutBuilder, merging: snapshot)
    }

    private func healthMetrics(
        from builder: HKLiveWorkoutBuilder?,
        merging base: SessionHealthMetrics
    ) -> SessionHealthMetrics {
        var snapshot = base
        if let builder {
            if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
               let maximum = builder.statistics(for: hrType)?.maximumQuantity() {
                snapshot.recordHeartRate(maximum.doubleValue(for: heartRateUnit))
            }
            if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
               let total = builder.statistics(for: energyType)?.sumQuantity() {
                snapshot.recordActiveCalories(total.doubleValue(for: .kilocalorie()))
            }
        }
        return snapshot
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
    
    /// Ends HealthKit collection and returns a session-bound aggregate. A five
    /// second fallback prevents a stalled HealthKit callback from keeping the
    /// watch-ingest session open; a later callback cannot deliver twice.
    func endWorkout(completion: @escaping (SessionHealthMetrics) -> Void) {
        workoutGeneration += 1   // invalidate auth/query callbacks from this session
        let endingGeneration = workoutGeneration
        stopHeartRateStream()
        let fallback = healthMetricsSnapshot()
        let gate = HealthSummaryCompletionGate(completion: completion)
        let closingRuntimeSession = extendedSession
        let closingWorkoutSession = workoutSession
        let closingWorkoutBuilder = workoutBuilder

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard gate.deliver(fallback) else { return }
            self?.releaseWorkoutOwnership(
                session: closingWorkoutSession,
                builder: closingWorkoutBuilder,
                generation: endingGeneration
            )
            self?.scheduleRuntimeInvalidation(closingRuntimeSession)
        }

        guard let session = closingWorkoutSession, let builder = closingWorkoutBuilder else {
            if gate.deliver(fallback) {
                releaseWorkoutOwnership(session: nil, builder: nil, generation: endingGeneration)
                scheduleRuntimeInvalidation(closingRuntimeSession)
            }
            return
        }

        session.end()
        builder.endCollection(withEnd: Date()) { [weak self] success, error in
            guard let self else {
                gate.deliver(fallback)
                return
            }

            let finalMetrics = self.healthMetrics(from: builder, merging: fallback)
            if gate.deliver(finalMetrics) {
                self.releaseWorkoutOwnership(
                    session: session,
                    builder: builder,
                    generation: endingGeneration
                )
                self.scheduleRuntimeInvalidation(closingRuntimeSession)
            }

            guard success, error == nil else {
                let message = error?.localizedDescription ?? "endCollection returned false"
                print("❌ Workout end error: \(message)")
                return
            }

            builder.finishWorkout { workout, error in
                if let error = error {
                    print("❌ Finish workout error: \(error.localizedDescription)")
                } else {
                    print("✅ Workout saved to HealthKit")
                }
                _ = workout
            }
        }
    }

    private func releaseWorkoutOwnership(
        session: HKWorkoutSession?,
        builder: HKLiveWorkoutBuilder?,
        generation: Int
    ) {
        DispatchQueue.main.async {
            let ownsSession = session != nil && self.workoutSession === session
            let ownsBuilder = builder != nil && self.workoutBuilder === builder
            if self.workoutGeneration == generation || ownsSession {
                self.isActive = false
            }
            if ownsSession {
                self.workoutSession = nil
                self.workoutSessionGeneration = 0
            }
            if ownsBuilder {
                self.workoutBuilder = nil
                self.workoutBuilderGeneration = 0
            }
        }
    }

    /// The lifecycle POST allows up to 30 seconds. Keep the exact runtime
    /// session that owned this workout alive for a little longer, without a
    /// stale callback ever invalidating a newer session's runtime lease.
    private func scheduleRuntimeInvalidation(_ runtimeSession: WKExtendedRuntimeSession?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self, weak runtimeSession] in
            runtimeSession?.invalidate()
            if let self, self.extendedSession === runtimeSession {
                self.extendedSession = nil
            }
            print("⏱️ Extended runtime session ended")
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
            guard self.workoutSession === workoutSession,
                  self.workoutSessionGeneration == self.workoutGeneration else { return }
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
                guard self.workoutBuilder === workoutBuilder,
                      self.workoutBuilderGeneration == self.workoutGeneration else { return }
                switch quantityType {
                case HKQuantityType.quantityType(forIdentifier: .heartRate):
                    let bpm = stats?.mostRecentQuantity()?.doubleValue(for: .init(from: "count/min")) ?? 0
                    let maximum = stats?.maximumQuantity()?.doubleValue(for: self.heartRateUnit) ?? bpm
                    self.sessionHealthMetrics.recordHeartRate(maximum)
                    if bpm.isFinite, bpm > 0 {
                        self.heartRate = bpm
                        print("❤️ Heart rate: \(Int(bpm.rounded())) BPM")
                    }
                    
                case HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned):
                    let cal = stats?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                    self.sessionHealthMetrics.recordActiveCalories(cal)
                    if cal.isFinite, cal >= 0 {
                        self.activeCalories = cal
                    }
                    
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
