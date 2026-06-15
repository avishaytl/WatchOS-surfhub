# אלגוריתם סשן וקפיצה מקצה לקצה

מסמך זה מסכם את הזרימה הפעילה באפליקציית השעון לאחר השינויים האחרונים: התחלת סשן, קליטת GPS/IMU, זיהוי קפיצות, סיום סשן, החלטת העלאה לענן, ופורמט הלוג הבינארי `.kslog`.

המסמך מתאר את המימוש הנוכחי ב-Swift, בעיקר בקבצים:

- `Kiters/Kiters Watch App/Services/SessionManager.swift`
- `Kiters/Kiters Watch App/Services/JumpDetector.swift`
- `Kiters/Kiters Watch App/Services/KitesurfJumpEngine.swift`
- `Kiters/Kiters Watch App/Services/SessionLogger.swift`
- `Kiters/Kiters Watch App/Models/Session.swift`

## תמונת על

המערכת מחולקת לשתי שכבות עיקריות:

1. שכבת הסשן: `SessionManager` מנהל את החיים של האימון, UI state, חיישנים, שמירה מקומית, לוגים והעלאה לענן.
2. שכבת האלגוריתם: `JumpDetector` הוא adapter ששומר על API ישן, אבל בפועל מזין את `KitesurfSession` ואת `KitesurfJumpEngineV7`.

זרימת הנתונים:

```text
Start button
  -> SessionManager.startSession
  -> LocationManager + MotionManager + WorkoutManager + SessionLogger

GPS 1Hz-ish
  -> SessionManager.handleGPSPoint
  -> speed smoothing
  -> JumpDetector.updateGPS
  -> Session.gpsPoints + distance + UI GPS state

IMU 50Hz-ish
  -> SessionManager.handleIMUSample
  -> JumpDetector.processSample
  -> KitesurfSession.onSample
  -> streaming FSM
  -> KitesurfJumpEngineV7.process after landing
  -> JumpDetector emits Jump
  -> SessionManager appends Jump to current Session

End button
  -> SessionManager.endSession
  -> stop sensors/logger/workout/timer
  -> if duration < 60s: delete everything
  -> else save local
  -> if no GPS: show OK notice, local only
  -> else show upload prompt
  -> only after user approves: start/end cloud session + upload log
```

## מודלי הנתונים

`Session` הוא האובייקט שנשמר מקומית:

```swift
struct Session: Identifiable, Codable {
    let id: String
    var startTime: Date
    var endTime: Date?
    var sport: Sport
    var status: SessionStatus
    var gpsPoints: [GPSPoint]
    var imuSamples: [IMUSample]
    var jumps: [Jump]
    var cachedDistance: Double = 0

    var duration: TimeInterval {
        let end = endTime ?? Date()
        return end.timeIntervalSince(startTime)
    }
}
```

שימו לב: `imuSamples` נשאר במודל לצורכי תאימות, אבל המימוש הנוכחי לא מוסיף אליו 50Hz של דגימות. ה-IMU המלא נשמר בלוג הבינארי כדי לא להכביד על `Session` ועל ה-main thread.

`Jump` הוא תוצאה שכבר עברה ניתוח:

```swift
struct Jump: Identifiable, Codable {
    let id: String
    var sessionId: String
    var startTime: Date
    var endTime: Date
    var height: Double
    var airtime: Double
    var jumpDistance: Double
    var rotations: Int
    var confidence: Double
    var imuSamples: [IMUSample]
    var apexTime: Double?
}
```

## תחילת סשן

התחלה מתבצעת דרך `SessionManager.startSession(sport:)`.

העיקרון החשוב: קודם מפרסמים `currentSession` ו-`isRecording`, ורק אחרי זה מתחילים חיישנים. כך כל callback שמגיע מיד אחרי ההפעלה רואה שיש סשן פעיל.

```swift
func startSession(sport: Sport) {
    guard currentSession == nil else { return }

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
    pendingCloudUpload = nil
    sessionNotice = nil
    runningDistance = 0
    lastGPSPoint = nil
    speedSmoothingBuffer.removeAll(keepingCapacity: true)

    locationManager.startTracking()
    motionManager.startTracking()
    workoutManager.startWorkout(sport: sport)

    let mode = detectionMode
    jumpDetector.reset(mode: mode)
    uploadState.reset(sessionId: newSession.id)

    sessionLogger.start(
        sessionId: newSession.id,
        mode: mode,
        devMode: JumpDetectionConfig.shared.devMode
    )

    startTimer()
}
```

### דלתא התחלה

| רכיב | לפני התחלה | אחרי התחלה |
|---|---:|---:|
| `currentSession` | `nil` | `Session(status: .active)` |
| `isRecording` | `false` | `true` |
| `isPaused` | `false` או ערך ישן | `false` |
| `jumpCount` | ערך קודם | `0` |
| `distance` | ערך קודם | `0` |
| `maxSpeed/currentSpeed` | ערך קודם | `0` |
| `gpsPointCount` | ערך קודם | `0` |
| `gpsSignalQuality` | ערך קודם | `.none` |
| `pendingCloudUpload` | אולי prompt מסשן קודם | `nil` |
| `sessionNotice` | אולי הודעה קודמת | `nil` |
| `runningDistance` | ערך קודם | `0` |
| `lastGPSPoint` | נקודה קודמת | `nil` |
| `speedSmoothingBuffer` | חלון קודם | ריק |
| `JumpDetector` | מצב קודם | reset לפי `DetectionMode` |
| `SessionLogger` | סגור או קובץ קודם | קובץ `.kslog` חדש |

## GPS: עדכון מהירות, מסלול ומצב קליטה

כל נקודת GPS עוברת קודם smoothing למהירות, כדי שהאלגוריתם לא יקבל קפיצות רעש של `CLLocation.speed`.

```swift
private func handleGPSPoint(_ point: GPSPoint) {
    speedSmoothingBuffer.append(point.speed)
    if speedSmoothingBuffer.count > speedSmoothingWindow {
        speedSmoothingBuffer.removeFirst()
    }
    let smoothedSpeed = speedSmoothingBuffer.reduce(0, +) / Double(speedSmoothingBuffer.count)

    jumpDetector.updateGPS(
        speed: smoothedSpeed,
        altitude: point.altitude,
        latitude: point.latitude,
        longitude: point.longitude,
        course: point.course,
        timestamp: point.timestamp
    )

    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        guard var session = self.currentSession, session.status == .active else { return }

        session.gpsPoints.append(point)

        if let prev = self.lastGPSPoint {
            let from = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
            let to = CLLocation(latitude: point.latitude, longitude: point.longitude)
            self.runningDistance += to.distance(from: from)
        }

        self.lastGPSPoint = point
        session.cachedDistance = self.runningDistance
        self.currentSession = session

        self.distance = self.runningDistance
        self.maxSpeed = max(self.maxSpeed, point.speed)
        self.currentSpeed = point.speed
        self.gpsPointCount = session.gpsPoints.count
        self.isGPSActive = true
        self.lastGPSAccuracy = point.horizontalAccuracy
        self.gpsSignalQuality = GPSSignalQuality.from(accuracy: point.horizontalAccuracy)
    }
}
```

### דלתא GPS

| אירוע | שינוי |
|---|---|
| נקודה ראשונה | `gpsPoints.count` עולה ל-1, `isGPSActive = true`, מרחק עדיין 0 כי אין נקודה קודמת |
| נקודה שנייה ומעלה | המרחק מתעדכן ב-O(1) לפי haversine בין הנקודה הקודמת לנוכחית |
| מהירות חדשה | raw speed נשמרת ב-`Session.gpsPoints`; smoothed speed מוזנת לאלגוריתם |
| דיוק GPS | `lastGPSAccuracy` ו-`gpsSignalQuality` מתעדכנים לפי accuracy |
| אין סשן פעיל | הנקודה עדיין יכולה להזין את detector לפני ה-main update, אבל לא נשמרת ל-Session |

### איכות GPS

```swift
static func from(accuracy: Double) -> GPSSignalQuality {
    if accuracy <= 0 { return .none }
    if accuracy < 5 { return .strong }
    if accuracy < 15 { return .good }
    if accuracy < 30 { return .fair }
    return .weak
}
```

## IMU: הזנת האלגוריתם ולוג בינארי

כל דגימת IMU מוזנת ל-`JumpDetector`. אין append של כל sample לתוך `Session`, כדי לא לגרום להעתקות struct כבדות ב-main thread.

```swift
private func handleIMUSample(_ sample: IMUSample) {
    jumpDetector.processSample(sample)
}
```

בתוך `JumpDetector.processSample`, הדגימה הופכת ל-`SensorSample` של מנוע v7, מוזנת ל-streaming FSM, ונכתבת ללוג:

```swift
func processSample(_ sample: IMUSample) {
    sampleCount += 1

    if t0Wall == nil {
        t0Wall = sample.timestamp
        sessionWallStart = sample.timestamp
    }

    let s = makeSensorSample(sample)
    session.onSample(s)

    if state != .idle || sampleCount % 5 == 0 {
        SessionLogger.shared.logSample(
            sample: sample,
            speed: latestSpeedMS,
            baselinePressure: 0,
            lowGCount: 0,
            state: state.rawValue
        )
    }
}
```

### דלתא IMU

| מצב detector | תדירות לוג | מה קורה |
|---|---:|---|
| `IDLE` | בערך 10Hz, כל דגימה חמישית | חסכון בגודל לוג בזמן שקט |
| `RIDING` | full rate | נשמר רצף מלא לפני takeoff |
| `AIRBORNE` | full rate | נשמר רצף מלא לקפיצה ולנחיתה |
| `ANALYZING` פנימי | מוצג כ-`AIRBORNE` ב-UI | ממשיכים לאסוף post-tail לניתוח |

## מיפוי `JumpDetector` הפעיל

`JumpDetector.swift` מכיל למעלה אלגוריתם ישן בתגובות, אבל המימוש הפעיל מתחיל ב:

```swift
final class JumpDetector {
    enum JumpState: String, CustomStringConvertible {
        case idle = "IDLE"
        case riding = "RIDING"
        case airborne = "AIRBORNE"
        case cooldown = "COOLDOWN"
    }

    private var session: KitesurfSession!
    private var mode: DetectionMode = .standard
}
```

ה-adapter שומר על API הישן:

- `reset(mode:)`
- `updateGPS(speed:altitude:latitude:longitude:course:timestamp:)`
- `processSample(_:)`
- `onStateChanged`
- `onJumpDetected`

אבל בפועל הוא מזין `KitesurfSession`, שמפעילה streaming FSM ומנתחת offline אחרי landing.

## שער מהירות ו-arm

האלגוריתם לא אמור לספור קפיצה כשהמשתמש עומד. לכן יש שער GPS:

```swift
func updateGPS(speed: Double, altitude: Double, latitude: Double, longitude: Double, course: Double = -1, timestamp: Date) {
    let v = max(0, speed)

    pendingSpeedMS = v
    pendingLat = latitude
    pendingLon = longitude
    latestSpeedMS = v

    if state == .idle || state == .riding {
        if devMode || v >= mode.minSpeedSafe {
            setState(.riding)
        } else if v < stationarySpeed {
            setState(.idle)
        }
    }
}
```

דלתא:

| תנאי | מצב חדש |
|---|---|
| `devMode == true` | `RIDING`, גם בלי GPS speed |
| `speed >= minSpeed` | `RIDING` |
| `speed < stationarySpeed` | `IDLE` |
| `AIRBORNE`/analysis פעיל | לא מורידים ל-`IDLE` באמצע קפיצה |

ברירת המחדל של `minSpeed` היא 15 קמ"ש, כלומר `15.0 / 3.6` מטר לשנייה.

## Streaming FSM: `KitesurfSession`

`KitesurfSession` מנהל ארבעה מצבים פנימיים:

```swift
final class KitesurfSession {
    enum State { case idle, riding, airborne, analyzing }
}
```

המצבים הפעילים:

| מצב | תפקיד |
|---|---|
| `idle` | לא מנתח דגימות |
| `riding` | אוסף baseline, ride stats, rolling buffer ומחפש release spike |
| `airborne` | אוסף jump buffer, מקפיא baro baseline, מחפש landing |
| `analyzing` | מוסיף post-tail ואז מריץ `KitesurfJumpEngineV7.process` |

הפרמטרים המרכזיים של הסשן:

| פרמטר | ערך | משמעות |
|---|---:|---|
| `preTailSec` | 2.0s | חלון לפני takeoff שמועבר לניתוח |
| `postLandingSec` | 1.0s | זנב אחרי landing לפני analysis |
| `rollingSec` | 6.0s | גודל rolling buffer |
| `baselineWarmupSec` | 8.0s | זמן חימום ל-baro baseline |
| `rideWindowSec` | 1.5s | חלון רעידות רכיבה לחישוב threshold אדפטיבי |
| `baselineEMA` | 0.01 | מעקב איטי אחרי שינויי לחץ/מזג אוויר |

## זיהוי takeoff

במצב `riding`, כל sample נכנס ל-rolling buffer ולחלון ride stats.

```swift
private func isReleaseSpike(_ s: SensorSample) -> Bool {
    let a = s.accelMagG
    guard a >= takeoffReleaseFloorG else { return false }
    guard rideWindow.count > 10 else { return a >= takeoffReleaseFloorG }

    let mu = median(rideWindow)
    let sd = std(rideWindow, mean: mean(rideWindow))
    let thr = max(takeoffReleaseFloorG, mu + releaseSigmaK * max(sd, 0.05))

    return a >= thr && s.gyroMag >= releaseGyroMinRad
}
```

המשמעות:

- לא משתמשים רק ב-`accel >= 1.5g`.
- threshold עולה אם הים/היד רועשים.
- חייבים גם אנרגיית gyro כדי להבדיל בין מכה ביד לבין takeoff אמיתי.

כשיש release spike:

```swift
jumpBuffer = rollingBuffer.last(samples(preTailSec))
takeoffIndexInBuffer = jumpBuffer.count - 1
takeoffT = s.t
baselineAtTakeoff = sessionBaselineP
jumpMinPressure = s.baro ?? sessionBaselineP
baselineFrozen = true
transition(to: .airborne)
```

דלתא takeoff:

| שדה | לפני | אחרי |
|---|---|---|
| `state` | `.riding` | `.airborne` |
| `jumpBuffer` | ריק | 2s אחרונות לפני takeoff |
| `takeoffT` | 0 או קודם | זמן sample מונוטוני |
| `baselineAtTakeoff` | baseline חי | snapshot קפוא |
| `baselineFrozen` | `false` | `true` |
| `jumpMinPressure` | infinity/ישן | לחץ נוכחי או baseline |

## זיהוי landing

במצב `airborne`, הסשן ממשיך להוסיף samples ל-`jumpBuffer` ומעדכן `jumpMinPressure`.

נחיתה מזוהה באחד משלושה מסלולים:

```swift
private func landingDetected(_ s: SensorSample, air: Double) -> Bool {
    if air >= hardLandingMinAirSec && s.accelMagG >= detectorLandingSpikeG {
        return true
    }

    if air >= hardLandingMinAirSec, let p = s.baro {
        let drop = baselineAtTakeoff - jumpMinPressure
        if drop > detectorNoiseFloorHPa {
            let recover = max(drop * 0.08, detectorNoiseFloorHPa)
            if p >= baselineAtTakeoff - recover { return true }
        }
    }

    let settleBaroOK = baselineAtTakeoff > 0
        && jumpMinPressure.isFinite
        && (baselineAtTakeoff - jumpMinPressure) >= detectorSettleMinBaroDropHPa

    guard air >= settleMinAirSec && settleBaroOK else {
        settleRun = 0
        return false
    }

    let rideMean = rideWindow.isEmpty ? 0.1 : median(rideWindow)
    if abs(s.accelMagG - rideMean) < 0.35 && s.gyroMag < 8.0 {
        settleRun += 1
        if settleRun >= settleSamplesNeeded { return true }
    } else {
        settleRun = 0
    }
    return false
}
```

מסלולי landing:

| מסלול | תנאי |
|---|---|
| hard impact | אחרי מינימום airtime, תאוצה מעל `landingSpikeG` |
| baro recovery | היה drop אמיתי בלחץ, והלחץ חזר קרוב ל-baseline |
| settle | האצה חזרה קרוב לרכיבה רגועה + gyro רגוע לאורך מספר samples |
| watchdog | אם עבר `maxAirTimeSec`, עוברים ל-analysis, אבל תוצאה עם timeout נפסלת |

## Offline analysis: `KitesurfJumpEngineV7.process`

אחרי landing נכנסים ל-`analyzing`, אוספים post-tail של שנייה, ואז מריצים ניתוח על buffer קפוא.

השלבים העיקריים:

1. Dedup לפי timestamp כדי להימנע מ-zero dt.
2. הערכת `dt` בפועל.
3. סינון baro: median filter ואז שני low-pass filters.
4. חישוב ride baseline מ-25% הראשונים של ה-buffer.
5. איתור takeoff לפי hint או לפי release threshold.
6. איתור landing לפי impact/baro/settle.
7. חישוב airtime, מרחק, גובה, rotations ו-confidence.

### סינון לחץ

```swift
let filled = fillForward(baroRaw)
let m = DSP.medianFilter(filled, halfWindow: cfg.baroMedianHalfWindow)
let p1 = DSP.lowPass(m, alpha: cfg.baroLowPassAlpha1)
let baroSmooth = DSP.lowPass(p1, alpha: cfg.baroLowPassAlpha2)
```

### גובה

יש שתי הערכות:

1. Barometric:

```text
dP = baselineP - jumpMinP
baroH = dP * 8.43
```

2. Kinematic:

```text
symCeilingH = g * airtime^2 / 8
riseH = calibration * 0.5 * g * tRise^2
kiteFallbackH = calibration * 0.13 * symCeilingH
```

הבחירה:

```swift
let airtimeCeiling = symCeilingH * cfg.airtimeCeilingTolerance
let baroConsistent = baroH > 0 && baroH <= airtimeCeiling

if baroConsistent {
    let baroTrust = DSP.clamp(
        (dP - cfg.baroTrustLoHPa) / (cfg.baroTrustHiHPa - cfg.baroTrustLoHPa),
        0,
        1
    )
    heightM = baroTrust * baroClamped + (1 - baroTrust) * kinematicH
} else {
    heightM = kinematicH
}
```

כלומר:

- בקפיצות קטנות/בינוניות ה-baro לא תמיד מספיק אמין.
- אם ה-baro סותר את airtime, מתעלמים ממנו.
- אם ה-baro משמעותי ועקבי, משלבים או סומכים עליו.

### סינון תוצאות

תוצאה נפסלת אם:

- אין מספיק samples.
- לא נמצא takeoff.
- לא נמצאה landing נקייה.
- הגובה המשולב נמוך מ-`minJumpHeightMeters`, ברירת מחדל 1m.
- confidence נמוך מ-0.40.
- adapter מזהה שה-session max speed נמוך מ-`minSpeed`, אלא אם `devMode` פעיל.

## המרת `JumpResult` ל-`Jump`

`JumpDetector.emitJump` מחזיר את התוצאה למודל של האפליקציה:

```swift
private func emitJump(from r: JumpResult) {
    guard r.confidence >= acceptConfidence01 else { return }

    if !devMode {
        let minKnots = mode.minSpeedSafe * 1.94384
        if r.maxSessionSpeedKnots < minKnots { return }
    }

    let base = sessionWallStart ?? t0Wall ?? Date()
    let start = base.addingTimeInterval(r.takeoffTimeSeconds)
    let end = base.addingTimeInterval(r.landingTimeSeconds)

    var jump = Jump(sessionId: sessionId, startTime: start)
    jump.endTime = end
    jump.height = r.jumpHeightMeters
    jump.airtime = r.airTimeSeconds
    jump.jumpDistance = r.jumpDistanceMeters ?? r.jumpDistanceGPSMeters ?? 0
    jump.rotations = r.rotations
    jump.apexTime = r.apexTimeSeconds
    jump.confidence = r.confidence * 100.0

    onJumpDetected?(jump)
}
```

ואז `SessionManager` מוסיף את הקפיצה לסשן:

```swift
private func handleJumpDetected(_ jump: Jump) {
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        guard var session = self.currentSession else { return }

        var detectedJump = jump
        detectedJump.sessionId = session.id
        session.jumps.append(detectedJump)

        self.currentSession = session
        self.jumpCount = session.jumps.count
    }
}
```

## Pause ו-Resume

Pause עוצר חיישנים, workout וטיימר, אבל לא שומר ולא מסיים:

```swift
func pauseSession() {
    guard currentSession != nil, !isPaused else { return }
    locationManager.pauseTracking()
    motionManager.pauseTracking()
    workoutManager.pauseWorkout()
    currentSession?.status = .paused
    isPaused = true
    timer?.invalidate()
    timer = nil
}
```

Resume מחזיר את החיישנים והטיימר:

```swift
func resumeSession() {
    guard currentSession != nil, isPaused else { return }
    locationManager.resumeTracking()
    motionManager.resumeTracking()
    workoutManager.resumeWorkout()
    currentSession?.status = .active
    isPaused = false
    startTimer()
}
```

דלתא:

| פעולה | status | sensors | timer |
|---|---|---|---|
| pause | `.paused` | paused | stopped |
| resume | `.active` | resumed | running |

## סיום סשן

סיום סשן מתחיל בעצירה של כל המקורות:

```swift
func endSession() {
    guard var session = currentSession else { return }

    locationManager.stopTracking()
    motionManager.stopTracking()

    sessionLogger.stop()
    let completedLogURL = sessionLogger.mostRecentLogURL()

    timer?.invalidate()
    timer = nil

    workoutManager.endWorkout { [weak self] workout in
        guard let self = self else { return }
        session.endTime = Date()
        session.status = .completed

        // branch logic below
    }
}
```

### Branch 1: פחות מדקה

הדרישה החדשה: סשן קצר מ-60 שניות לא נשמר בכלל, לא מקומית ולא בשרת. גם הלוג נמחק.

```swift
if session.duration < 60 {
    self.deleteLogFile(completedLogURL)
    DispatchQueue.main.async {
        self.resetFinishedSessionState()
        self.pendingCloudUpload = nil
        self.uploadState.reset(sessionId: nil)
        self.sessionNotice = SessionUserNotice(
            titleKey: "session.too_short_title",
            messageKey: "session.too_short_message"
        )
    }
    return
}
```

דלתא:

| רכיב | תוצאה |
|---|---|
| local storage | לא נשמר |
| cloud | לא מתחיל upload |
| log | נמחק |
| UI | חוזר למסך רגיל + הודעת OK |
| `currentSession` | `nil` |

### Branch 2: מעל דקה, בלי GPS

הסשן נשמר מקומית, אבל אי אפשר לפתוח סשן בשרת בלי נקודת GPS ראשונה. במקרה הזה המשתמש מקבל הודעת OK.

```swift
self.storageManager.saveSession(session)

DispatchQueue.main.async {
    self.resetFinishedSessionState()
    if session.gpsPoints.isEmpty {
        self.pendingCloudUpload = nil
        self.uploadState.reset(sessionId: nil)
        self.sessionNotice = SessionUserNotice(
            titleKey: "session.upload_failed_title",
            messageKey: "session.upload_no_gps_message"
        )
        return
    }
    self.pendingCloudUpload = PendingSessionCloudUpload(session: session, logURL: completedLogURL)
}
```

דלתא:

| רכיב | תוצאה |
|---|---|
| local storage | נשמר |
| cloud | לא נפתח סשן |
| log | נשאר מקומי |
| UI | הודעת OK: אין GPS, נשאר בשעון |

### Branch 3: מעל דקה, יש GPS

הסשן נשמר מקומית ואז מוצגת בחירה:

- Upload: להעלות לענן.
- Keep Local: להשאיר רק מקומי בשעון.

```swift
struct PendingSessionCloudUpload: Identifiable {
    let session: Session
    let logURL: URL?
    var id: String { session.id }
}

func keepPendingSessionLocal() {
    guard let pending = pendingCloudUpload else { return }
    pendingCloudUpload = nil
    if uploadState.activeSessionId == pending.session.id {
        uploadState.reset(sessionId: nil)
    }
}

func uploadPendingSessionToCloud() {
    guard let pending = pendingCloudUpload else { return }
    pendingCloudUpload = nil
    uploadCompletedSessionToCloud(session: pending.session, logURL: pending.logURL)
}
```

דלתא:

| בחירה | תוצאה |
|---|---|
| Keep Local | הסשן נשאר רק בשעון, אין upload |
| Upload | נשלח start+end לשרת; הלוג נשלח רק אם סשן השרת הצליח |

## העלאה לענן אחרי אישור משתמש

העלאה כבר לא נעשית live תוך כדי הסשן. אחרי שהמשתמש בוחר Upload, בונים payload קומפקטי:

```swift
private func uploadCompletedSessionToCloud(session: Session, logURL: URL?) {
    let durMin = max(1, Int(session.duration / 60))
    let jmax = session.jumps.map(\.height).max() ?? 0
    let jcnt = session.jumps.count
    let airS = session.jumps.map(\.airtime).max() ?? 0
    let spdKmh = Int(session.maxSpeed * 3.6)
    let distKm = session.distance / 1000
    let avgKmh = session.avgSpeed * 3.6

    let jData = session.jumps.map { jump in
        let nearest = session.gpsPoints.min {
            abs($0.timestamp.timeIntervalSince(jump.startTime)) <
            abs($1.timestamp.timeIntervalSince(jump.startTime))
        }
        return [
            "t": Int(jump.startTime.timeIntervalSince(session.startTime)),
            "h": Int(jump.height * 100),
            "a": Int(jump.airtime * 10),
            "s": Int((nearest?.speed ?? 0) * 3.6),
            "d": Int(jump.jumpDistance * 10),
            "y": Int((nearest?.latitude ?? 0) * 1e4),
            "x": Int((nearest?.longitude ?? 0) * 1e4)
        ]
    }
}
```

השרת נפתח לפי נקודת GPS ראשונה:

```swift
guard let firstPoint = session.gpsPoints.first else {
    sessionNotice = SessionUserNotice(
        titleKey: "session.upload_failed_title",
        messageKey: "session.upload_no_gps_message"
    )
    return
}

let started = try await WatchSessionUploader.shared.start(
    lat: firstPoint.latitude,
    lng: firstPoint.longitude,
    startedAt: session.startTime
)
```

ואז נסגר עם נתוני הסשן:

```swift
let response = try await WatchSessionUploader.shared.end(
    sessId: started.sessId,
    durMin: durMin,
    jmax: jmax,
    jcnt: jcnt,
    airS: airS,
    spdKmh: spdKmh,
    distKm: distKm,
    avgKmh: avgKmh,
    track: finalTrack,
    jData: jData
)

uploadLogToCloud(logURL)
```

## פורמט הלוג הבינארי `.kslog`

הלוג החדש בנוי כך שיהיה יעיל יותר מ-CSV בזמן כתיבה, נפח ואנרגיה. במקום שורות טקסט ארוכות, כל sample נשמר כ-record בינארי עם מספרים scaled.

קובץ:

```text
[file header: 8 bytes]
[JSON metadata header: headerLength bytes]
[record 1]
[record 2]
...
```

### File header

| offset | גודל | טיפוס | ערך |
|---:|---:|---|---|
| 0 | 4 | ASCII | `KSLG` |
| 4 | 1 | UInt8 | version, כרגע `1` |
| 5 | 1 | UInt8 | reserved, כרגע `0` |
| 6 | 2 | UInt16 LE | אורך JSON header |

דוגמה:

```text
4b 53 4c 47 01 00 8e 01
K  S  L  G  v1  0  headerLength=398
```

### JSON metadata header

ה-JSON הוא UTF-8, ומכיל את הגדרות הסשן והעמודות:

```json
{
  "app": "Kiters",
  "format": "kslog",
  "version": 1,
  "session": "sample-session-0001",
  "date": "20260613_120000",
  "mode": "Standard",
  "devMode": false,
  "sampleRateHz": 50,
  "parameters": {
    "minSpeed": 4.1666666667,
    "takeoffG": 1.5,
    "landingG": 2.0,
    "minAirtime": 0.5,
    "maxAirtime": 8.0,
    "cooldown": 1.5
  },
  "columns": [
    "idx", "t", "ax", "ay", "az", "aM",
    "gx", "gy", "gz", "gM",
    "gvX", "gvY", "gvZ",
    "baro", "baseBaro", "spd", "lowG", "state", "evt"
  ]
}
```

### Sample record

Sample record מתחיל ב-byte מסוג `1`.

| סדר | גודל | טיפוס | סקייל |
|---:|---:|---|---|
| 1 | 1 | UInt8 | record type = `1` |
| 2 | 4 | UInt32 LE | `idx` |
| 3 | 4 | UInt32 LE | `t` במילישניות |
| 4 | 2 | Int16 LE | `ax * 1000` |
| 5 | 2 | Int16 LE | `ay * 1000` |
| 6 | 2 | Int16 LE | `az * 1000` |
| 7 | 2 | Int16 LE | `aM * 1000` |
| 8 | 2 | Int16 LE | `gx * 1000` |
| 9 | 2 | Int16 LE | `gy * 1000` |
| 10 | 2 | Int16 LE | `gz * 1000` |
| 11 | 2 | Int16 LE | `gM * 1000` |
| 12 | 2 | Int16 LE | `gvX * 1000` |
| 13 | 2 | Int16 LE | `gvY * 1000` |
| 14 | 2 | Int16 LE | `gvZ * 1000` |
| 15 | 4 | Int32 LE | `baro * 100` |
| 16 | 4 | Int32 LE | `baseBaro * 100` |
| 17 | 2 | UInt16 LE | `speed * 100` |
| 18 | 2 | UInt16 LE | `lowGCount` |
| 19 | 1 | UInt8 | state code |
| 20 | 2 | UInt16 LE | event byte length |
| 21 | N | UTF-8 | event |

גודל record ללא event:

```text
1 + 45 = 46 bytes
```

### Event record

Event record מתחיל ב-byte מסוג `2`.

| סדר | גודל | טיפוס | סקייל |
|---:|---:|---|---|
| 1 | 1 | UInt8 | record type = `2` |
| 2 | 4 | UInt32 LE | `idx` |
| 3 | 4 | UInt32 LE | `t` במילישניות |
| 4 | 2 | UInt16 LE | `speed * 100` |
| 5 | 1 | UInt8 | state code |
| 6 | 2 | UInt16 LE | event byte length |
| 7 | N | UTF-8 | event |

גודל record ללא event:

```text
1 + 13 = 14 bytes
```

### State codes

| code | state |
|---:|---|
| 0 | `idle` |
| 1 | `riding` |
| 2 | `airborne` |
| 3 | `cooldown` |
| 255 | unknown |

### ערכי sentinel

| שדה | sentinel | משמעות |
|---|---:|---|
| `Int16` sensor fields | `Int16.min` | אין ערך |
| `Int32` baro fields | `Int32.min` | אין ערך |
| `UInt16` speed | `0` | אין מהירות או מהירות 0 |

## דוגמת לוג

נוצרו שלושה קבצים לדוגמה:

- `docs/examples/sample-session.kslog` - קובץ בינארי אמיתי בפורמט החדש.
- `docs/examples/sample-session.kslog.hex` - hexdump של אותו קובץ.
- `docs/examples/sample-session.kslog.preview.txt` - preview מפוענח בסגנון `SessionLogger.buildShareText`.

הדוגמה כוללת:

- `state->IDLE`
- sample ב-`IDLE`
- `state->RIDING`
- sample takeoff ב-`RIDING`
- `state->AIRBORNE`
- sample באוויר
- sample landing
- event של `JUMP ACCEPTED`

דוגמת preview:

```text
Kiters Session Log
File: sample-session.kslog
Format: binary kslog v1
session: sample-session-0001
mode: Standard

CSV preview decoded from binary:
idx,t,ax,ay,az,aM,gx,gy,gz,gM,gvX,gvY,gvZ,baro,baseBaro,spd,lowG,state,evt
1,0.000,,,,,,,,,,,,,,0.00,,idle,state->IDLE
2,0.200,0.015,-0.010,0.020,0.027,0.020,0.010,0.000,0.022,0.000,0.000,-1.000,1013.24,1013.24,0.00,0,idle,
3,1.200,,,,,,,,,,,,,,5.20,,riding,state->RIDING
...
```

## נקודות בדיקה חשובות

כאשר בודקים התנהגות בשטח או בסימולטור, אלה המצבים שכדאי לוודא:

| תרחיש | ציפייה |
|---|---|
| סשן 30 שניות | לא נשמר, לא מועלה, לוג נמחק, הודעת OK |
| סשן 2 דקות בלי GPS | נשמר מקומית, לא מועלה, הודעת OK שאין GPS |
| סשן 2 דקות עם GPS ובחירת Keep Local | נשמר מקומית בלבד |
| סשן 2 דקות עם GPS ובחירת Upload | נשלח start לפי GPS ראשון, end עם summary, ואז log upload |
| GPS noisy | detector מקבל speed ממוצע rolling window של 5 נקודות |
| IMU ב-IDLE | לוג throttled, בערך 10Hz |
| IMU בזמן רכיבה/קפיצה | לוג full rate |
| קפיצה קטנה | לרוב גובה kinematic |
| קפיצה גדולה עם baro עקבי | blended/barometric |
| baro סותר airtime | מתעלמים מה-baro |
| confidence נמוך | לא נשלחת קפיצה ל-Session |

## סיכום קצר

האלגוריתם הנוכחי הוא לא רק state machine פשוט של low-g. הוא pipeline דו-שלבי:

1. `KitesurfSession` מזהה חלון קפיצה בזמן אמת לפי release spike אדפטיבי, gyro, baro baseline ו-landing.
2. `KitesurfJumpEngineV7` מנתח את החלון offline ומפיק גובה, airtime, rotations, distance ו-confidence.

סיום הסשן מנותק מהעלאה חיה: קודם שומרים מקומית, ואז המשתמש מחליט אם להעלות. סשנים מתחת לדקה נמחקים לגמרי. הלוג עבר ל-`.kslog` בינארי כדי לשמור יותר מידע בפחות נפח ועם פחות עלות I/O.
