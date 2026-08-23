# SPOTEQ — Wear OS (Android Watch)

Standalone Wear OS port of the **SPOTEQ Watch App** (watchOS), replicating the
same UI and jump-detection logic for Android-watch users. See the porting plan
in `../` and the Swift source under `../SPOTEQ/SPOTEQ Watch App/`.

## Stack
- Kotlin + Jetpack **Compose for Wear OS**
- `SensorManager` (linear accel / gyro / gravity / pressure) at 50 Hz
- `FusedLocationProviderClient` for GPS
- Health Services `MeasureClient` for live heart rate
- Foreground `Service` keeps the session recording with the screen off
- `SharedPreferences` for settings, JSON files for sessions, CSV diagnostic logs

## Modules / packages (`:wear`)
- `engine/` — the v7 jump engine (`KitesurfJumpEngineV7`, `KitesurfSession`,
  `JumpDetector` adapter, `DSP`, `GpsUtil`). Pure Kotlin, no Android deps.
- `model/` — `Session`, `Jump`, `GpsPoint`, `ImuSample`, `Sport`,
  `DetectionMode` + `JumpDetectionConfig`.
- `sensors/` — `MotionManager`, `LocationManager`, `WorkoutManager`.
- `session/` — `SessionManager` (ViewModel/StateFlows) + `RecordingService`.
- `storage/` — `StorageManager`, `SettingsStore`, `SessionLogger`.
- `ui/` — Compose Wear screens (Home, SportSelection, ActiveSession pager,
  Settings, Data, Logs, SessionDetail).

## Engine parity
`engine/KitesurfJumpEngineV7.kt` is a faithful port of the Swift engine. The
JVM test `EngineParityTest` replays the same sensor-log fixtures the Swift
`JumpReplay` harness blesses and asserts the detected jumps match the Swift
expected output (synthetic → 1 jump @ 3.09 m / 1.5 s / 8 rot; realistic and
ultra-realistic → 0 jumps).

## Build & test
```bash
# from android/
./gradlew :wear:testDebugUnitTest      # engine parity tests
./gradlew :wear:assembleDebug          # build APK

# install + run on a Wear OS emulator/device
adb install -r -g wear/build/outputs/apk/debug/wear-debug.apk
adb shell am start -n com.kiters.wear/.MainActivity
```

## Not in v1 (vs watchOS)
- Cloud upload to Supabase (`CloudSyncService`) and "Fetch Cloud Response".
- Android phone companion + Wearable Data Layer transfer (standalone only).
- iOS Water Lock has no exact equivalent; replaced by a "Screen Lock" setting +
  the foreground ongoing activity. Calories (not shown in the watchOS UI) omitted.
