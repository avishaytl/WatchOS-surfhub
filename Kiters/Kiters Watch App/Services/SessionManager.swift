//
//  SessionManager.swift
//  iSurf-Watch
//
//  Coordinates all services and manages active session state
//

import Foundation
import Combine
import CoreLocation
import Network
import WatchKit

// MARK: - GPS Signal Quality
enum GPSSignalQuality: String {
    case none      // No GPS fix
    case weak      // accuracy > 30m
    case fair      // accuracy 15–30m
    case good      // accuracy 5–15m
    case strong    // accuracy < 5m
    
    var icon: String {
        switch self {
        case .none:   return "location.slash"
        case .weak:   return "location"
        case .fair:   return "location.fill"
        case .good:   return "location.fill"
        case .strong: return "location.circle.fill"
        }
    }
    
    var color: String {
        switch self {
        case .none:   return "red"
        case .weak:   return "orange"
        case .fair:   return "yellow"
        case .good:   return "green"
        case .strong: return "green"
        }
    }
    
    var displayName: String {
        switch self {
        case .none:   return "No GPS"
        case .weak:   return "Weak"
        case .fair:   return "Fair"
        case .good:   return "Good"
        case .strong: return "Strong"
        }
    }
    
    static func from(accuracy: Double) -> GPSSignalQuality {
        if accuracy <= 0 { return .none }
        if accuracy < 5 { return .strong }
        if accuracy < 15 { return .good }
        if accuracy < 30 { return .fair }
        return .weak
    }
}

struct PendingSessionCloudUpload: Identifiable {
    let session: Session
    let logURL: URL?

    var id: String { session.id }
}

struct SessionUserNotice: Identifiable {
    let id = UUID()
    let titleKey: String
    let messageKey: String
}

class SessionManager: ObservableObject {
    // Services
    private let locationManager = LocationManager()
    private let motionManager = MotionManager()
    private let waterSubmersionManager = WaterSubmersionManager()
    private let workoutManager = WorkoutManager()
    private let storageManager = StorageManager()
    private lazy var sensorProvider = LiveSensorProvider(
        motionManager: motionManager,
        locationManager: locationManager,
        waterSubmersionManager: waterSubmersionManager
    )
    /// Selected at each session start based on the "detectionEngine" setting.
    private var jumpDetector: JumpDetecting = JumpDetector()
    private let sessionLogger = SessionLogger.shared
    
    // Published state
    @Published var currentSession: Session?
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var jumpCount = 0
    @Published var distance: Double = 0
    @Published var maxSpeed: Double = 0
    @Published var currentSpeed: Double = 0
    @Published var duration: TimeInterval = 0
    @Published var heartRate: Double = 0
    @Published var activeCalories: Double = 0
    @Published var pendingCloudUpload: PendingSessionCloudUpload?
    @Published var sessionNotice: SessionUserNotice?
    @Published var canUploadPendingSession = false
    @Published var newBestJumpPresentation: Jump?
    
    // GPS tracking state
    @Published var gpsPointCount: Int = 0
    @Published var isGPSActive: Bool = false
    @Published var lastGPSAccuracy: Double = 0
    @Published var gpsSignalQuality: GPSSignalQuality = .none
    
    // Jump detection state (live)
    @Published var jumpDetectionState: JumpDetector.JumpState = .idle
    
    // Permission state
    @Published var locationDenied = false
    @Published var locationAuthStatus: CLAuthorizationStatus = .notDetermined
    @Published var permissionRequested = false
    
    // Computed helpers
    var isLocationAuthorized: Bool {
        locationAuthStatus == .authorizedWhenInUse || locationAuthStatus == .authorizedAlways
    }
    var isLocationNotDetermined: Bool {
        locationAuthStatus == .notDetermined
    }
    var isLocationDenied: Bool {
        locationAuthStatus == .denied || locationAuthStatus == .restricted
    }
    
    // Private state
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    /// Running total distance — updated incrementally instead of recomputing
    /// from the full GPS array every time (which is O(n) and increasingly slow).
    private var runningDistance: Double = 0
    private var lastGPSPoint: GPSPoint?
    private var latestLiveGPSPoint: GPSPoint?

    /// Rolling buffer of the last N raw GPS speeds (m/s).
    /// We feed the *smoothed* mean to the jump detector to suppress noise
    /// from CLLocation.speed (which can swing ±1–3 m/s between fixes).
    /// Raw speeds are still preserved on Session.gpsPoints for max/avg stats.
    private var speedSmoothingBuffer: [Double] = []
    private let speedSmoothingWindow = 5

    /// Speed (m/s) below which the rider is treated as stationary: the displayed
    /// current speed is forced to 0 and the session max-speed is NOT advanced.
    /// This kills GPS jitter that otherwise "fakes" a few km/h while standing
    /// still (e.g. the 3.9 km/h max seen while the watch sat on a table).
    /// ≈ 5.4 km/h — far below any real kitesurf riding speed, so genuine motion
    /// is never clipped.
    private let stationarySpeedThreshold = 1.5
    private let liveFallbackCoordinate = (lat: 0.0, lng: 0.0)

    // MARK: - Watch Ingest upload state (all accessed on main thread only)
    private let uploadState = LiveSessionUploadState()
    private var liveEndInFlightSessionIds = Set<String>()
    private var finalizedLiveSessionIds = Set<String>()
    private var liveEndRetryCounts: [String: Int] = [:]
    /// session id → diagnostic .kslog URL for sessions queued for cloud upload,
    /// so an offline upload can still attach the log when it flushes on reconnect.
    private var pendingUploadLogURLs: [String: URL] = [:]
    /// session ids whose log upload is in-flight or already succeeded — dedups the
    /// log upload across the live-finalize handler, the workout callback and the
    /// reconnect flush (all of which may fire for the same session).
    private var logUploadInFlightOrDone = Set<String>()
    private var activeDetectionEngine: DetectionEngine = .v11Buffered
    private var recordingPipelineStarted = false
    private var motionPipelineStarted = false
    private var lastPipelineWarningSignature = ""
    private var lastPipelineWarningT = -Double.infinity
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "com.kiters.network-monitor")

    /// Read from UserDefaults so the user's Settings selection takes effect
    /// at the next session start (no need to restart the app).
    private var detectionMode: DetectionMode {
        let raw = UserDefaults.standard.string(forKey: "detectionMode") ?? DetectionMode.standard.rawValue
        return DetectionMode(rawValue: raw) ?? .standard
    }

    /// Selected jump-detection engine. Read at session start so the user's
    /// Settings choice takes effect on the next session (no app restart).
    private var detectionEngine: DetectionEngine {
        let raw = UserDefaults.standard.string(forKey: "detectionEngine") ?? DetectionEngine.v16BigAir.rawValue
        return DetectionEngine(rawValue: raw) ?? .v16BigAir
    }
    
    init() {
        setupCallbacks()
        observeManagers()
        startNetworkMonitoring()
        flushPendingCloudUploads()
    }
    
    // MARK: - Launch Permissions
    
    /// Called from a .task{} at launch (runs async, never blocks the main thread).
    /// Waits for the home screen to render before showing any permission dialogs.
    func requestPermissionsOnLaunch() async {
        // Small delay so the home screen fully renders before any dialog appears.
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
        
        await MainActor.run {
            // Log current permission states before requesting
            print("━━━━━━━━━━ PERMISSION STATUS AT LAUNCH ━━━━━━━━━━")
            print("📍 Location: raw=\(locationAuthStatus.rawValue) (0=notDet,1=restricted,2=denied,3=always,4=whenInUse)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            
            // 1. Location permission
            if locationAuthStatus == .notDetermined && !permissionRequested {
                permissionRequested = true
                locationManager.requestPermission()
                print("📍 Location permission requested")
            } else {
                print("📍 Location already determined — skipping request")
            }
            // 2. HealthKit permission (shows its own system dialog)
            workoutManager.requestAuthorization()
        }
    }
    
    // MARK: - Setup
    
    private func setupCallbacks() {
        sensorProvider.onEvent = { [weak self] event in
            self?.handleSensorProviderEvent(event)
        }
        
        // Jump detection callbacks (re-wired whenever the detector is swapped).
        wireJumpDetectorCallbacks()
    }

    /// Wires the jump-detector callbacks. Called again after the detector is
    /// (re)created at session start, since the engine can change between sessions.
    private func wireJumpDetectorCallbacks() {
        jumpDetector.onJumpDetected = { [weak self] jump in
            self?.handleJumpDetected(jump)
        }

        jumpDetector.onStateChanged = { [weak self] newState in
            DispatchQueue.main.async {
                self?.jumpDetectionState = newState
            }
        }

        // V14 drives the absolute altimeter on demand: the engine opens the
        // window at takeoff and closes it after the landing baseline settles.
        if let v14 = jumpDetector as? JumpDetectorV14 {
            v14.onAbsoluteAltitudeWindowChange = { [weak self] open, reason in
                if open {
                    self?.sensorProvider.beginAbsoluteAltitudeWindow(reason: reason)
                } else {
                    self?.sensorProvider.endAbsoluteAltitudeWindow(reason: reason)
                }
            }
        }

        // v9 and v12 emit a fast first jump, then refine it in place once their
        // later baseline/drift check settles. Other engines are untouched.
        if let v9 = jumpDetector as? JumpDetectorV9 {
            v9.onJumpUpdated = { [weak self] jump in
                self?.handleJumpUpdated(jump)
            }
            v9.onJumpRetracted = { [weak self] jumpId in
                self?.handleJumpRetracted(jumpId)
            }
        }

        if let v12 = jumpDetector as? JumpDetectorV12 {
            v12.onJumpUpdated = { [weak self] jump in
                self?.handleJumpUpdated(jump)
            }
            v12.onJumpRetracted = { [weak self] jumpId in
                self?.handleJumpRetracted(jumpId)
            }
        }
    }
    
    private func observeManagers() {
        // Location authorization
        locationManager.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                self.locationAuthStatus = status
                if status != .notDetermined {
                    self.permissionRequested = false
                }
                print("📍 SessionManager: auth status = \(status.rawValue)")
            }
            .store(in: &cancellables)
        
        // Location permission denied
        locationManager.$permissionDenied
            .receive(on: DispatchQueue.main)
            .sink { [weak self] denied in
                self?.locationDenied = denied
            }
            .store(in: &cancellables)
        
        // Heart rate from WorkoutManager
        workoutManager.$heartRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bpm in
                self?.heartRate = bpm
            }
            .store(in: &cancellables)
        
        // Active calories from WorkoutManager
        workoutManager.$activeCalories
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cal in
                self?.activeCalories = cal
            }
            .store(in: &cancellables)

        workoutManager.$isActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self = self else { return }
                guard active, self.isRecording, !self.isPaused else { return }
                if self.motionPipelineStarted {
                    self.sensorProvider.upgradeMotionToBatchedIfAvailable()
                } else {
                    self.startMotionPipelineIfNeeded(preferBatched: true, reason: "workout-running")
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Permission
    
    func requestLocationPermission() {
        guard !permissionRequested else {
            print("⚠️ SessionManager: permission already requested")
            return
        }
        permissionRequested = true
        locationManager.requestPermission()
    }

    /// Warm up GPS while the Home screen is in the foreground so a session can
    /// start with an immediate fix and the user sees live signal quality.
    /// No-op when not authorized or when a session is already recording.
    func prewarmGPS() {
        guard !isRecording else { return }
        sensorProvider.prewarmLocation()
    }

    /// Stop the Home-screen GPS warm-up (e.g. when backgrounded). Never affects
    /// an active session — the LocationManager guards on session ownership.
    func stopGPSPrewarm() {
        sensorProvider.stopLocationPrewarm()
        // If no session is running, reset the transient signal indicator.
        if !isRecording {
            isGPSActive = false
            gpsSignalQuality = .none
        }
    }

    // MARK: - Session Control
    
    /// `engineOverride` bypasses the Settings engine for this session only —
    /// the Home "sensor recording" button passes `.sensorRecorder` so a pure
    /// capture session never depends on (or changes) the user's engine choice.
    func startSession(sport: Sport, engineOverride: DetectionEngine? = nil) {
        guard currentSession == nil else {
            print("⚠️ Session already active")
            return
        }

        print("━━━━━━━━━━ STARTING SESSION ━━━━━━━━━━")
        print("🏄 Sport: \(sport.displayName)")
        print("📍 Location auth: \(locationAuthStatus.rawValue) (2=whenInUse, 3=always, 4=denied)")
        print("🎯 Motion available: \(motionManager.isDeviceMotionAvailable)")
        print("💪 HealthKit active: \(workoutManager.isActive)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // Create session synchronously on the calling thread (already main via button tap),
        // then publish all state changes at once so sensors can start with a live session.
        let newSession = Session(sport: sport)
        currentSession = newSession
        isRecording = true
        isPaused = false
        setFrontmostTimeoutExtended(true, reason: "session-start")
        jumpCount = 0
        distance = 0
        maxSpeed = 0
        currentSpeed = 0
        duration = 0
        gpsPointCount = 0
        isGPSActive = false
        lastGPSAccuracy = 0
        gpsSignalQuality = .none
        pendingCloudUpload = nil
        sessionNotice = nil
        newBestJumpPresentation = nil
        runningDistance = 0
        lastGPSPoint = nil
        speedSmoothingBuffer.removeAll(keepingCapacity: true)
        recordingPipelineStarted = false
        motionPipelineStarted = false
        lastPipelineWarningSignature = ""
        lastPipelineWarningT = -Double.infinity
        
        // Reset jump detector before sensors start streaming so the first IMU
        // samples belong to the new live session. The engine is (re)selected
        // here from the user's Settings choice and its callbacks re-wired.
        let mode = detectionMode
        let requestedEngine = engineOverride ?? detectionEngine
        let selection = makeJumpDetector(for: requestedEngine)
        activeDetectionEngine = selection.engine
        jumpDetector = selection.detector
        if selection.engine == .v13Pure {
            V13CalculationLogService.shared.beginSession(
                sessionID: newSession.id,
                t: ProcessInfo.processInfo.systemUptime
            )
        } else {
            V13CalculationLogService.shared.detachSink()
        }
        if let fallbackReason = selection.fallbackReason {
            sessionNotice = SessionUserNotice(
                titleKey: "session.v12_unavailable_title",
                messageKey: "session.v12_unavailable_message"
            )
            print("🦘 \(requestedEngine.displayName) unavailable — falling back to \(selection.engine.displayName): \(fallbackReason)")
        }
        wireJumpDetectorCallbacks()
        jumpDetector.sessionId = newSession.id
        jumpDetector.reset(mode: mode)
        print("🦘 Jump detector reset — requested: \(requestedEngine.displayName), active: \(selection.engine.displayName), mode: \(mode.displayName)")

        // Open diagnostics immediately. Jump detection is sensor-only, so short
        // no-GPS live sessions must still produce a .kslog trail.
        startRecordingPipelineIfReady(session: newSession)
        if let fallbackReason = selection.fallbackReason {
            sessionLogger.logEvent("Jump engine fallback: requested=\(requestedEngine.rawValue) active=\(selection.engine.rawValue) reason=\(fallbackReason)")
        }

        // Reset cloud upload state for the new session
        uploadState.reset(sessionId: newSession.id)
        startLiveSessionIfNeeded(session: newSession, coordinate: liveStartCoordinate(for: newSession), reason: "session-start")

        // Start services AFTER session and detector state are ready. V12/V13
        // start sensors immediately; other engines wait briefly for the workout path.
        print("💪 Starting workout (if available)...")
        workoutManager.startWorkout(sport: sport)

        print("📍 Starting location tracking...")
        sensorProvider.start()

        if activeDetectionEngine == .v12AppleSensorFusion || activeDetectionEngine == .v13Pure
            || activeDetectionEngine == .v14Hybrid || activeDetectionEngine == .v15Clean
            || activeDetectionEngine == .v16BigAir
            || activeDetectionEngine == .sensorRecorder {
            startMotionPipelineIfNeeded(preferBatched: false, reason: "\(activeDetectionEngine.rawValue)-immediate-sensor-start")
        } else {
            scheduleMotionFallbackIfWorkoutDoesNotStart()
        }
        
        // Start UI timer
        startTimer()
        print("⏱️ UI timer started")
        
        print("✅ Session started successfully!")
    }

    private func makeJumpDetector(for requestedEngine: DetectionEngine) -> (engine: DetectionEngine, detector: JumpDetecting, fallbackReason: String?) {
        switch requestedEngine {
        case .v11Buffered:
            return (.v11Buffered, JumpDetectorV11(), nil)
        case .v16BigAir:
            let readiness = JumpDetectorV16.readinessReport()
            if !readiness.isReady {
                print("🪁 V16 selected despite readiness issue; keeping V16 active: \(readiness.logDetails)")
            }
            return (.v16BigAir, JumpDetectorV16(), nil)
        case .sensorRecorder:
            return (.sensorRecorder, SensorRecordingDetector(), nil)
        case .v15Clean:
            let readiness = JumpDetectorV15.readinessReport()
            if !readiness.isReady {
                print("🦘 V15 selected despite readiness issue; keeping V15 active: \(readiness.logDetails)")
            }
            return (.v15Clean, JumpDetectorV15(), nil)
        case .v14Hybrid:
            let readiness = JumpDetectorV14.readinessReport()
            if !readiness.isReady {
                print("🦘 V14 selected despite readiness issue; keeping V14 active: \(readiness.logDetails)")
            }
            return (.v14Hybrid, JumpDetectorV14(), nil)
        case .v13Pure:
            let readiness = JumpDetectorV13.readinessReport()
            if !readiness.isReady {
                print("🦘 V13 selected despite readiness issue; keeping V13 active: \(readiness.logDetails)")
            }
            return (.v13Pure, JumpDetectorV13(), nil)
        case .v12AppleSensorFusion:
            let readiness = JumpDetectorV12.readinessReport()
            let forceV12 = UserDefaults.standard.bool(forKey: V12DebugSettings.forceEngineWhenNotReady)
            guard readiness.isReady || forceV12 else {
                return (.v11Buffered, JumpDetectorV11(), readiness.logDetails)
            }
            if !readiness.isReady {
                print("🦘 V12 forced by debug settings despite readiness: \(readiness.logDetails)")
            }
            return (.v12AppleSensorFusion, JumpDetectorV12(), nil)
        case .v10:
            return (.v10, JumpDetectorV10(), nil)
        case .v9:
            return (.v9, JumpDetectorV9(), nil)
        case .v8:
            return (.v8, JumpDetectorV8(), nil)
        case .v7:
            return (.v7, JumpDetector(), nil)
        }
    }

    private func startMotionPipelineIfNeeded(preferBatched: Bool, reason: String) {
        guard isRecording, !isPaused, !motionPipelineStarted else { return }
        motionPipelineStarted = true

        // V14 samples the absolute altimeter on demand — only inside the
        // engine's takeoff→stable-landing window. V15 and V13 are the
        // continuous single-consumer (spec P4): stream start-to-stop, no
        // watchdog restarts — every observed freeze was a competing consumer
        // or a restart-induced re-anchor, not a lack of supervision. Every
        // other (older) engine keeps the supervised continuous stream.
        let absoluteMode: MotionManager.AbsoluteAcquisitionMode
        if jumpDetector is JumpDetectorV16 {
            // V16 intentionally never consumes the absolute-altitude channel.
            // `.onDemand` leaves it off because V16 never opens a window.
            absoluteMode = .onDemand
        } else if jumpDetector is JumpDetectorV14 {
            absoluteMode = .onDemand
        } else if jumpDetector is JumpDetectorV15 {
            absoluteMode = .continuousNoWatchdog
        } else if jumpDetector is JumpDetectorV13 {
            absoluteMode = .continuousNoWatchdog
        } else {
            absoluteMode = .continuous
        }
        sensorProvider.setAbsoluteAcquisitionMode(absoluteMode)

        // V15-FIX §3 F5: bypass the shared V13 throttle setting for V15 —
        // it's calibrated for the barometer's native ~3 Hz cadence, and the
        // V13 setting (default 0.5 s / 2 Hz, user-configurable up to 1.0 s)
        // was measured cutting V15's abs stream to a fixed ~1 Hz, leaving
        // only 3–4 arc points per jump even on an otherwise-healthy channel.
        // V14's on-demand window is even shorter-lived (only takeoff→landing,
        // often well under 2 s) and was still inheriting the same throttle —
        // full rate here means more real absolute samples land inside a short
        // flight instead of falling through to the ballistic estimate.
        let absoluteIntervalOverride: Double? = (jumpDetector is JumpDetectorV15
            || jumpDetector is JumpDetectorV14) ? 0.0 : nil

        sensorProvider.startMotion(
            preferBatched: preferBatched,
            absoluteProcessingIntervalOverrideSec: absoluteIntervalOverride
        )
        print("Motion pipeline started (\(reason), batched=\(preferBatched))")
    }

    private func setFrontmostTimeoutExtended(_ enabled: Bool, reason: String) {
        WKExtension.shared().isFrontmostTimeoutExtended = enabled
        print("⌚️ Frontmost timeout extended=\(enabled) (\(reason))")
    }

    private func scheduleMotionFallbackIfWorkoutDoesNotStart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self = self else { return }
            guard self.isRecording, !self.isPaused, !self.motionPipelineStarted else { return }

            // CMBatchedSensorManager requires the workout session to be running.
            // If HealthKit is unavailable or slow to transition, keep recording
            // with the 50 Hz CMMotionManager fallback rather than losing the
            // beginning of the session.
            self.startMotionPipelineIfNeeded(preferBatched: false, reason: "workout-not-running-fallback")
        }
    }
    
    func pauseSession() {
        guard currentSession != nil, !isPaused else { return }
        
        // Pause all services
        sensorProvider.pause()
        motionPipelineStarted = false
        workoutManager.pauseWorkout()
        
        // Update session status synchronously (called from main via button)
        currentSession?.status = .paused
        isPaused = true
        if activeDetectionEngine == .v13Pure {
            V13CalculationLogService.shared.lifecycle(
                t: ProcessInfo.processInfo.systemUptime,
                action: "sessionPaused"
            )
        }
        
        // Stop timer
        timer?.invalidate()
        timer = nil
        
        print("⏸️ Session paused")
    }
    
    func resumeSession() {
        guard currentSession != nil, isPaused else { return }
        
        // Resume all services
        sensorProvider.resumeLocation()
        workoutManager.resumeWorkout()
        if workoutManager.isActive {
            startMotionPipelineIfNeeded(preferBatched: true, reason: "resume-workout-running")
        } else {
            scheduleMotionFallbackIfWorkoutDoesNotStart()
        }
        
        // Update session status synchronously (called from main via button)
        currentSession?.status = .active
        isPaused = false
        if activeDetectionEngine == .v13Pure {
            V13CalculationLogService.shared.lifecycle(
                t: ProcessInfo.processInfo.systemUptime,
                action: "sessionResumed"
            )
        }
        
        // Restart timer
        startTimer()
        
        print("▶️ Session resumed")
    }
    
    func endSession() {
        // Batch engines (v8) may detect a jump in the closing seconds. Flush them
        // synchronously and fold into currentSession (on the main thread) BEFORE the
        // session is captured below for saving. Streaming v7 returns [] (no-op).
        let finalJumps = jumpDetector.endSession()
        for jump in finalJumps { handleJumpDetected(jump) }

        guard var session = currentSession else { return }

        // Live lifecycle is independent of workout/log/local-save handling.
        // Close the server session first so a delayed HealthKit callback cannot
        // leave the backend showing this session as active.
        session.endTime = Date()
        session.status = .completed
        currentSession = session
        finishLiveSessionOnServer(session: session, showPendingPrompt: session.duration >= 60)

        // Stop all services
        sensorProvider.stop()
        motionPipelineStarted = false

        // Queue the summary only after sensor acquisition has stopped and after
        // the detector's synchronous flush above. SessionLogger.stop() then
        // drains it into the same .kslog file used by the cloud-upload flow.
        if activeDetectionEngine == .v13Pure {
            V13CalculationLogService.shared.endSession(
                t: ProcessInfo.processInfo.systemUptime,
                durationSec: session.duration,
                reportedJumpCount: session.jumps.count
            )
        }
        
        // Stop session logger only if the one-minute recording gate opened.
        let completedLogURL = recordingPipelineStarted ? sessionLogger.mostRecentLogURL() : nil
        if recordingPipelineStarted {
            sessionLogger.stop()
        }
        V13CalculationLogService.shared.detachSink()
        // Remember the log location synchronously (before the async live-finalize
        // completes) so the finalize handler can upload the .kslog too.
        if let logURL = completedLogURL { pendingUploadLogURLs[session.id] = logURL }
        
        // Stop timer
        timer?.invalidate()
        timer = nil

        // The visible recording state should not wait for HealthKit's end
        // callback. The completed Session value is captured below for save/upload.
        resetFinishedSessionState()
        
        // End workout and save
        workoutManager.endWorkout { [weak self] workout in
            guard let self = self else { return }

            if session.duration < 60 {
                self.deleteLogFile(completedLogURL)
                print("⌚️ Session discarded — shorter than 60 seconds")
                DispatchQueue.main.async {
                    self.pendingCloudUpload = nil
                    self.sessionNotice = SessionUserNotice(
                        titleKey: "session.too_short_title",
                        messageKey: "session.too_short_message"
                    )
                }
                return
            }
            
            // Save session locally
            self.storageManager.saveSession(session)
            self.storageManager.markPendingCloudUpload(sessionId: session.id)
            print("✅ Session saved: \(session.jumps.count) jumps, \(String(format: "%.2f", session.distance/1000))km")
            
            // Always present the end-of-session prompt and keep it open until the
            // user explicitly chooses (upload / keep local / discard). The session
            // is the user's decision point for cloud upload of the diagnostic log;
            // live metadata may already be on the cloud, but nothing here may
            // dismiss the prompt on the user's behalf.
            DispatchQueue.main.async {
                self.pendingCloudUpload = PendingSessionCloudUpload(session: session, logURL: completedLogURL)
            }
        }
    }

    func keepPendingSessionLocal() {
        guard let pending = pendingCloudUpload else { return }
        pendingCloudUpload = nil
        // Local-only: drop it from the cloud queue so it is not auto-uploaded later.
        storageManager.clearPendingCloudUpload(sessionId: pending.session.id)
        print("⌚️ Session kept local only: \(pending.session.id)")
    }

    /// User chose to upload. Works offline: the session stays queued and is
    /// auto-uploaded on the next reconnect (see `flushPendingCloudUploads`).
    /// Sign-in is enforced at the call site (ContentView) before this runs.
    func uploadPendingSessionToCloud() {
        guard let pending = pendingCloudUpload else { return }
        pendingCloudUpload = nil
        // Keep it in the cloud queue so a failed/offline upload is retried later.
        storageManager.markPendingCloudUpload(sessionId: pending.session.id)
        if let logURL = pending.logURL {
            pendingUploadLogURLs[pending.session.id] = logURL
        }

        finishLiveSessionOnServer(session: pending.session)
        uploadSessionLog(sessionId: pending.session.id, logURL: pending.logURL)
    }

    /// Called from the prompt when the user taps Upload but is not signed in.
    /// Keeps the session queued (it will upload once signed in + online) and
    /// surfaces a sign-in hint.
    func notifySignInRequiredForUpload() {
        guard let pending = pendingCloudUpload else { return }
        pendingCloudUpload = nil
        storageManager.markPendingCloudUpload(sessionId: pending.session.id)
        if let logURL = pending.logURL {
            pendingUploadLogURLs[pending.session.id] = logURL
        }
        sessionNotice = SessionUserNotice(
            titleKey: "session.signin_required_title",
            messageKey: "session.signin_required_message"
        )
    }

    /// Discard the just-finished local copy. The live server session is still
    /// finalized automatically by `endSession`; this only removes local storage
    /// and the diagnostic log.
    func discardPendingSession() {
        guard let pending = pendingCloudUpload else { return }
        pendingCloudUpload = nil
        storageManager.deleteSession(id: pending.session.id)
        deleteLogFile(pending.logURL)
        print("🗑️ Local session copy discarded: \(pending.session.id)")
    }

    /// Uploads the diagnostic .kslog for a session and clears it from the cloud
    /// queue on success. Idempotent per session — safe to call from the live
    /// finalize handler, the end-of-session callback, the manual prompt and the
    /// reconnect flush. On failure it stays queued for the next reconnect.
    private func uploadSessionLog(sessionId: String, logURL: URL?) {
        guard !logUploadInFlightOrDone.contains(sessionId) else { return }
        guard let logURL else {
            // No log to upload — don't keep the session queued forever for a log.
            print("☁️ No session log available for cloud upload")
            storageManager.clearPendingCloudUpload(sessionId: sessionId)
            pendingUploadLogURLs.removeValue(forKey: sessionId)
            return
        }
        logUploadInFlightOrDone.insert(sessionId)
        Task {
            do {
                let response = try await CloudSyncService.shared.uploadLog(logURL)
                let cloudPath = response.path ?? "(no path)"
                print("☁️ Session log uploaded: \(logURL.lastPathComponent) → \(cloudPath)")
                await MainActor.run {
                    self.storageManager.clearPendingCloudUpload(sessionId: sessionId)
                    self.pendingUploadLogURLs.removeValue(forKey: sessionId)
                }
            } catch {
                print("☁️ Session log upload failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.logUploadInFlightOrDone.remove(sessionId)   // allow retry on reconnect
                }
            }
        }
    }

    private func resetFinishedSessionState() {
        currentSession = nil
        isRecording = false
        isPaused = false
        setFrontmostTimeoutExtended(false, reason: "session-finished")
        jumpCount = 0
        isGPSActive = false
        gpsSignalQuality = .none
        newBestJumpPresentation = nil
        activeDetectionEngine = .v16BigAir
        motionPipelineStarted = false
    }

    private func deleteLogFile(_ url: URL?) {
        guard let url else { return }
        do {
            try FileManager.default.removeItem(at: url)
            print("🗑️ Discarded short-session log: \(url.lastPathComponent)")
        } catch {
            print("⚠️ Failed to delete short-session log: \(error.localizedDescription)")
        }
    }

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.canUploadPendingSession = path.status == .satisfied
                if self.canUploadPendingSession {
                    self.flushPendingCloudUploads()
                }
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    /// Uploads every session the user queued for the cloud (the pending queue),
    /// silently, when a connection is available. Sessions chosen "Keep Local" or
    /// "Discard" were removed from the queue, so they are skipped. A successful
    /// upload clears the session from the queue (see `finishLiveSessionOnServer`).
    private func flushPendingCloudUploads() {
        guard canUploadPendingSession, !isRecording else { return }
        let pendingIds = Set(storageManager.pendingCloudUploadSessionIds())
        guard !pendingIds.isEmpty else { return }

        let sessions = storageManager.loadAllSessions().filter { pendingIds.contains($0.id) }
        for session in sessions {
            // Skip the session currently shown in the end-of-session prompt; the
            // user hasn't chosen yet.
            if pendingCloudUpload?.session.id == session.id { continue }
            // Silent retry: don't pop the end-of-session prompt if this fails.
            finishLiveSessionOnServer(session: session, showPendingPrompt: false)
            let logURL = pendingUploadLogURLs[session.id]
                ?? sessionLogger.allLogURLs().first { $0.lastPathComponent.contains(String(session.id.prefix(8))) }
            uploadSessionLog(sessionId: session.id, logURL: logURL)
        }
    }
    
    // MARK: - Data Handling

    private func handleSensorProviderEvent(_ event: SensorProviderEvent) {
        switch event {
        case .motion(let sample):
            handleIMUSample(sample)
        case .motionBatch(let batch):
            handleIMUBatch(batch)
        case .barometer:
            // Relative altitude and pressure are carried, with their original
            // timestamp, by the following IMU sample just as before.
            break
        case .absoluteAltitude(let reading):
            handleAbsoluteAltitude(
                sensorT: reading.sensorT,
                receivedT: reading.receivedT,
                altitudeM: reading.altitudeM,
                accuracyM: reading.accuracyM,
                precisionM: reading.precisionM
            )
        case .gps(let point):
            handleGPSPoint(point)
        case .gpsBatch(let batch):
            handleGPSBatch(batch)
        case .submersion:
            // LiveSensorProvider has already placed this snapshot on the
            // MotionManager ZOH channel used by the next motion event.
            break
        case .absoluteAltitudeStreamRestart(let reason):
            jumpDetector.absoluteAltitudeStreamDidRestart(reason: reason)
        case .imuStreamRecovery(let reason):
            sessionLogger.logEvent("IMU stream recovery: \(reason)")
        case .pipelineHealth(let health):
            handleMotionPipelineHealth(health)
        case .diagnostic(_, let message):
            sessionLogger.logEvent("Sensor provider: \(message)")
        }
    }
    
    private func handleGPSPoint(_ point: GPSPoint) {
        latestLiveGPSPoint = point

        // Always reflect GPS signal quality so the Home screen can show a live
        // indicator while GPS warms up — even before a session has started.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isGPSActive = true
            self.lastGPSAccuracy = point.horizontalAccuracy
            self.gpsSignalQuality = GPSSignalQuality.from(accuracy: point.horizontalAccuracy)
        }

        // Everything below is session-recording work only. During Home-screen
        // prewarm there is no session, so we skip detector/metrics entirely
        // (and avoid polluting the speed-smoothing buffer that the session reuses).
        guard isRecording else { return }
        sessionLogger.logGPSPoint(point)

        // Smooth speed via simple moving average to remove GPS jitter
        // before feeding the detector. Buffer is bounded to N samples.
        speedSmoothingBuffer.append(point.speed)
        if speedSmoothingBuffer.count > speedSmoothingWindow {
            speedSmoothingBuffer.removeFirst()
        }
        let smoothedSpeed = speedSmoothingBuffer.reduce(0, +) / Double(speedSmoothingBuffer.count)

        // ── Feed jump detector FIRST, directly on the callback thread ──
        // This is the most latency-sensitive path: the detector must see
        // speed updates as soon as GPS delivers them, not after a main-thread
        // round-trip.  updateGPS() is thread-safe (uses os_unfair_lock).
        jumpDetector.updateGPS(
            speed: smoothedSpeed,
            altitude: point.altitude,
            latitude: point.latitude,
            longitude: point.longitude,
            course: point.course,
            horizontalAccuracy: point.horizontalAccuracy,
            timestamp: point.timestamp
        )

        // Then update UI state on main thread (non-latency-critical).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard var session = self.currentSession, session.status == .active else { return }
            
            session.gpsPoints.append(point)

            // Incremental distance — O(1) instead of O(n)
            if let prev = self.lastGPSPoint {
                let from = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                let to   = CLLocation(latitude: point.latitude, longitude: point.longitude)
                self.runningDistance += to.distance(from: from)
            }
            self.lastGPSPoint = point
            session.cachedDistance = self.runningDistance
            self.currentSession = session

            // Update UI metrics.
            // Use the *smoothed* speed with a stationary deadband so jitter
            // while standing still neither shows a phantom current speed nor
            // inflates the session max. Real riding is well above the threshold.
            self.distance = self.runningDistance
            let displaySpeed = smoothedSpeed >= self.stationarySpeedThreshold ? smoothedSpeed : 0
            self.currentSpeed = displaySpeed
            if displaySpeed > 0 {
                self.maxSpeed = max(self.maxSpeed, smoothedSpeed)
            }
            
            // GPS point count is session-scoped (signal quality / accuracy are
            // already updated unconditionally at the top of this method).
            self.gpsPointCount = session.gpsPoints.count

            self.startRecordingPipelineIfReady(session: session)
            self.handleUploadOnGPS(point, session: session)
        }
    }
    
    private func handleGPSBatch(_ batch: [GPSPoint]) {
        print("📦 GPS batch received: \(batch.count) points")
    }
    
    private func handleIMUSample(_ sample: IMUSample) {
        // DO NOT mutate Session on every sample – at 50Hz this floods the main
        // thread with struct copies and makes the UI unresponsive.
        // The IMU batch callback writes samples to storage in bulk.
        // Here we only feed the jump detector (runs on the OperationQueue background thread).
        jumpDetector.processSample(sample)
    }

    private func handleAbsoluteAltitude(sensorT: TimeInterval,
                                        receivedT: TimeInterval,
                                        altitudeM: Double,
                                        accuracyM: Double?,
                                        precisionM: Double?) {
        jumpDetector.processAbsoluteAltitude(
            sensorT: sensorT,
            receivedT: receivedT,
            altitudeM: altitudeM,
            accuracyM: accuracyM,
            precisionM: precisionM
        )
    }
    
    private func handleIMUBatch(_ batch: [IMUSample]) {
        // ── DO NOT append IMU samples to the Session struct. ──
        // At 50 Hz × 250 samples/batch, the Session struct grows by ~30KB per
        // batch (every 5 seconds).  Copy-on-write of that struct on the main
        // thread causes increasing UI lag.
        //
        // Keep one logger operation per Core Motion batch. This preserves every
        // compact raw record without allocating 200 dispatch blocks per second.
        sessionLogger.logMotionSamples(batch)
    }

    private func handleMotionPipelineHealth(_ health: MotionPipelineHealth) {
        let loggerHealth = sessionLogger.queueHealthSnapshot()
        var warnings = health.warnings
        if loggerHealth.maximumPending >= 25 {
            warnings.append("loggerQueueBacklog")
        }

        var values: [String: Double] = [
            "windowSec": health.windowSec,
            "absoluteIntervalSec": health.absoluteIntervalSec,
            "imuSourceHz": health.imuSourceHz,
            "imuProcessedHz": health.imuProcessedHz,
            "relativeAltitudeHz": health.relativeAltitudeHz,
            "absoluteAltitudeSourceHz": health.absoluteAltitudeSourceHz,
            "absoluteAltitudeProcessedHz": health.absoluteAltitudeProcessedHz,
            "waterUpdateHz": health.waterUpdateHz,
            "absoluteQueueLatencyAverageMs": health.absoluteQueueLatencyAverageMs,
            "absoluteQueueLatencyMaximumMs": health.absoluteQueueLatencyMaximumMs,
            "loggerPendingOperations": Double(loggerHealth.pending),
            "loggerMaximumPendingOperations": Double(loggerHealth.maximumPending)
        ]
        if let gap = health.imuGapSec { values["imuGapSec"] = gap }
        if let gap = health.relativeAltitudeGapSec { values["relativeAltitudeGapSec"] = gap }
        if let gap = health.absoluteAltitudeGapSec { values["absoluteAltitudeGapSec"] = gap }

        V13CalculationLogService.shared.record(V13AuditRecord(
            monotonicTime: health.timestamp,
            kind: "pipelineHealth",
            stage: "pipeline",
            action: "sensorPipelineHealth",
            decision: warnings.isEmpty ? "healthy" : "degraded",
            reason: warnings.first,
            values: values,
            labels: [
                "imuSource": health.imuSource,
                "warnings": warnings.joined(separator: ",")
            ]
        ))

        let signature = warnings.sorted().joined(separator: ",")
        guard !signature.isEmpty,
              signature != lastPipelineWarningSignature
                || health.timestamp - lastPipelineWarningT >= 60 else { return }
        lastPipelineWarningSignature = signature
        lastPipelineWarningT = health.timestamp
        sessionLogger.logEvent("Motion pipeline degraded: \(signature)")
    }
    
    private func handleJumpDetected(_ jump: Jump) {
        // Mutate Session struct on the main thread only. Run synchronously when
        // already on main so the v8 end-of-session flush lands in currentSession
        // before endSession() captures it for saving.
        let body: () -> Void = { [weak self] in
            guard let self = self else { return }
            guard var session = self.currentSession else { return }

            // V15 emits low-speed candidates so they remain visible in the
            // diagnostic log. They must not affect counts, records, or uploads.
            if jump.gpsVerified == false {
                let speed = jump.takeoffGroundSpeed
                    .map { String(format: "%.2f", $0) } ?? "n/a"
                self.sessionLogger.logEvent(
                    "JUMP excluded from session: gpsVerified=false takeoffGroundSpeed=\(speed)m/s"
                )
                print("↩️ JUMP EXCLUDED (GPS-unverified) — takeoffSpeed=\(speed)m/s")
                return
            }

            var detectedJump = jump
            detectedJump.sessionId = session.id
            let previousBest = session.jumps.map(\.height).max() ?? 0
            session.jumps.append(detectedJump)

            self.currentSession = session
            self.jumpCount = session.jumps.count
            if detectedJump.height > previousBest {
                self.newBestJumpPresentation = detectedJump
            }

            print("🎉 JUMP DETECTED! Height: \(String(format: "%.2f", jump.height))m, Airtime: \(String(format: "%.2f", jump.airtime))s")
            self.handleUploadOnJump(detectedJump)
        }

        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    /// Refinement from engines that emit a fast first result (v9/v12): replace an
    /// already-recorded jump (matched by `Jump.id`) in place. If the provisional is no longer in
    /// the session (e.g. it was pruned), the accurate jump is folded in as new so it
    /// is never lost. The live count is unchanged by an update.
    private func handleJumpUpdated(_ jump: Jump) {
        let body: () -> Void = { [weak self] in
            guard let self = self else { return }
            guard var session = self.currentSession else { return }

            guard let idx = session.jumps.firstIndex(where: { $0.id == jump.id }) else {
                self.handleJumpDetected(jump)   // provisional gone — don't lose the final
                return
            }

            var updated = jump
            updated.sessionId = session.id
            session.jumps[idx] = updated
            self.currentSession = session
            self.jumpCount = session.jumps.count

            print("🔧 JUMP REFINED! Height: \(String(format: "%.2f", updated.height))m, Airtime: \(String(format: "%.2f", updated.airtime))s")
            // Push the corrected metrics to the cloud (only records if it improves a PB).
            self.handleUploadOnJump(updated)
        }

        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    /// Remove a provisional/instant jump later rejected by a full-baseline or
    /// drift-corrected re-analysis.
    private func handleJumpRetracted(_ jumpId: String) {
        let body: () -> Void = { [weak self] in
            guard let self = self else { return }
            guard var session = self.currentSession else { return }
            guard let idx = session.jumps.firstIndex(where: { $0.id == jumpId }) else { return }

            let removed = session.jumps.remove(at: idx)
            self.currentSession = session
            self.jumpCount = session.jumps.count
            if self.newBestJumpPresentation?.id == removed.id {
                self.newBestJumpPresentation = nil
            }
            print("↩️ JUMP RETRACTED (false positive) — id=\(jumpId)")
        }

        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    func dismissNewBestJumpPresentation() {
        newBestJumpPresentation = nil
    }
    
    // MARK: - Watch Ingest Upload

    private func startRecordingPipelineIfReady(session: Session) {
        guard !recordingPipelineStarted else { return }

        recordingPipelineStarted = true
        let mode = detectionMode
        let v13Config = (jumpDetector as? JumpDetectorV13)?.effectiveConfiguration
        let v15Config = (jumpDetector as? JumpDetectorV15)?.effectiveConfiguration
        let v16Config = (jumpDetector as? JumpDetectorV16)?.effectiveConfiguration
        sessionLogger.start(
            sessionId: session.id,
            mode: mode,
            sensorOnly: true,
            engine: activeDetectionEngine,
            v13Config: v13Config,
            v15Config: v15Config
        )
        if let config = v15Config {
            // The legacy `parameters` block in the header carries v7
            // DetectionMode values that V15 never reads — log the real
            // thresholds so a session can be explained from its own log.
            sessionLogger.logEvent(
                "V15 config minRise=\(config.minRiseM)m yankOpen=\(config.yankOpenG)g "
                    + "quietStd=\(config.quietStdG)g impact=\(config.impactG)g "
                    + "floatFactor=\(config.floatFactor) minFloat=\(config.minFloatFraction) "
                    + "minAirtime=\(config.minAirtimeSec)s maxFlight=\(config.maxFlightSec)s "
                    + "taperStart=\(config.airtimeTaperStartSec)s "
                    + "gpsVerifyMinSpeed=\(config.gpsVerifyMinSpeedMS)m/s "
                    + "coldStartGrace=\(config.coldStartGraceSec)s"
            )
        }
        if let config = v16Config {
            sessionLogger.logEvent(
                "V16 config pop=\(config.popMinG)g cluster=\(config.popClusterSec)s "
                    + "lift=\(config.liftThreshMS2)m/s2 shelf=\(config.minLiftPlateauSec)s "
                    + "smooth=±\(config.liftSmoothSec)s apexPre=\(config.apexPreSec)s "
                    + "apexPost=\(config.apexPostSec)s heightScale=\(config.heightScale) "
                    + "heightOffset=\(config.heightOffsetM)m minReport=\(config.minReportM)m "
                    + "attitudeGapMax=\(config.maxAttitudeGapSec)s barometer=unused gpsGate=none"
            )
        }
        if let config = v13Config {
            V13CalculationLogService.shared.attachSink { record in
                SessionLogger.shared.logV13Audit(record)
            }
            sessionLogger.logEvent(
                "V13 config minCounted=\(config.minCountedHeightM)m "
                    + "candidateRise=\(config.candidateRiseM)m "
                    + "takeoffWindow=\(config.takeoffWindowSec)s "
                    + "landingDescent=\(config.landingDescentM)m"
            )
        }
        emitSessionStartSyncMarker()
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            sessionLogger.logEvent("Low Power Mode is ON - disable it for absolute-altitude cadence")
        }
        print("🟢 Recording diagnostics opened")
    }

    private func emitSessionStartSyncMarker() {
        sessionLogger.logSync(label: "session-start-triple-tap")
        sessionLogger.logEvent("SYNC marker: three watch haptic taps")

        for idx in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 + Double(idx) * 0.18) {
                guard self.isRecording else { return }
                WKInterfaceDevice.current().play(.click)
            }
        }
    }

    /// Called on the main thread from handleGPSPoint.
    private func handleUploadOnGPS(_ point: GPSPoint, session: Session) {
        // 1. Start: fire once per session, then retry at most every 5 s on failure.
        //    Guard prevents flooding the server when GPS fires 1 Hz and the first
        //    request hasn't returned yet (the original bug: N concurrent start calls).
        if uploadState.currentServerSessId == nil {
            startLiveSessionIfNeeded(session: session, coordinate: (lat: point.latitude, lng: point.longitude), reason: "gps")
            return
        }
        guard let sessId = uploadState.currentServerSessId else { return }

        // 2. Decimate track: one point every ~5 s
        _ = uploadState.appendTrackIfDue(now: Date(), lat: point.latitude, lng: point.longitude)

        // 3. Ping every ~10 s
        if uploadState.shouldPing(now: Date()) {
            let jcnt = session.jumps.count
            Task {
                do {
                    try await WatchSessionUploader.shared.ping(
                        sessId: sessId, lat: point.latitude, lng: point.longitude,
                        jmax: uploadState.pingBestJumpM,
                        jcnt: jcnt > 0 ? jcnt : nil
                    )
                } catch {
                    print("☁️ Ping failed: \(error.localizedDescription)")
                }
            }
        }

        // 4. Record new speed best (1 km/h threshold to avoid noise)
        let kmh = point.speed * 3.6
        if let kmh = uploadState.speedRecordIfImproved(kmh: kmh) {
            postRecord(sessId: sessId, localSessionId: session.id, speedKmh: kmh, reason: "speed")
        }

        // 5. Record distance best at coarse intervals so long-session PBs notify live.
        let distKm = self.runningDistance / 1000
        if let distKm = uploadState.distanceRecordIfImproved(distKm: distKm) {
            postRecord(sessId: sessId, localSessionId: session.id, distKm: distKm, reason: "distance")
        }
    }

    private func liveStartCoordinate(for session: Session) -> (lat: Double, lng: Double) {
        if let firstPoint = session.gpsPoints.first {
            return (firstPoint.latitude, firstPoint.longitude)
        }
        if let latestLiveGPSPoint {
            return (latestLiveGPSPoint.latitude, latestLiveGPSPoint.longitude)
        }
        return liveFallbackCoordinate
    }

    private func startLiveSessionIfNeeded(
        session: Session,
        coordinate: (lat: Double, lng: Double),
        reason: String
    ) {
        guard uploadState.currentServerSessId == nil else { return }
        let now = Date()
        guard uploadState.beginStartAttempt(
            sessionId: session.id,
            now: now,
            lat: coordinate.lat,
            lng: coordinate.lng
        ) else { return }

        let lat = coordinate.lat
        let lng = coordinate.lng
        let startedAt = session.startTime
        let localSessionId = session.id
        Task {
            do {
                let resp = try await WatchSessionUploader.shared.start(
                    lat: lat,
                    lng: lng,
                    startedAt: startedAt
                )
                let accepted = await MainActor.run { () -> Bool in
                    self.uploadState.acceptStart(sessionId: localSessionId, sessId: resp.sessId)
                }
                guard accepted else { return }
                print("☁️ Session live on server — sessId=\(resp.sessId) spot=\(resp.spot) reason=\(reason)")
                await self.flushPendingRecordsIfNeeded(sessId: resp.sessId, localSessionId: localSessionId)
            } catch {
                await MainActor.run {
                    self.uploadState.failStart(sessionId: localSessionId)
                }
                print("☁️ Session start failed (will retry): \(error.localizedDescription) reason=\(reason)")
            }
        }
    }

    private func flushPendingRecordsIfNeeded(sessId: Int, localSessionId: String) async {
        let pending = await MainActor.run {
            self.uploadState.claimPendingRecord(sessionId: localSessionId)
        }
        guard let pending else { return }

        do {
            let r = try await WatchSessionUploader.shared.record(
                sessId: sessId,
                jumpM: pending.jumpM,
                airS: pending.airS,
                speedKmh: pending.speedKmh,
                distKm: pending.distKm
            )
            if !r.broken.isEmpty { print("☁️ New all-time PB: \(r.broken.joined(separator: ", "))") }
        } catch {
            await MainActor.run {
                self.uploadState.enqueue(pending)
            }
            print("☁️ Pending record flush failed: \(error.localizedDescription)")
        }
    }

    private func postRecord(sessId: Int, localSessionId: String,
                            jumpM: Double? = nil, airS: Double? = nil,
                            speedKmh: Double? = nil, distKm: Double? = nil,
                            reason: String) {
        Task {
            do {
                let r = try await WatchSessionUploader.shared.record(
                    sessId: sessId,
                    jumpM: jumpM,
                    airS: airS,
                    speedKmh: speedKmh,
                    distKm: distKm
                )
                if !r.broken.isEmpty {
                    print("☁️ New all-time PB (\(reason)): \(r.broken.joined(separator: ", "))")
                }
            } catch {
                await MainActor.run {
                    if self.uploadState.activeSessionId == localSessionId {
                        self.uploadState.enqueue(PendingLiveRecord(
                            jumpM: jumpM,
                            airS: airS,
                            speedKmh: speedKmh,
                            distKm: distKm
                        ))
                    }
                }
                print("☁️ Record (\(reason)) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Called on the main thread from handleJumpDetected.
    private func handleUploadOnJump(_ jump: Jump) {
        guard let record = uploadState.jumpRecordIfImproved(heightM: jump.height, airS: jump.airtime) else { return }
        guard let sessId = uploadState.currentServerSessId, let localSessionId = uploadState.activeSessionId else {
            uploadState.enqueue(record)
            return
        }
        postRecord(sessId: sessId, localSessionId: localSessionId,
                   jumpM: record.jumpM, airS: record.airS, reason: "jump")
    }

    private struct CompletedSessionUploadPayload {
        let durMin: Int
        let jmax: Double
        let jcnt: Int
        let airS: Double
        let spdKmh: Int
        let distKm: Double
        let avgKmh: Double
        let track: [[Int]]
        let jData: [[String: Int]]
    }

    /// Speed retention: ground speed 1.5 s AFTER the landing over ground speed
    /// 1.0 s BEFORE the pop. 114 % means the rider landed and accelerated away,
    /// 20 % means they stopped dead; the log-287 median is 50 %, so losing half
    /// the speed is normal and a rider who holds 80 % is doing something right.
    ///
    /// ⚠️ Computed HERE, at upload, and not inside JumpEngineV16 where the rest
    /// of the per-jump diagnostics live. The engine finalises a big jump the
    /// moment `now` reaches the landing instant, so a fix 1.5 s LATER does not
    /// exist yet — the engine would silently read the speed AT touchdown
    /// instead, which is a different and much lower quantity, and one that
    /// varies with which evaluation path the jump happened to take. At session
    /// end the whole track is on hand and the number is simply correct.
    ///
    /// nil without fixes on both sides, and nil when the landing was never
    /// resolved. It is an OUTPUT: nothing may gate on it.
    private func speedRetention(for jump: Jump, in session: Session) -> Double? {
        guard !jump.hasUnresolvedAirtime, jump.endTime > jump.startTime else { return nil }
        // ±3 s, the same tolerance the engine applies to its own GPS lookups.
        func speed(near t: Date) -> Double? {
            guard let fix = session.gpsPoints.min(by: {
                abs($0.timestamp.timeIntervalSince(t)) < abs($1.timestamp.timeIntervalSince(t))
            }), abs(fix.timestamp.timeIntervalSince(t)) <= 3.0 else { return nil }
            return fix.speed
        }
        guard let before = speed(near: jump.startTime.addingTimeInterval(-1.0)),
              let after = speed(near: jump.endTime.addingTimeInterval(1.5)),
              before > 0.5 else { return nil }   // a stopped rider has no ratio
        return after / before
    }

    private func completedSessionUploadPayload(for session: Session) -> CompletedSessionUploadPayload {
        let durMin  = max(1, Int(session.duration / 60))
        let jmax    = session.jumps.map(\.height).max() ?? 0
        let jcnt    = session.jumps.count
        let airS    = session.jumps.map(\.airtime).max() ?? 0
        let spdKmh  = Int(session.maxSpeed * 3.6)
        let distKm  = session.distance / 1000
        let avgKmh  = session.avgSpeed * 3.6

        // Compact jData — one entry per jump
        let startTime = session.startTime
        let jData: [[String: Int]] = session.jumps.map { j in
            let nearestToTakeoff = session.gpsPoints.min {
                abs($0.timestamp.timeIntervalSince(j.startTime)) < abs($1.timestamp.timeIntervalSince(j.startTime))
            }
            let jumpGpsPoints = session.gpsPoints.filter {
                $0.timestamp >= j.startTime && $0.timestamp <= j.endTime
            }
            let jumpTopSpeed = jumpGpsPoints.map(\.speed).max() ?? nearestToTakeoff?.speed ?? 0
            var entry: [String: Int] = [
                "t": Int(j.startTime.timeIntervalSince(startTime)),
                "h": Int(j.height * 100),        // cm
                "a": Int(j.airtime * 10),         // tenths-sec
                "s": Int(jumpTopSpeed * 3.6),     // km/h
                "d": Int(j.jumpDistance * 10),    // dm
                "y": Int(((nearestToTakeoff?.latitude  ?? 0) * 1e4).rounded()),
                "x": Int(((nearestToTakeoff?.longitude ?? 0) * 1e4).rounded()),
            ]

            // Everything below is OPTIONAL and is emitted only when the engine
            // measured it. A phone reading an older watch's payload simply does
            // not see these keys and falls back to its previous behaviour, so
            // the key must be ABSENT rather than zero — a 0 lat/lng or a 0 %
            // speed retention would read as a measurement.
            //
            // Integers only, like the original seven. ~40 bytes a jump, ~1.2 KB
            // for a 30-jump session.

            // Drawing anchors: landing and apex positions plus the vertical
            // shape. Without them the phone draws a straight chord from the
            // track's bearing — 8.09 m of error on log 287 against 4.55 m with
            // them. The full reconstructed arc was measured too: 48x the bytes
            // and no better (5.10 m), because it carries integration noise.
            if let v = j.landingLatitude   { entry["ly"] = Int((v * 1e4).rounded()) }
            if let v = j.landingLongitude  { entry["lx"] = Int((v * 1e4).rounded()) }
            if let v = j.apexLatitude      { entry["py"] = Int((v * 1e4).rounded()) }
            if let v = j.apexLongitude     { entry["px"] = Int((v * 1e4).rounded()) }
            if let v = j.riseFraction      { entry["rf"] = Int((v * 100).rounded()) }

            // Rider diagnostics.
            if let v = j.takeoffYankG      { entry["yk"] = Int((v * 10).rounded()) }
            if let v = j.landingImpactG    { entry["lg"] = Int((v * 10).rounded()) }
            if let v = j.rotationRevs      { entry["rt"] = Int((v * 100).rounded()) }
            if let v = j.edgeLoadG         { entry["eg"] = Int((v * 100).rounded()) }
            if let v = speedRetention(for: j, in: session) {
                entry["sr"] = Int((v * 100).rounded())
            }
            return entry
        }

        var track: [[Int]] = []
        var lastT: Date?
        for pt in session.gpsPoints {
            if lastT == nil || pt.timestamp.timeIntervalSince(lastT!) >= 5 {
                let compact = [Int(pt.latitude * 1e4), Int(pt.longitude * 1e4)]
                if track.last != compact {
                    track.append(compact)
                }
                lastT = pt.timestamp
            }
        }

        return CompletedSessionUploadPayload(
            durMin: durMin,
            jmax: jmax,
            jcnt: jcnt,
            airS: airS,
            spdKmh: spdKmh,
            distKm: distKm,
            avgKmh: avgKmh,
            track: track,
            jData: jData
        )
    }

    private func finishLiveSessionOnServer(session: Session, showPendingPrompt: Bool = true) {
        let beginFinish = {
            guard !self.finalizedLiveSessionIds.contains(session.id),
                  !self.liveEndInFlightSessionIds.contains(session.id) else { return }
            self.liveEndInFlightSessionIds.insert(session.id)
            print("☁️ Live session end requested — localSessionId=\(session.id)")

            Task {
                let finished = await self.finalizeLiveSessionOnServer(session: session)
                await MainActor.run {
                    self.liveEndInFlightSessionIds.remove(session.id)
                    if finished {
                        self.finalizedLiveSessionIds.insert(session.id)
                        self.liveEndRetryCounts.removeValue(forKey: session.id)
                        // Metadata is on the cloud. Do NOT upload the log or dismiss
                        // the end-of-session prompt here — the diagnostic log is the
                        // user's choice via the prompt, which must stay open until
                        // they tap upload / keep local / discard.
                        if self.uploadState.activeSessionId == session.id {
                            self.uploadState.reset(sessionId: nil)
                        }
                    } else {
                        if showPendingPrompt {
                            self.storageManager.markPendingCloudUpload(sessionId: session.id)
                        }
                        if showPendingPrompt, self.pendingCloudUpload == nil {
                            self.pendingCloudUpload = PendingSessionCloudUpload(session: session, logURL: nil)
                        }
                        let retryCount = (self.liveEndRetryCounts[session.id] ?? 0) + 1
                        self.liveEndRetryCounts[session.id] = retryCount
                        if retryCount <= 3 {
                            let delay = min(30.0, Double(retryCount) * 5.0)
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                                self?.finishLiveSessionOnServer(session: session, showPendingPrompt: showPendingPrompt)
                            }
                            print("☁️ Live session end retry scheduled — localSessionId=\(session.id) attempt=\(retryCount + 1)")
                        }
                    }
                }
            }
        }

        if Thread.isMainThread {
            beginFinish()
        } else {
            DispatchQueue.main.async {
                beginFinish()
            }
        }
    }

    private func finalizeLiveSessionOnServer(session: Session) async -> Bool {
        let payload = completedSessionUploadPayload(for: session)
        let localSessionId = session.id
        let startCoordinate = await MainActor.run { self.liveStartCoordinate(for: session) }
        let sessId: Int

        if let current = await MainActor.run { self.uploadState.currentServerSessId } {
            sessId = current
        } else if let current = await waitForServerSessionId(localSessionId: localSessionId) {
            sessId = current
        } else {
            do {
                let started = try await WatchSessionUploader.shared.start(
                    lat: startCoordinate.lat,
                    lng: startCoordinate.lng,
                    startedAt: session.startTime
                )
                await MainActor.run {
                    _ = self.uploadState.acceptStart(sessionId: localSessionId, sessId: started.sessId)
                }
                sessId = started.sessId
                print("☁️ Session started during finalization — sessId=\(started.sessId) spot=\(started.spot)")
            } catch {
                print("☁️ Live session final start failed: \(error.localizedDescription)")
                return false
            }
        }

        await flushPendingRecordsIfNeeded(sessId: sessId, localSessionId: localSessionId)

        do {
            let finalTrack = payload.track.isEmpty
                ? [[Int(startCoordinate.lat * 1e4), Int(startCoordinate.lng * 1e4)]]
                : payload.track
            let r = try await WatchSessionUploader.shared.end(
                sessId: sessId,
                durMin: payload.durMin,
                jmax: payload.jmax,
                jcnt: payload.jcnt,
                airS: payload.airS,
                spdKmh: payload.spdKmh,
                distKm: payload.distKm,
                avgKmh: payload.avgKmh,
                track: finalTrack,
                jData: payload.jData
            )
            print("☁️ Live session ended — sessId=\(sessId) finalPBs=\(r.broken)")
            return true
        } catch {
            print("☁️ Live session end failed: \(error.localizedDescription)")
            return false
        }
    }

    private func waitForServerSessionId(localSessionId: String) async -> Int? {
        // Match the uploader's resource timeout so End can close a Start that
        // was still waiting on watch connectivity when the rider tapped stop.
        for _ in 0..<60 {
            let snapshot = await MainActor.run {
                self.uploadState.startSnapshot(sessionId: localSessionId)
            }
            guard snapshot.isCurrent else { return nil }
            if let sessId = snapshot.sessId { return sessId }
            if !snapshot.startInFlight { return nil }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return await MainActor.run {
            self.uploadState.activeSessionId == localSessionId ? self.uploadState.currentServerSessId : nil
        }
    }

    // MARK: - Metrics

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let session = self.currentSession else { return }
            DispatchQueue.main.async {
                self.duration = session.duration
            }
        }
    }
}
