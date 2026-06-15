//
//  LocationManager.swift
//  iSurf-Watch
//
//  Manages GPS location tracking with battery optimization
//

import Foundation
import CoreLocation
import Combine

class LocationManager: NSObject, ObservableObject {
    private let locationManager = CLLocationManager()
    
    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var permissionDenied = false
    @Published var isTracking = false
    
    // Safety flags to prevent duplicate requests and fake errors
    private var hasReceivedAuthorizationResponse = false
    private var permissionRequestInProgress = false
    private var wantsToTrack = false
    private var isPrewarming = false
    
    // Location buffer for batch processing
    private var locationBuffer: [GPSPoint] = []
    private let bufferSize = 10 // Send every 10 GPS points (~10 seconds at 1Hz)
    
    // Callbacks
    var onLocationUpdate: ((GPSPoint) -> Void)?
    var onLocationBatch: (([GPSPoint]) -> Void)?
    
    override init() {
        super.init()
        setupLocationManager()
    }
    
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone // Update on every GPS fix — needed for jump speed/altitude
        locationManager.activityType = .fitness
        
        authorizationStatus = locationManager.authorizationStatus
        
        // If already determined, mark as received
        if authorizationStatus != .notDetermined {
            hasReceivedAuthorizationResponse = true
        }
        
        print("📍 LocationManager initialized. Status: \(authorizationStatus.rawValue)")
    }
    
    func requestPermission() {
        let currentStatus = locationManager.authorizationStatus
        
        guard currentStatus == .notDetermined else {
            print("⚠️ Permission already determined: \(currentStatus.rawValue)")
            return
        }
        
        guard !permissionRequestInProgress else {
            print("⚠️ Permission request already in progress")
            return
        }
        
        permissionRequestInProgress = true
        print("📍 Requesting location permission (requestWhenInUseAuthorization only)...")
        locationManager.requestWhenInUseAuthorization()
        // DO NOT call startUpdatingLocation() or requestLocation() here!
        // On watchOS, that causes a fake kCLErrorDenied before the dialog appears
    }
    
    /// Warms up GPS ahead of a session so the first fix is ready quickly and the
    /// Home screen can display live signal quality. Safe to call repeatedly.
    /// Does NOT request permission (that stays a deliberate Start-Session action)
    /// and does nothing if tracking is already running (session or prewarm).
    func prewarm() {
        let status = locationManager.authorizationStatus
        authorizationStatus = status
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        guard !isTracking else { return }
        isPrewarming = true
        locationManager.startUpdatingLocation()
        isTracking = true
        print("📍 GPS prewarm started")
    }

    /// Stops prewarm updates — but never while a real session owns the GPS
    /// (`wantsToTrack`), so calling this on Home teardown can't kill a session.
    func stopPrewarm() {
        guard isPrewarming else { return }
        isPrewarming = false
        guard !wantsToTrack else { return }   // session owns GPS — leave it on
        locationManager.stopUpdatingLocation()
        isTracking = false
        print("📍 GPS prewarm stopped")
    }

    func startTracking() {
        wantsToTrack = true
        isPrewarming = false   // a real session now owns the GPS
        let currentStatus = locationManager.authorizationStatus
        authorizationStatus = currentStatus
        
        if currentStatus == .authorizedWhenInUse || currentStatus == .authorizedAlways {
            beginLocationUpdates()
        } else if currentStatus == .notDetermined {
            // Only request auth - do NOT start location updates yet
            print("📍 Not authorized yet, requesting permission first...")
            requestPermission()
        } else {
            print("❌ Location permission denied or restricted")
            DispatchQueue.main.async {
                self.permissionDenied = true
            }
        }
    }
    
    private func beginLocationUpdates() {
        guard !isTracking else {
            print("📍 Already tracking, skipping duplicate start")
            return
        }
        locationManager.startUpdatingLocation()
        isTracking = true
        print("📍 Location tracking started (authorized)")
    }
    
    func stopTracking() {
        wantsToTrack = false
        locationManager.stopUpdatingLocation()
        isTracking = false
        
        // Flush remaining buffer
        if !locationBuffer.isEmpty {
            onLocationBatch?(locationBuffer)
            locationBuffer.removeAll()
        }
        
        print("📍 Location tracking stopped")
    }
    
    func pauseTracking() {
        locationManager.stopUpdatingLocation()
        isTracking = false
        print("⏸️ Location tracking paused")
    }
    
    func resumeTracking() {
        wantsToTrack = true
        let currentStatus = locationManager.authorizationStatus
        if currentStatus == .authorizedWhenInUse || currentStatus == .authorizedAlways {
            beginLocationUpdates()
        }
        print("▶️ Location tracking resumed")
    }
    
    private func processLocation(_ location: CLLocation) {
        // Filter out invalid locations.
        // Tightened from <50m to <20m: a 50m fix can introduce ±1.7 m/s
        // speed error, which produces spurious IDLE↔RIDING transitions in
        // the jump detector. Apple Watch typically achieves <15m within
        // 10–30s of fix; 20m is a safe ceiling for water sports.
        guard location.horizontalAccuracy > 0 &&
              location.horizontalAccuracy < 20 else {
            return
        }
        
        DispatchQueue.main.async {
            self.currentLocation = location
        }
        let gpsPoint = GPSPoint(from: location)
        
        // Immediate callback for real-time processing
        onLocationUpdate?(gpsPoint)
        
        // Add to buffer for batch processing
        locationBuffer.append(gpsPoint)
        
        if locationBuffer.count >= bufferSize {
            onLocationBatch?(locationBuffer)
            locationBuffer.removeAll()
        }
    }
}

// MARK: - CLLocationManagerDelegate
extension LocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            self.hasReceivedAuthorizationResponse = true
            self.permissionRequestInProgress = false
            print("📍 Location authorization changed: \(manager.authorizationStatus.rawValue)")
            
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                print("✅ Location permission granted!")
                self.permissionDenied = false
                // Auto-start tracking if we wanted to track
                if self.wantsToTrack && !self.isTracking {
                    self.beginLocationUpdates()
                }
            } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                print("❌ Location permission denied")
                self.permissionDenied = true
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        processLocation(location)
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("❌ Location error: \(error.localizedDescription)")
        
        if let clError = error as? CLError {
            switch clError.code {
            case .denied:
                // IMPORTANT: On watchOS, a fake kCLErrorDenied can fire before
                // the user has responded to the permission dialog.
                // Only treat it as real denial if we've actually received an auth callback.
                if hasReceivedAuthorizationResponse {
                    DispatchQueue.main.async {
                        self.authorizationStatus = .denied
                        self.permissionDenied = true
                    }
                } else {
                    print("⚠️ Ignoring fake kCLErrorDenied (no auth response yet)")
                }
            case .network:
                print("⚠️ Network error - will retry")
            default:
                break
            }
        }
    }
}
