# watchOS App - SPOTEQ Watch

Swift/SwiftUI Apple Watch application for real-time session tracking with jump detection.

## 📁 Project Structure

```
SPOTEQ/
├── SPOTEQApp.swift              # Main app entry point
├── Info.plist                  # App configuration & permissions
├── Models/
│   └── Session.swift           # Data models (Session, Jump, GPSPoint, IMUSample)
├── Services/
│   ├── LocationManager.swift   # GPS tracking (CoreLocation)
│   ├── MotionManager.swift     # IMU sampling (CoreMotion @ 50Hz)
│   ├── WorkoutManager.swift    # HealthKit integration
│   ├── SessionManager.swift    # Main coordinator
│   └── JumpDetector.swift      # Real-time jump detection
├── Storage/
│   └── StorageManager.swift    # Local JSON storage
└── Views/
    ├── ContentView.swift       # Main navigation
    ├── HomeView.swift          # Start screen
    ├── SportSelectionView.swift # Sport picker
    ├── ActiveSessionView.swift # Live session tracking
    └── SessionDetailView.swift # Session history
```

## 🚀 Quick Start

### Prerequisites

- Xcode 15.0+
- watchOS 10.0+ SDK
- Apple Watch (Series 4 or later recommended for GPS)
- Apple Developer Account (for HealthKit)

### Setup Steps

1. **Open in Xcode**:
   ```bash
   cd /Users/avishay/Desktop/spoteq/apps/watchos
   open SPOTEQ.xcodeproj  # You'll need to create this
   ```

2. **Create Xcode Project**:
   - File → New → Project
   - Choose "watchOS → App"
   - Product Name: `SPOTEQ`
   - Bundle ID: `com.avishayportal.kiters.watchapp` (legacy App Store identity; do not rename)
   - Interface: SwiftUI
   - Language: Swift

3. **Add Capabilities**:
   - Signing & Capabilities → + Capability
   - Add: HealthKit, Location, Background Modes
   - Background Modes: Enable "Location updates" and "Workout processing"

4. **Copy Source Files**:
   All Swift files are already created in the correct directories!

5. **Build & Run**:
   - Select watchOS Simulator or paired Apple Watch
   - Product → Run (⌘R)

## 🎯 Key Features Implemented

### ✅ Core Services

- **LocationManager**: GPS tracking at ~1Hz with battery optimization
- **MotionManager**: IMU sampling at 50Hz (accelerometer + gyroscope)
- **WorkoutManager**: HealthKit integration for workout sessions
- **SessionManager**: Coordinates all services and manages state
- **JumpDetector**: Real-time jump detection using state machine
- **StorageManager**: Local JSON storage with auto-sync queue

### ✅ SwiftUI Views

- **HomeView**: Start session + recent history
- **SportSelectionView**: Choose sport (kiteboarding/windsurfing/wingfoiling/surfing)
- **ActiveSessionView**: 3-tab live tracking
  - Tab 1: Speed, distance, duration, jump count
  - Tab 2: Jump statistics (best jump, total jumps)
  - Tab 3: Pause/Resume/End controls
- **SessionDetailView**: Post-session analysis

### ✅ Jump Detection Algorithm

State machine with 4 states:
1. **Riding**: Normal state, monitoring for takeoff
2. **Takeoff**: Detected acceleration spike (>2g)
3. **Airborne**: Confirmed flight, tracking duration
4. **Landing**: Strong deceleration (>2.5g), finalize jump

Calculates:
- **Height**: Physics formula `h = (g × t²) / 8`
- **Airtime**: Time from takeoff to landing
- **Rotations**: Integrate gyroscope Z-axis
- **Confidence**: Based on airtime, height, and sensor quality

## 📱 Usage

### Starting a Session

1. Open app on Apple Watch
2. Tap "Start Session"
3. Select your sport
4. Grant permissions (first time only)
5. Session starts automatically

### During Session

- **Swipe left/right** to switch between tabs
- **Tab 1**: View live metrics (speed, distance, jumps)
- **Tab 2**: See jump stats (best jump)
- **Tab 3**: Pause or end session

### After Session

- Sessions saved automatically to local storage
- View in "Recent" list on home screen
- Tap to see detailed statistics

## 🔋 Battery Optimization

- GPS: 1Hz update rate, 5m distance filter
- IMU: 50Hz sampling (only during active session)
- Background: Workout mode keeps app alive
- Storage: Batched writes (10 GPS points, 250 IMU samples)

## 📊 Data Storage

Sessions saved as JSON files:
```
/Documents/sessions/{sessionId}.json
```

Each session includes:
- Metadata (sport, duration, timestamps)
- GPS points (lat/lng/alt/speed)
- IMU samples (acceleration + rotation)
- Detected jumps (height, airtime, rotations)

## 🔐 Permissions Required

- **Location (When In Use)**: Track GPS during sessions
- **Motion**: Access accelerometer/gyroscope
- **HealthKit**: Save workouts, read heart rate
- **Background Location**: Continue tracking when screen off

All configured in `Info.plist` with usage descriptions.

## 🧪 Testing

### Simulator Testing
Limited functionality (no GPS/IMU), but UI works:
```bash
# Select "Apple Watch Series 9 (45mm)" simulator
# Run app to test UI flows
```

### Device Testing
Requires paired Apple Watch:
1. Connect iPhone via USB
2. Ensure Apple Watch paired and unlocked
3. Select Apple Watch device target
4. Build & Run

### Jump Detection Testing
- Walk/shake watch to simulate motion
- Check console logs for state transitions
- Verify jump detection thresholds

## 🐛 Debugging

Enable verbose logging:
```swift
// Add to SessionManager.init()
print("🔧 Debug mode enabled")
```

Watch console output:
- 📍 Location updates
- 🎯 Motion samples
- 🚀 Takeoff detection
- ✈️ Airborne confirmation
- 🛬 Landing detection
- 🎉 Jump finalized

## 📦 Next Steps

1. **WatchConnectivity**: Sync to iPhone (not yet implemented)
2. **Offline Replay**: Test with recorded sensor data
3. **Algorithm Tuning**: Adjust thresholds based on real sessions
4. **Battery Testing**: Monitor power consumption
5. **Field Testing**: Validate jump detection accuracy

## 🏗️ Architecture Notes

**Offline-First**:
- All data stored locally first
- Sync to phone via WatchConnectivity (TODO)
- Phone syncs to backend

**State Management**:
- `@StateObject` for managers (retain across views)
- `@EnvironmentObject` for sharing state
- Combine publishers for real-time updates

**Thread Safety**:
- Location/Motion callbacks on background queue
- UI updates wrapped in `DispatchQueue.main.async`

## 📚 Related Docs

- [03_watchos_app.md](../../docs/03_watchos_app.md) - Full implementation guide
- [05_jump_detection.md](../../docs/05_jump_detection.md) - Algorithm details
- [06_data_model.md](../../docs/06_data_model.md) - Data structures

---

**Built with ❤️ for wind sports athletes**
