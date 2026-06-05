# 03 - watchOS App Implementation

## Overview

The watchOS app is the **primary data collection device**. It runs natively using Swift and SwiftUI, leveraging CoreMotion for IMU data and CoreLocation for GPS tracking.

## Project Setup

### Create Xcode Project

1. Open Xcode → New Project
2. Select **watchOS** → **App**
3. Name: `iSurf-Watch`
4. Interface: **SwiftUI**
5. Language: **Swift**
6. Deployment target: **watchOS 9.0+**

### Configure Capabilities

In Xcode project settings, enable:

**Capabilities Tab**:
- [ ] Background Modes
  - Location updates
  - Workout processing
- [ ] HealthKit
- [ ] Location (When In Use)

**Info.plist**:
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>iSurf tracks your location during surf sessions to map your route and calculate speed.</string>

<key>NSMotionUsageDescription</key>
<string>iSurf uses motion sensors to detect jumps and measure airtime.</string>

<key>UIBackgroundModes</key>
<array>
    <string>location</string>
    <string>workout-processing</string>
</array>
```

## Core Architecture

### App Structure

```swift
// iSurfApp.swift
import SwiftUI

@main
struct iSurfApp: App {
    @StateObject private var workoutManager = WorkoutManager.shared
    @StateObject private var connectivityManager = WatchConnectivityManager.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workoutManager)
                .environmentObject(connectivityManager)
        }
    }
}
```

### Main View

```swift
// ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @State private var showingSummary = false
    
    var body: some View {
        if workoutManager.isSessionActive {
            SessionView()
        } else if showingSummary, let lastSession = workoutManager.lastSession {
            SummaryView(session: lastSession)
                .onDisappear { showingSummary = false }
        } else {
            StartView(onStart: startSession)
        }
    }
    
    private func startSession() {
        Task {
            await workoutManager.startSession(sport: .kiteboarding)
        }
    }
}
```

## Location Manager

### CoreLocation Setup

```swift
// Services/LocationManager.swift
import CoreLocation
import Combine

@MainActor
class LocationManager: NSObject, ObservableObject {
    private let locationManager = CLLocationManager()
    
    @Published var currentLocation: CLLocation?
    @Published var currentSpeed: Double = 0 // m/s
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    private var locationBuffer: [GPSPoint] = []
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5.0 // meters
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = false
    }
    
    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }
    
    func startTracking() {
        locationManager.startUpdatingLocation()
    }
    
    func stopTracking() {
        locationManager.stopUpdatingLocation()
        flushBuffer()
    }
    
    private func flushBuffer() {
        guard !locationBuffer.isEmpty else { return }
        // Save to session store
        SessionStore.shared.appendGPSPoints(locationBuffer)
        locationBuffer.removeAll()
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        currentLocation = location
        currentSpeed = max(0, location.speed) // Filter invalid negative speeds
        
        let gpsPoint = GPSPoint(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            speed: location.speed,
            course: location.course,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy
        )
        
        locationBuffer.append(gpsPoint)
        
        // Flush buffer every 10 points (~10 seconds at 1Hz)
        if locationBuffer.count >= 10 {
            flushBuffer()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        authorizationStatus = status
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}
```

## Motion Manager

### CoreMotion IMU Collection

```swift
// Services/MotionManager.swift
import CoreMotion
import Combine

@MainActor
class MotionManager: ObservableObject {
    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    
    @Published var currentAcceleration: CMAcceleration?
    @Published var currentRotationRate: CMRotationRate?
    
    private var imuBuffer: [IMUSample] = []
    private let samplingRate: Double = 50.0 // Hz
    
    init() {
        queue.name = "com.isurf.motion"
        queue.maxConcurrentOperationCount = 1
    }
    
    func startTracking() {
        guard motionManager.isDeviceMotionAvailable else {
            print("Device motion not available")
            return
        }
        
        motionManager.deviceMotionUpdateInterval = 1.0 / samplingRate
        
        motionManager.startDeviceMotionUpdates(
            using: .xMagneticNorthZVertical,
            to: queue
        ) { [weak self] motion, error in
            guard let self = self, let motion = motion else { return }
            
            Task { @MainActor in
                self.processMotionUpdate(motion)
            }
        }
    }
    
    func stopTracking() {
        motionManager.stopDeviceMotionUpdates()
        flushBuffer()
    }
    
    private func processMotionUpdate(_ motion: CMDeviceMotion) {
        currentAcceleration = motion.userAcceleration
        currentRotationRate = motion.rotationRate
        
        let sample = IMUSample(
            timestamp: Date(),
            accelerationX: motion.userAcceleration.x,
            accelerationY: motion.userAcceleration.y,
            accelerationZ: motion.userAcceleration.z,
            rotationX: motion.rotationRate.x,
            rotationY: motion.rotationRate.y,
            rotationZ: motion.rotationRate.z,
            pitch: motion.attitude.pitch,
            roll: motion.attitude.roll,
            yaw: motion.attitude.yaw
        )
        
        imuBuffer.append(sample)
        
        // Process jump detection in real-time
        JumpDetector.shared.processSample(sample)
        
        // Flush buffer every 100 samples (~2 seconds at 50Hz)
        if imuBuffer.count >= 100 {
            flushBuffer()
        }
    }
    
    private func flushBuffer() {
        guard !imuBuffer.isEmpty else { return }
        // Only save IMU data during detected jumps (to save storage)
        SessionStore.shared.appendIMUSamples(imuBuffer)
        imuBuffer.removeAll()
    }
}
```

## Workout Manager

### HealthKit Workout Session

```swift
// Services/WorkoutManager.swift
import HealthKit
import Combine

@MainActor
class WorkoutManager: ObservableObject {
    static let shared = WorkoutManager()
    
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    
    @Published var isSessionActive = false
    @Published var currentSession: Session?
    @Published var lastSession: Session?
    
    private let locationManager = LocationManager()
    private let motionManager = MotionManager()
    private let jumpDetector = JumpDetector.shared
    
    @Published var metrics = SessionMetrics()
    
    private init() {
        requestHealthKitPermission()
    }
    
    private func requestHealthKitPermission() {
        let typesToShare: Set = [
            HKQuantityType.workoutType()
        ]
        
        healthStore.requestAuthorization(toShare: typesToShare, read: []) { success, error in
            if let error = error {
                print("HealthKit authorization error: \(error)")
            }
        }
    }
    
    func startSession(sport: Sport) async {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .surfingSports
        configuration.locationType = .outdoor
        
        do {
            session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            builder = session?.associatedWorkoutBuilder()
            
            session?.delegate = self
            builder?.delegate = self
            
            builder?.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            
            // Start session
            let startDate = Date()
            session?.startActivity(with: startDate)
            try await builder?.beginCollection(withStart: startDate)
            
            // Initialize new session
            currentSession = Session(
                id: UUID().uuidString,
                sport: sport,
                startTime: startDate
            )
            
            // Start sensors
            locationManager.startTracking()
            motionManager.startTracking()
            jumpDetector.reset()
            
            isSessionActive = true
            
        } catch {
            print("Failed to start workout: \(error)")
        }
    }
    
    func pauseSession() {
        session?.pause()
        locationManager.stopTracking()
        motionManager.stopTracking()
    }
    
    func resumeSession() {
        session?.resume()
        locationManager.startTracking()
        motionManager.startTracking()
    }
    
    func stopSession() async {
        guard let session = session, let builder = builder else { return }
        
        // Stop sensors
        locationManager.stopTracking()
        motionManager.stopTracking()
        
        // End workout
        let endDate = Date()
        session.end()
        
        do {
            try await builder.endCollection(withEnd: endDate)
            let workout = try await builder.finishWorkout()
            
            // Finalize session
            currentSession?.endTime = endDate
            currentSession?.summary = calculateSummary()
            currentSession?.jumps = jumpDetector.detectedJumps
            
            // Save session
            if let finalSession = currentSession {
                SessionStore.shared.saveSession(finalSession)
                lastSession = finalSession
                
                // Transfer to phone
                WatchConnectivityManager.shared.sendSession(finalSession)
            }
            
            currentSession = nil
            isSessionActive = false
            
        } catch {
            print("Failed to end workout: \(error)")
        }
    }
    
    private func calculateSummary() -> SessionSummary {
        let gpsPoints = SessionStore.shared.getGPSPoints()
        
        let distance = calculateDistance(from: gpsPoints)
        let duration = (currentSession?.endTime?.timeIntervalSince(currentSession?.startTime ?? Date()) ?? 0)
        let speeds = gpsPoints.compactMap { $0.speed > 0 ? $0.speed : nil }
        
        return SessionSummary(
            distance: distance / 1000.0, // Convert to km
            duration: duration,
            maxSpeed: (speeds.max() ?? 0) * 3.6, // Convert m/s to km/h
            avgSpeed: (speeds.reduce(0, +) / Double(speeds.count)) * 3.6,
            jumpCount: jumpDetector.detectedJumps.count,
            maxJumpHeight: jumpDetector.detectedJumps.map(\.height).max() ?? 0,
            totalAirtime: jumpDetector.detectedJumps.map(\.airtime).reduce(0, +)
        )
    }
    
    private func calculateDistance(from points: [GPSPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        
        var totalDistance: Double = 0
        for i in 1..<points.count {
            let loc1 = CLLocation(
                latitude: points[i-1].latitude,
                longitude: points[i-1].longitude
            )
            let loc2 = CLLocation(
                latitude: points[i].latitude,
                longitude: points[i].longitude
            )
            totalDistance += loc1.distance(from: loc2)
        }
        return totalDistance
    }
}

// MARK: - HKWorkoutSessionDelegate
extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        // Handle state changes
    }
    
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("Workout session error: \(error)")
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate
extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // Handle collected data
    }
    
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Handle workout events
    }
}
```

## Watch Connectivity

### Communication with iPhone

```swift
// Services/WatchConnectivityManager.swift
import WatchConnectivity

@MainActor
class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()
    
    @Published var isReachable = false
    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    
    private override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }
    
    // Send live updates during session
    func sendLiveUpdate(metrics: SessionMetrics) {
        guard let session = session, session.isReachable else { return }
        
        let message: [String: Any] = [
            "type": "live_update",
            "speed": metrics.currentSpeed,
            "jumpCount": metrics.jumpCount,
            "distance": metrics.distance,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        session.sendMessage(message, replyHandler: nil) { error in
            print("Live update error: \(error)")
        }
    }
    
    // Transfer completed session
    func sendSession(_ session: Session) {
        guard let wcSession = self.session else { return }
        
        do {
            // Save session to temporary file
            let fileURL = try SessionStore.shared.exportSessionFile(session)
            
            // Transfer file
            wcSession.transferFile(fileURL, metadata: [
                "sessionId": session.id,
                "timestamp": session.startTime.timeIntervalSince1970
            ])
            
            print("Session transfer initiated: \(session.id)")
            
        } catch {
            print("Session transfer error: \(error)")
        }
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error = error {
                print("WCSession activation error: \(error)")
            }
        }
    }
    
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
        }
    }
    
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        // Handle messages from iPhone (e.g., settings sync)
    }
}
```

## Session UI

### Active Session View

```swift
// Views/SessionView.swift
import SwiftUI

struct SessionView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @State private var showingEndConfirmation = false
    
    var body: some View {
        VStack(spacing: 12) {
            // Speed gauge
            VStack {
                Text("\(Int(workoutManager.metrics.currentSpeed * 3.6))")
                    .font(.system(size: 48, weight: .bold))
                Text("km/h")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Stats grid
            HStack(spacing: 20) {
                StatView(title: "Jumps", value: "\(workoutManager.metrics.jumpCount)")
                StatView(title: "Time", value: formatDuration(workoutManager.metrics.duration))
            }
            
            // Controls
            HStack(spacing: 20) {
                Button(action: { workoutManager.pauseSession() }) {
                    Image(systemName: "pause.fill")
                        .font(.title2)
                }
                .buttonStyle(.bordered)
                
                Button(action: { showingEndConfirmation = true }) {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding()
        .confirmationDialog("End Session?", isPresented: $showingEndConfirmation) {
            Button("End Session", role: .destructive) {
                Task {
                    await workoutManager.stopSession()
                }
            }
        }
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

struct StatView: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
```

## Background Processing

### Efficient Battery Usage

```swift
// Services/PowerManager.swift
import Foundation

class PowerManager {
    static let shared = PowerManager()
    
    // Adaptive sampling based on motion
    func adjustSamplingRate(basedOn acceleration: Double) -> Double {
        if acceleration < 0.1 {
            // Stationary - reduce GPS to 0.2Hz
            return 0.2
        } else if acceleration < 0.5 {
            // Slow movement - 0.5Hz
            return 0.5
        } else {
            // Active - full 1Hz
            return 1.0
        }
    }
    
    // Pause recording when stationary for > 5 minutes
    func shouldPauseRecording(lastSignificantMotion: Date) -> Bool {
        return Date().timeIntervalSince(lastSignificantMotion) > 300
    }
}
```

## Development Checklist

### Project Setup
- [ ] Create Xcode watchOS project
- [ ] Enable required capabilities (Location, HealthKit, Background Modes)
- [ ] Add Info.plist usage descriptions
- [ ] Configure deployment target (watchOS 9.0+)

### Core Services
- [ ] Implement LocationManager with CoreLocation
- [ ] Implement MotionManager with CoreMotion
- [ ] Create WorkoutManager with HealthKit integration
- [ ] Set up WatchConnectivityManager

### Jump Detection
- [ ] Implement JumpDetector (see `05_jump_detection.md`)
- [ ] Test with real sensor data
- [ ] Tune thresholds for water sports

### Session Management
- [ ] Create SessionStore for local persistence
- [ ] Implement session file export
- [ ] Test session transfer to phone

### UI
- [ ] Build SessionView with live metrics
- [ ] Create SummaryView for post-session
- [ ] Add StartView with sport selection

### Testing
- [ ] Test on physical Apple Watch
- [ ] Test battery life (target: 3-4 hours)
- [ ] Test background session continuation
- [ ] Test WatchConnectivity transfer

---

**Next Steps**: Implement the Wear OS app (`04_wearos_app.md`) or dive into jump detection algorithm (`05_jump_detection.md`).
