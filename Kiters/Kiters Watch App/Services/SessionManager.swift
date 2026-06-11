//
//  SessionManager.swift
//  iSurf-Watch
//
//  Coordinates all services and manages active session state
//

import Foundation
import Combine
import CoreLocation
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

class SessionManager: ObservableObject {
    // Services
    private let locationManager = LocationManager()
    private let motionManager = MotionManager()
    private let workoutManager = WorkoutManager()
    private let storageManager = StorageManager()
    private let jumpDetector = JumpDetector()
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

    /// Rolling buffer of the last N raw GPS speeds (m/s).
    /// We feed the *smoothed* mean to the jump detector to suppress noise
    /// from CLLocation.speed (which can swing ±1–3 m/s between fixes).
    /// Raw speeds are still preserved on Session.gpsPoints for max/avg stats.
    private var speedSmoothingBuffer: [Double] = []
    private let speedSmoothingWindow = 5

    // MARK: - Watch Ingest upload state (all accessed on main thread only)
    private var serverSessId: Int?
    private var lastPingTime: Date?
    private var lastTrackTime: Date?
    // Tracks the last time we attempted a `start` POST so we don't fire a new
    // request on every GPS update while the first is still in flight (watchOS GPS
    // can fire 1 Hz, network round-trip is ~200 ms–1 s).
    private var lastStartAttempt: Date?
    private var trackPoints: [[Int]] = []
    private var sessionBestJumpM: Double = 0
    private var sessionBestAirS: Double = 0
    private var sessionBestSpeedKmh: Double = 0

    /// Read from UserDefaults so the user's Settings selection takes effect
    /// at the next session start (no need to restart the app).
    private var detectionMode: DetectionMode {
        let raw = UserDefaults.standard.string(forKey: "detectionMode") ?? DetectionMode.standard.rawValue
        return DetectionMode(rawValue: raw) ?? .standard
    }
    
    init() {
        setupCallbacks()
        observeManagers()
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
        // Location updates
        locationManager.onLocationUpdate = { [weak self] gpsPoint in
            self?.handleGPSPoint(gpsPoint)
        }
        
        locationManager.onLocationBatch = { [weak self] batch in
            self?.handleGPSBatch(batch)
        }
        
        // Motion updates
        motionManager.onIMUSample = { [weak self] sample in
            self?.handleIMUSample(sample)
        }
        
        motionManager.onIMUBatch = { [weak self] batch in
            self?.handleIMUBatch(batch)
        }
        
        // Jump detection
        jumpDetector.onJumpDetected = { [weak self] jump in
            self?.handleJumpDetected(jump)
        }
        
        // Jump state changes (for UI)
        jumpDetector.onStateChanged = { [weak self] newState in
            DispatchQueue.main.async {
                self?.jumpDetectionState = newState
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
    
    // MARK: - Session Control
    
    func startSession(sport: Sport) {
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
        jumpCount = 0
        distance = 0
        maxSpeed = 0
        currentSpeed = 0
        duration = 0
        gpsPointCount = 0
        isGPSActive = false
        lastGPSAccuracy = 0
        gpsSignalQuality = .none
        runningDistance = 0
        lastGPSPoint = nil
        speedSmoothingBuffer.removeAll(keepingCapacity: true)
        
        // Start all services AFTER session is published
        print("📍 Starting location tracking...")
        locationManager.startTracking()
        
        print("🎯 Starting motion tracking...")
        motionManager.startTracking()
        
        print("💪 Starting workout (if available)...")
        workoutManager.startWorkout(sport: sport)
        
        // Reset jump detector with user-selected detection mode
        let mode = detectionMode
        jumpDetector.reset(mode: mode)
        print("🦘 Jump detector reset — mode: \(mode.displayName)")

        // Reset cloud upload state for the new session
        resetUploadState()
        
        // Start session logger (CSV file for diagnostics)
        sessionLogger.start(
            sessionId: newSession.id,
            mode: mode,
            devMode: JumpDetectionConfig.shared.devMode
        )
        
        // Start UI timer
        startTimer()
        print("⏱️ UI timer started")
        
        print("✅ Session started successfully!")
    }
    
    /// Activates watchOS Water Lock when the "autoLock" setting is enabled.
    ///
    /// IMPORTANT: `enableWaterLock()` only works while the app is in the
    /// **foreground active** scene. Calling it from `startSession()` (during the
    /// button tap, before the ActiveSessionView has appeared) is the common cause
    /// of "Water Lock doesn't work on device". This is therefore invoked from
    /// `ActiveSessionView.onAppear`, where the session screen is guaranteed
    /// frontmost. The user double-presses the Digital Crown to exit Water Lock.
    func enableWaterLockIfNeeded() {
        let autoLock = UserDefaults.standard.object(forKey: "autoLock") as? Bool ?? true
        guard autoLock else {
            print("💧 Water Lock skipped (autoLock disabled)")
            return
        }
        guard isRecording else { return }
        // Small delay so the scene is fully active before locking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard self.isRecording else { return }
            WKInterfaceDevice.current().enableWaterLock()
            print("💧 Water Lock enabled")
        }
    }
    
    func pauseSession() {
        guard currentSession != nil, !isPaused else { return }
        
        // Pause all services
        locationManager.pauseTracking()
        motionManager.pauseTracking()
        workoutManager.pauseWorkout()
        
        // Update session status synchronously (called from main via button)
        currentSession?.status = .paused
        isPaused = true
        
        // Stop timer
        timer?.invalidate()
        timer = nil
        
        print("⏸️ Session paused")
    }
    
    func resumeSession() {
        guard currentSession != nil, isPaused else { return }
        
        // Resume all services
        locationManager.resumeTracking()
        motionManager.resumeTracking()
        workoutManager.resumeWorkout()
        
        // Update session status synchronously (called from main via button)
        currentSession?.status = .active
        isPaused = false
        
        // Restart timer
        startTimer()
        
        print("▶️ Session resumed")
    }
    
    func endSession() {
        guard var session = currentSession else { return }
        
        // Stop all services
        locationManager.stopTracking()
        motionManager.stopTracking()
        
        // Stop session logger
        sessionLogger.stop()
        uploadMostRecentLogToCloud()
        
        // Stop timer
        timer?.invalidate()
        timer = nil
        
        // End workout and save
        workoutManager.endWorkout { [weak self] workout in
            guard let self = self else { return }
            
            // Update session
            session.endTime = Date()
            session.status = .completed
            
            // Save session locally
            self.storageManager.saveSession(session)
            print("✅ Session saved: \(session.jumps.count) jumps, \(String(format: "%.2f", session.distance/1000))km")

            // Upload final session to server
            self.uploadSessionEnd(session: session)
            
            // Reset state on main thread
            DispatchQueue.main.async {
                self.currentSession = nil
                self.isRecording = false
                self.isPaused = false
                self.jumpCount = 0
                self.isGPSActive = false
                self.gpsSignalQuality = .none
            }
        }
    }

    private func uploadMostRecentLogToCloud() {
        guard let logURL = sessionLogger.mostRecentLogURL() else {
            print("☁️ No session log available for cloud upload")
            return
        }

        Task {
            do {
                let response = try await CloudSyncService.shared.uploadLog(logURL)
                let cloudPath = response.path ?? "(no path)"
                print("☁️ Session log uploaded: \(logURL.lastPathComponent) → \(cloudPath)")
            } catch {
                print("☁️ Session log upload failed: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Data Handling
    
    private func handleGPSPoint(_ point: GPSPoint) {
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

            // Update UI metrics
            self.distance = self.runningDistance
            self.maxSpeed = max(self.maxSpeed, point.speed)
            self.currentSpeed = point.speed
            
            // Update GPS tracking state
            self.gpsPointCount = session.gpsPoints.count
            self.isGPSActive = true
            self.lastGPSAccuracy = point.horizontalAccuracy
            self.gpsSignalQuality = GPSSignalQuality.from(accuracy: point.horizontalAccuracy)

            // Wire upload: start / ping / track / speed-record
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
    
    private func handleIMUBatch(_ batch: [IMUSample]) {
        // ── DO NOT append IMU samples to the Session struct. ──
        // At 50 Hz × 250 samples/batch, the Session struct grows by ~30KB per
        // batch (every 5 seconds).  Copy-on-write of that struct on the main
        // thread causes increasing UI lag.
        //
        // All raw sensor data is already being written to the CSV log by
        // SessionLogger.  Jump-specific samples are captured in Jump.imuSamples.
        // There is no need to keep a second copy inside Session.
    }
    
    private func handleJumpDetected(_ jump: Jump) {
        // Mutate Session struct on main thread only.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard var session = self.currentSession else { return }
            
            var detectedJump = jump
            detectedJump.sessionId = session.id
            session.jumps.append(detectedJump)
            
            self.currentSession = session
            self.jumpCount = session.jumps.count

            print("🎉 JUMP DETECTED! Height: \(String(format: "%.2f", jump.height))m, Airtime: \(String(format: "%.2f", jump.airtime))s")

            // Wire upload: record new session-best jump/air
            self.handleUploadOnJump(detectedJump)
        }
    }
    
    // MARK: - Watch Ingest Upload

    private func resetUploadState() {
        serverSessId        = nil
        lastPingTime        = nil
        lastTrackTime       = nil
        lastStartAttempt    = nil
        trackPoints         = []
        sessionBestJumpM    = 0
        sessionBestAirS     = 0
        sessionBestSpeedKmh = 0
    }

    /// Called on the main thread from handleGPSPoint.
    private func handleUploadOnGPS(_ point: GPSPoint, session: Session) {
        // 1. Start: fire once per session, then retry at most every 5 s on failure.
        //    Guard prevents flooding the server when GPS fires 1 Hz and the first
        //    request hasn't returned yet (the original bug: N concurrent start calls).
        if serverSessId == nil {
            let now = Date()
            let retryDelay: TimeInterval = 5
            if let last = lastStartAttempt, now.timeIntervalSince(last) < retryDelay { return }
            lastStartAttempt = now
            lastPingTime  = now
            lastTrackTime = now
            trackPoints.append([Int(point.latitude * 1e4), Int(point.longitude * 1e4)])
            let lat = point.latitude, lng = point.longitude, startedAt = session.startTime
            Task {
                do {
                    let resp = try await WatchSessionUploader.shared.start(
                        lat: lat, lng: lng, startedAt: startedAt
                    )
                    await MainActor.run { self.serverSessId = resp.sessId }
                    print("☁️ Session live on server — sessId=\(resp.sessId) spot=\(resp.spot)")
                } catch {
                    print("☁️ Session start failed (will retry): \(error.localizedDescription)")
                }
            }
            return
        }
        guard let sessId = serverSessId else { return }

        // 2. Decimate track: one point every ~5 s
        if let last = lastTrackTime, Date().timeIntervalSince(last) >= 5 {
            trackPoints.append([Int(point.latitude * 1e4), Int(point.longitude * 1e4)])
            lastTrackTime = Date()
        }

        // 3. Ping every ~10 s
        if let last = lastPingTime, Date().timeIntervalSince(last) >= 10 {
            let jmax = sessionBestJumpM
            let jcnt = session.jumps.count
            lastPingTime = Date()
            Task {
                do {
                    try await WatchSessionUploader.shared.ping(
                        sessId: sessId, lat: point.latitude, lng: point.longitude,
                        jmax: jmax > 0 ? jmax : nil,
                        jcnt: jcnt > 0 ? jcnt : nil
                    )
                } catch {
                    print("☁️ Ping failed: \(error.localizedDescription)")
                }
            }
        }

        // 4. Record new speed best (1 km/h threshold to avoid noise)
        let kmh = point.speed * 3.6
        if kmh > sessionBestSpeedKmh + 1 {
            sessionBestSpeedKmh = kmh
            Task {
                do {
                    let r = try await WatchSessionUploader.shared.record(sessId: sessId, speedKmh: kmh)
                    if !r.broken.isEmpty { print("☁️ New all-time speed PB: \(String(format:"%.1f",kmh)) km/h") }
                } catch {
                    print("☁️ Record (speed) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Called on the main thread from handleJumpDetected.
    private func handleUploadOnJump(_ jump: Jump) {
        guard let sessId = serverSessId else { return }
        let jumpBetter = jump.height  > sessionBestJumpM
        let airBetter  = jump.airtime > sessionBestAirS
        guard jumpBetter || airBetter else { return }
        if jumpBetter { sessionBestJumpM = jump.height  }
        if airBetter  { sessionBestAirS  = jump.airtime }
        Task {
            do {
                let r = try await WatchSessionUploader.shared.record(
                    sessId: sessId,
                    jumpM: jumpBetter ? jump.height  : nil,
                    airS:  airBetter  ? jump.airtime : nil
                )
                if !r.broken.isEmpty { print("☁️ New all-time PB: \(r.broken.joined(separator: ", "))") }
            } catch {
                print("☁️ Record (jump) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Called after the session is saved locally. Fires the `end` ingest call.
    private func uploadSessionEnd(session: Session) {
        guard let sessId = serverSessId else {
            print("☁️ Skip end upload — session never started on server (no GPS?)")
            return
        }
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
            let nearest = session.gpsPoints.min {
                abs($0.timestamp.timeIntervalSince(j.startTime)) < abs($1.timestamp.timeIntervalSince(j.startTime))
            }
            return [
                "t": Int(j.startTime.timeIntervalSince(startTime)),
                "h": Int(j.height * 100),        // cm
                "a": Int(j.airtime * 10),         // tenths-sec
                "s": Int((nearest?.speed ?? 0) * 3.6), // km/h
                "d": Int(j.jumpDistance * 10),    // dm
                "y": Int((nearest?.latitude  ?? 0) * 1e4),
                "x": Int((nearest?.longitude ?? 0) * 1e4),
            ]
        }

        // Fall back to building track from gpsPoints if nothing was collected live
        let track: [[Int]]
        if !trackPoints.isEmpty {
            track = trackPoints
        } else {
            var pts: [[Int]] = []; var lastT: Date? = nil
            for pt in session.gpsPoints {
                if lastT == nil || pt.timestamp.timeIntervalSince(lastT!) >= 5 {
                    pts.append([Int(pt.latitude * 1e4), Int(pt.longitude * 1e4)])
                    lastT = pt.timestamp
                }
            }
            track = pts.isEmpty ? [[0, 0]] : pts
        }

        Task {
            do {
                let r = try await WatchSessionUploader.shared.end(
                    sessId: sessId, durMin: durMin,
                    jmax: jmax, jcnt: jcnt, airS: airS,
                    spdKmh: spdKmh, distKm: distKm, avgKmh: avgKmh,
                    track: track, jData: jData
                )
                print("☁️ Session uploaded — sessId=\(sessId) finalPBs=\(r.broken)")
            } catch {
                print("☁️ Session end upload failed: \(error.localizedDescription)")
            }
            await MainActor.run { self.serverSessId = nil }
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
