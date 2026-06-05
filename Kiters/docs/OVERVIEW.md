# watchOS App - Implementation Overview

## 📱 What We Built

A **complete watchOS app** for tracking wind sports sessions with **real-time jump detection**!

### ✨ Key Features

1. **Multi-Sport Tracking** (Kiteboarding, Windsurfing, Wing Foiling, Surfing)
2. **Real-Time Jump Detection** (Height, Airtime, Rotations)
3. **GPS Tracking** (Speed, Distance, Route)
4. **HealthKit Integration** (Workout sessions, Heart rate, Calories)
5. **Offline-First Storage** (Sessions saved locally as JSON)
6. **Battery Optimized** (Smart sampling rates, batched processing)

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────┐
│         SessionManager                  │  ← Main Coordinator
│  (Orchestrates all services)            │
└────┬──────┬──────┬──────┬──────┬───────┘
     │      │      │      │      │
     ▼      ▼      ▼      ▼      ▼
┌─────────┐┌──────┐┌──────┐┌──────┐┌────────┐
│Location ││Motion││Workout││Jump  ││Storage │
│Manager  ││Mgr   ││Manager││Detect││Manager │
│         ││      ││       ││      ││        │
│GPS @1Hz ││IMU   ││Health ││State ││JSON    │
│         ││@50Hz ││Kit    ││Machine││Files  │
└─────────┘└──────┘└──────┘└──────┘└────────┘
     │         │       │       │        │
     └────┬────┴───┬───┴───┬───┴────────┘
          ▼        ▼       ▼
    ┌────────────────────────┐
    │   SwiftUI Views        │
    │  (Home, Active, Detail)│
    └────────────────────────┘
```

---

## 📁 File Structure (14 Files Created)

```
apps/watchos/
├── README.md                      ← Project documentation
├── CHECKLIST.md                   ← Development tasks
├── setup-xcode-project.sh         ← Setup instructions
├── verify-project.sh              ← File verification
└── iSurf-Watch/
    ├── iSurfApp.swift            ← App entry point
    ├── Info.plist                ← Permissions & config
    ├── Models/
    │   └── Session.swift         ← Data models (Session, Jump, GPS, IMU)
    ├── Services/
    │   ├── LocationManager.swift ← GPS tracking
    │   ├── MotionManager.swift   ← IMU sensors
    │   ├── WorkoutManager.swift  ← HealthKit
    │   ├── SessionManager.swift  ← Coordinator
    │   └── JumpDetector.swift    ← Jump algorithm
    ├── Storage/
    │   └── StorageManager.swift  ← JSON persistence
    └── Views/
        ├── ContentView.swift         ← Navigation root
        ├── HomeView.swift            ← Start screen
        ├── SportSelectionView.swift  ← Sport picker
        ├── ActiveSessionView.swift   ← Live tracking
        └── SessionDetailView.swift   ← History view
```

---

## 🎯 Jump Detection Algorithm

### State Machine Flow

```
     ┌─────────┐
     │ RIDING  │ ← Normal riding
     └────┬────┘
          │ Accel > 2g
          ▼
     ┌─────────┐
     │ TAKEOFF │ ← Potential jump
     └────┬────┘
          │ Sustained 0.1-0.3s
          ▼
     ┌─────────┐
     │AIRBORNE │ ← Confirmed flight
     └────┬────┘
          │ Decel > 2.5g
          ▼
     ┌─────────┐
     │ LANDING │ ← Impact detected
     └────┬────┘
          │ Finalize metrics
          ▼
     ┌─────────┐
     │ RIDING  │ ← Return to normal
     └─────────┘
```

### Metrics Calculated

- **Height**: `h = (g × airtime²) / 8` (physics formula)
- **Airtime**: Time between takeoff and landing
- **Rotations**: Integrate gyroscope Z-axis (vertical spin)
- **Confidence**: Score 0-1 based on sensor quality

---

## 📊 Data Models

### Session
```swift
struct Session {
    id: String
    startTime: Date
    endTime: Date?
    sport: Sport              // kiteboarding/windsurfing/wingfoiling/surfing
    status: SessionStatus     // active/paused/completed
    gpsPoints: [GPSPoint]     // ~3600 points per hour @ 1Hz
    imuSamples: [IMUSample]   // ~180,000 samples per hour @ 50Hz
    jumps: [Jump]             // Detected jumps
    
    // Computed
    duration: TimeInterval
    distance: Double
    maxSpeed: Double
    avgSpeed: Double
}
```

### Jump
```swift
struct Jump {
    id: String
    sessionId: String
    startTime: Date
    endTime: Date
    height: Double        // meters
    airtime: Double       // seconds
    rotations: Int        // full 360° spins
    confidence: Double    // 0-1 score
    imuSamples: [IMUSample]  // High-res data during jump
}
```

---

## 🔋 Battery Optimization

| Component | Strategy | Impact |
|-----------|----------|--------|
| **GPS** | 1Hz, 5m filter | ⚡️ Low |
| **IMU** | 50Hz (active only) | ⚡️⚡️ Medium |
| **HealthKit** | Passive tracking | ⚡️ Low |
| **Storage** | Batched writes | ⚡️ Minimal |
| **Screen** | Auto-sleep enabled | ⚡️⚡️⚡️ High |

**Estimated Battery Life**: 4-6 hours of active tracking

---

## 🎨 User Interface

### Home Screen
- **Start Button** (opens sport selector)
- **Recent Sessions** (last 3 sessions)
- **Empty State** (when no history)

### Active Session (3 Tabs)
1. **Metrics Tab**
   - Duration (00:00:00)
   - Current Speed (km/h)
   - Max Speed (km/h)
   - Distance (km)
   - Jump Count (#)

2. **Jumps Tab**
   - Best Jump (height + airtime)
   - Rotation count
   - Total jumps

3. **Controls Tab**
   - Pause/Resume button
   - End Session button

### Session Detail
- Sport icon + name
- Date/time
- Duration, Distance, Speed stats
- Jump list (height, airtime, rotations, confidence)

---

## 🔐 Permissions Required

✅ **Location (When In Use)**
- Tracks GPS during active sessions
- Usage: Calculate speed, distance, route

✅ **Motion & Fitness**
- Access accelerometer + gyroscope
- Usage: Detect jumps, calculate height/rotations

✅ **Health**
- Save workouts to Health app
- Read heart rate (optional)
- Usage: Track calories, heart rate zones

✅ **Background Modes**
- Location updates
- Workout processing
- Usage: Continue tracking when screen off

---

## 🧪 Testing Strategy

### Unit Tests (TODO)
- [ ] Jump detection algorithm
- [ ] Height calculation accuracy
- [ ] Rotation counting
- [ ] GPS filtering
- [ ] Storage/retrieval

### Integration Tests (TODO)
- [ ] SessionManager coordination
- [ ] Service lifecycle
- [ ] Permission handling
- [ ] Error scenarios

### Field Tests (Required!)
- [ ] Real kiteboarding session
- [ ] Validate jump detection
- [ ] Check false positives
- [ ] Battery monitoring
- [ ] GPS accuracy

---

## 🚀 Next Steps

### Immediate (You Need To Do)
1. ✅ Open Xcode
2. ✅ Create watchOS project (follow `setup-xcode-project.sh` instructions)
3. ✅ Add all source files to project
4. ✅ Configure capabilities (HealthKit, Location, Background)
5. ✅ Build on simulator
6. ✅ Test on real Apple Watch

### Phase 2 (After Basic Testing)
1. Implement WatchConnectivity (sync to iPhone)
2. Tune jump detection thresholds
3. Add haptic feedback on jump
4. Optimize battery usage
5. Field test with real sessions

### Phase 3 (Polish)
1. Better error handling
2. Session deletion
3. Settings screen
4. Complications
5. App Store submission

---

## 💡 Key Implementation Details

### 1. Real-Time Processing
- LocationManager callbacks → immediate GPS processing
- MotionManager callbacks → 50Hz IMU stream → JumpDetector
- JumpDetector state machine → emit jump events
- SessionManager → update UI metrics

### 2. Offline-First
- All data saved locally (JSON files)
- WatchConnectivity for phone sync (TODO)
- Phone syncs to backend (TODO)
- No network required on watch

### 3. State Management
- `@StateObject` for service managers (persist)
- `@EnvironmentObject` for sharing across views
- Combine publishers for reactive updates
- Timer for UI refresh (1Hz)

### 4. Thread Safety
- Location/Motion callbacks on background queue
- UI updates: `DispatchQueue.main.async { ... }`
- Atomic operations for shared state
- No data races

---

## 📖 Code Examples

### Starting a Session
```swift
// User taps "Start Session" → Selects sport
sessionManager.startSession(sport: .kiteboarding)

// Under the hood:
// 1. Create Session(sport: .kiteboarding)
// 2. LocationManager.startTracking()
// 3. MotionManager.startTracking()
// 4. WorkoutManager.startWorkout()
// 5. JumpDetector.reset()
// 6. UI updates automatically (@Published)
```

### Jump Detection Flow
```swift
// 50Hz IMU stream
motionManager.processSample(sample) 
  → jumpDetector.processSample(sample)
    → checkForTakeoff() // Accel > 2g?
      → state = .takeoff
    → confirmTakeoff() // Sustained 0.1s?
      → state = .airborne
    → trackAirborne() // Decel > 2.5g?
      → state = .landing
    → finalizeLanding() // Calculate metrics
      → onJumpDetected(jump) 
        → sessionManager.handleJumpDetected(jump)
          → UI updates (jump count ++)
```

---

## 🎓 Learning Resources

- [Apple Watch Programming Guide](https://developer.apple.com/documentation/watchos-apps)
- [CoreMotion Framework](https://developer.apple.com/documentation/coremotion)
- [HealthKit Workouts](https://developer.apple.com/documentation/healthkit/workouts_and_activity_rings)
- [SwiftUI for watchOS](https://developer.apple.com/tutorials/swiftui)

---

**Ready to build?** Follow the setup instructions in `setup-xcode-project.sh`! 🚀
