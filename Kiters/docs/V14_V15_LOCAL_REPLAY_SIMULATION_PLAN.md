# Surfer V14/V15 Local Replay and Simulation Environment

תאריך: 2026-07-20
מבוסס על audit מלא של הקוד הקיים (ללא שינויי קוד — מסמך תכנון בלבד, כנדרש).

---

## 1. Executive Summary

הממצא המרכזי: **הארכיטקטורה הנדרשת ברובה כבר קיימת**. `JumpEngineV14`/`JumpEngineV15` הם ליבות טהורות (ללא CoreMotion/CLLocationManager/wall-clock), `JumpDetectorV14`/`JumpDetectorV15` הם ה-adapters שממירים בין sensor streams לבין קריאות ל-engine, ו-`Tools/JumpReplay` הוא כבר CLI ב-macOS שמריץ **בדיוק אותו קוד** (symlinks פיזיים, לא עותק) על לוגים אמיתיים, כולל תמיכה ב-V14/V15, comparison runner, ground-truth evaluation harness (precision/recall/F1), ו-golden-file regression (`--bless`/`--compare`).

מה **לא** קיים: (1) ממשק ויזואלי/timeline — הכל היום טקסט+JSON; (2) replay modes דטרמיניסטיים עם שעון — יש רק "מקסימום מהירות", אין real-time/accelerated/step; (3) debug sink מובנה וטיפוסי — יש רק מחרוזות free-text; (4) batch runner על תיקייה שלמה עם aggregate report; (5) ground truth harness מוכלל (כרגע קשור ל-Surfr reference ול-v10/v11 בלבד); (6) config snapshot דטרמיניסטי (יש תלות שקטה ב-`UserDefaults.standard` בתוך ה-adapter).

המלצה: **לא לבנות סימולטור חדש**. להרחיב את `Tools/JumpReplay` הקיים בשכבות: scheduler/clock, debug-sink טיפוסי, batch runner, ground-truth מוכלל, ו-desktop UI (SwiftUI+Charts) שקורא את ה-JSON artifacts שה-CLI כבר מייצר. זהו המשך ישיר של תבנית קיימת, לא ארכיטקטורה חדשה.

---

## 2. Existing Codebase Audit — מפת קבצים

```
Kiters/
├─ Kiters Watch App/
│  ├─ Models/Session.swift          — IMUSample, Jump, Session (המודל הקנוני הקיים)
│  ├─ Services/
│  │  ├─ JumpDetecting.swift        — הפרוטוקול המשותף לכל ה-adapters (JumpDetecting)
│  │  ├─ JumpEngineV14.swift        — ליבת V14 (טהורה, ~600+ שורות)
│  │  ├─ JumpDetectorV14.swift      — adapter V14 (CoreMotion↔engine)
│  │  ├─ JumpEngineV15.swift        — ליבת V15 (1282 שורות, טהורה)
│  │  ├─ JumpDetectorV15.swift      — adapter V15 (455 שורות)
│  │  ├─ V14HeightAnalyzer.swift    — מודול גובה משותף ל-V14
│  │  ├─ MotionManager.swift        — CoreMotion/CMAltimeter (live-only)
│  │  ├─ LocationManager.swift      — CLLocationManager (live-only)
│  │  ├─ WaterSubmersionManager.swift — submersion sensing (live-only)
│  │  ├─ SessionManager.swift       — orchestrator, UserDefaults, WKExtension (live-only)
│  │  ├─ SessionLogger.swift        — כותב .kslog בינארי (singleton, no-op כשלא פעיל)
│  │  └─ SensorRecordingDetector.swift — no-op detector ל"הקלטה בלבד"
├─ Package.swift                    — SPM target "WatchLiveSessionCore" ששולף בדיוק
│                                      את קבצי ה-engine (לא ה-adapters של החישה)
└─ Tools/JumpReplay/
   ├─ Package.swift                 — executable macOS CLI
   └─ Sources/JumpReplay/
      ├─ main.swift                 — CLI runner: parse args, load log, drive detector
      ├─ Loader.swift               — פרסר CSV/JSON/.kslog (v1+v2 בינארי)
      ├─ FormatDetector.swift       — coreMotion/android/onDevice heuristic
      ├─ ComparisonRunner.swift     — JumpComparisonRunner (v7..v13 היום)
      ├─ JumpEvaluationHarness.swift— ground-truth precision/recall/F1 (v10/v11 בלבד)
      ├─ SurfrGroundTruthLabelImporter.swift — פרסר תיוג ground-truth (Surfr JSON)
      ├─ Reporter.swift             — JSON export + bless/compare regression
      ├─ EngineE2ESelfTest.swift    — unit tests לכל ה-adapters (v11-v14)
      ├─ MockGPS.swift              — מזרים מהירות מדומה כשאין GPS בלוג
      └─ WatchSources/              — **symlinks פיזיים** לקבצי ה-Services המקוריים
```

**לוגים אמיתיים קיימים בשפע**: עשרות תיקיות `cloud_logs_*` בשורש הריפו, כל אחת עם `.kslog` אמיתי מסשנים על המים — בדיוק המקור שה-spec דורש כברירת מחדל.

---

## 3. Current V14 and V15 Architecture

`JumpEngineV14`/`V15` מקבלים קלט אך ורק דרך שיטות טהורות:
```swift
engine.addIMU(t: TimeInterval, verticalLoadG: Double, gyroRadS: Double)
engine.addRelativeAltitude(t: TimeInterval, altitudeM: Double)
engine.addAbsoluteAltitude(t: TimeInterval, altitudeM: Double)
engine.addGPS(t: TimeInterval, lat: Double, lng: Double, speedMS: Double)
```
אין קריאה ל-`Date()`, אין `CMMotionManager`/`CLLocationManager` בקובץ ה-engine, אין singleton state מלבד מה שמוזרק. פלט דרך `delegate.jumpDetected(_:)` ו-`onDebug: (TimeInterval, String) -> Void`. זו **בדיוק** ה-"Shared Jump Engine Core" שה-spec מבקש — כבר קיימת.

`JumpDetectorV14`/`V15` הם ה-adapters: ממירים `IMUSample` (הכולל gravity/pressure/absoluteAltitude) ל-vertical-load ולקריאות ה-engine, מנהלים monotonic clock דרך `bootWallClock` קבוע (לא `Date()` חי), ומטפלים בדגשים ספציפיים ל-V14 (on-demand absolute-altitude window) ו-V15 (`continuousNoWatchdog`). שדה `synchronousAnalysis: Bool` בפרוטוקול `JumpDetecting` הוא **המתג הקיים בין live לreplay** — כשהוא `true`, קריאות ל-engine מבוצעות `engineQueue.sync` (סינכרוני, כמו replay), כשהוא `false` — `engineQueue.async` (live).

---

## 4. Current Log Formats

`Loader.swift` תומך כבר בשלושה פורמטים דרך auto-detection:
- **CSV** — `coreMotion`/`android`/`onDevice`, מזוהה לפי magnitude וקטור הכבידה (`FormatDetector`).
- **JSON** — array של `RawRow`, או envelope עם `contentType`/`contentEncoding` (base64 → kslog).
- **`.kslog` בינארי** — הפורמט הפרודקשן עצמו (v1 ו-v2/KSLG2), עם רשומות טיפוסיות: motion, rawAccel, baro, absoluteAltitude, gps, submersion, event, sync, status, v13Audit. זהו כבר "המודל הקנוני האחיד" שה-spec מבקש בסעיף 5 — לא צריך מודל נוסף, `IMUSample` (Session.swift:157) **הוא** ה-`ReplaySensorRecord`: מכיל timestamp, accel×3, gyro×3, gravity, pressure, relativeAltitude+timestamp, absoluteAltitude+accuracy+precision+timestamp, attitudeQuaternion, submerged/waterDepth/waterPressure.

---

## 5. Required Refactoring for Replayability

**כמעט אין.** ה-abstraction שה-spec מבקש בסעיף 4 (`MotionSampleSource`/`PressureSampleSource`/`SimulationClock`) קיים כבר במובן פונקציונלי: ה-engine מקבל `t: TimeInterval` + ערכים מוכנים, וה-adapter (`JumpDetectorV14`) הוא ה"source" היחיד שמזין אותו — בין אם המקור האמיתי הוא `MotionManager` (live) או `Loader`+לולאת `main.swift` (replay). **אין צורך ליצור פרוטוקולים פורמליים נוספים** — זה יהיה כפילות מיותרת על סעיף 26 בהנחיות ("אל תיצור abstractions כפולים אם כבר קיימת שכבת providers").

שני חריגים אמיתיים שדורשים תשומת לב (לא שינוי מבני, אלא סגירת פער):
1. **`UserDefaults.standard`** — `JumpDetectorV14.makeConfigFromSettings()` (JumpDetectorV14.swift:118) נקרא גם ב-`init()` וגם ב-`reset()`, וקורא ישירות מ-`UserDefaults.standard`. ב-CLI זה עובד (macOS מחזיר defaults ריקים/קוד), אבל זה מפר את דרישת ה-config snapshot הדטרמיניסטי (סעיף 17/9): אין דרך היום להעביר קונפיגורציה מפורשת ל-replay ולדעת בוודאות שהיא זהה בכל הרצה.
2. **`SessionLogger.shared`** — singleton שנקרא ישירות מתוך ה-adapters (`logEvent`, `logSample`). זה **לא** בעיה בפועל: ב-replay הוא פשוט לא הופעל (`--with-logger` מבטל שתיקה) והופך ל-no-op. **אין צורך לשנות.**

---

## 6. Shared Engine Core

קיים. `Package.swift` (שורש הריפו) מגדיר target בשם `WatchLiveSessionCore` שמייצא בדיוק את `JumpEngineV12/V13/V14/V15` + `V14HeightAnalyzer` + `LiveSessionUploadState`, ומחריג במפורש את כל ה-adapters, ה-detectors וה-sensor managers. `Tools/JumpReplay` **לא** משתמש ב-package הזה — הוא סימלינק ישיר ל-source files (כולל ה-detectors, לא רק ה-engines). זו בחירה מכוונת ותקפה: מבטיחה `swift build` עצמאי בלי תלות cross-package, ומבטיחה "אותו קוד ליבה" ברמת קובץ, לא רק ברמת API.

**אין פעולה נדרשת** — לשמר כפי שהוא.

---

## 7. Live and Replay Sensor Providers

- **Live**: `MotionManager` → `IMUSample` → `SessionManager.handleIMUSample` → `jumpDetector.processSample`.
- **Replay**: `Loader.load()` → `[IMUSample]` (ממוין לפי timestamp מקורי) → `main.swift` לולאה → `detector.processSample`.

שני הנתיבים מזינים את **אותו** `JumpDetecting.processSample(_:)`. ה-emulation הקיים ל-V14 on-demand absolute-altitude window (main.swift:270-330, `feedAbsoluteAltitudes`/`emulateV14WindowTransition`) הוא דוגמה מדויקת לעיקרון הנדרש: לא לשנות את ה-engine, לחקות בקובץ ה-replay בלבד את התנהגות ה-hardware (callback ראשון מיידי בפתיחת חלון, ZOH).

**פער אמיתי**: main.swift כרגע מזרים samples בלולאה הדוקה ("מקסימום מהירות" תמיד) — אין `ReplayClock` שמכבד timestamps אמיתיים לצורך real-time/accelerated playback (ר' סעיף 11).

---

## 8. Replay Clock and Deterministic Scheduler

**לא קיים כיום, וזה הפער המרכזי היחיד בשכבת הליבה.** מכיוון שה-engine כבר "עיוור" ל-wall clock ומקבל `t` מפורש, בניית שכבת scheduler היא low-risk ולא נוגעת בכלל ב-engine/adapter.

```swift
protocol ReplayClock {
    func wait(untilSampleT sampleT: TimeInterval, sessionStartT: TimeInterval) async
}

struct MaxSpeedClock: ReplayClock {          // הקיים היום, במרומז
    func wait(untilSampleT: TimeInterval, sessionStartT: TimeInterval) async {}
}

struct WallPacedClock: ReplayClock {          // real-time (1x) ו-accelerated (Nx)
    let speedMultiplier: Double
    let clockStartT = ContinuousClock.now
    func wait(untilSampleT sampleT: TimeInterval, sessionStartT: TimeInterval) async {
        let targetElapsed = (sampleT - sessionStartT) / speedMultiplier
        let actualElapsed = clockStartT.duration(to: .now)
        let remaining = targetElapsed - actualElapsed.seconds
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
    }
}
```
Ordering policy לדגימות בעלות timestamp זהה: יש לבדוק אמפירית את סדר השדות כפי ש-`Loader`/`SessionLogger` כבר כותבים אותם (baro ZOH-held על כל IMU row → IMU קודם, pressure/absoluteAltitude מגיעים כ-side-channel דרך אותה שורה) — **לא לבחור סדר שרירותי**, לשמר את מה שה-adapter הקיים כבר עושה (`relativeAltitudeFrame` נקרא לפני `addIMU` בתוך אותו `submitToEngine` block, ר' JumpDetectorV14.swift:250-254).

---

## 9. Log Parsing and Timestamp Normalization

`Loader.swift` כבר עושה: session-relative time (`s.timestamp.timeIntervalSince(base)` בכל מקום), auto format detection, וטיפול מפורש בבעיית clock-domain (ר' `AltimeterTimestampNormalizer` ב-`MotionManager` — אותה בעיה מתועדת: CoreMotion timestamps ידועים כמחליפים domain בין boot-seconds ל-epoch-seconds, ויש anchor logic קיים). ה-replay (`JumpDetectorV14.alignedToMotionClock`) חוזר על אותו עיקרון — "timestamps בטווח 60s מה-motion clock נאמנים כפי שהם, אחרת fallback".

**פערים לסגירה** (לא ארכיטקטורה חדשה, רק דיווח):
- אין parse-report מפורש (duplicate timestamps / out-of-order / gaps / NaN) שמוצג למשתמש — הקוד *סובלני* (tolerant) אבל *שקט* (ר' סעיף 23 להלן).
- אין strict-mode שעוצר על violation.

---

## 10. Simulation Lifecycle

קיים במלואו ברמת ה-engine/adapter: `reset(mode:)` → session created; `processSample`/`processAbsoluteAltitude`/`updateGPS` → streaming; מעברי state דרך `onStateChanged`/`onDebug` (candidate/takeoff/airborne/apex/landing מזוהים כבר כ-string events, ר' JumpDetectorV14.swift:354 `handleDebug`); `endSession()` → flush + finalize. אירועי sensor dropout/gap כבר מטופלים בשכבת production (`MotionPipelineHealth`, watchdog ב-MotionManager) אך **לא מוזרקים ל-replay** — הדבר הזה הוא gap אמיתי: replay היום מניח stream רציף, ולא יכול לדמות "pressure unavailable" / "motion gap" מכוונים כדי לבדוק חוסן.

---

## 11. Replay Modes

| מצב | קיים? | הערה |
|---|---|---|
| 7.1 Real-time | ❌ | דורש `WallPacedClock` (סעיף 8) |
| 7.2 Accelerated (Nx) | ❌ | אותו scheduler, `speedMultiplier` |
| 7.3 Maximum-speed deterministic | ✅ | זה מה ש-`main.swift` עושה היום (ברירת מחדל, `--speed` הקיים הוא GPS mock speed, **לא** replay speed — שם מטעה שכדאי להבהיר) |
| 7.4 Step mode | ❌ | דורש debugger-כמו CLI/UI interaction |

---

## 12. V14/V15 Parallel Execution

`main.swift` כבר תומך ב-`--engine v14`/`--engine v15` בנפרד עם state מבודד מלא (כל קריאה יוצרת `JumpDetectorV14()`/`V15()` חדש — אין singleton). **`ComparisonRunner.swift` הוא הפער**: ה-`runEngine` switch שלו (שורה 119-130) תומך רק ב-v7..v13, **לא כולל v14/v15**. זו הרחבה ישירה וקטנה (2 case חדשים תואמים למה שכבר קיים ב-main.swift:213-216), לא בנייה מאפס.

---

## 13. Engine Comparison

`JumpComparisonRunner.buildReport` (ComparisonRunner.swift:206-266) כבר מממש **בדיוק** את האלגוריתם המבוקש בסעיף 13: nearest-time greedy pairing בתוך tolerance (`pairToleranceSec = 3.0`, קונפיגורבילי), added/removed/changedMetrics diff, JSON export. זה כמעט זהה למבנה `JumpComparison` המוצע ב-spec, רק בשמות שונים (`JumpEngineComparisonReport` במקום `JumpComparison`). **הרחבה נדרשת**: היום ההתאמה מבוססת רק על `takeoffTime` — ה-spec מבקש חלון סביב takeoff+apex+landing (עדיפות עתידית, לא קריטי כי `Jump` כבר נושא `apexTime`/`endTime`).

---

## 14. Ground Truth Annotation

קיים מנגנון עובד אך **צר**: `SurfrGroundTruthLabelImporter.swift` טוען קובץ ground-truth בפורמט JSON (`SurfrLabel`: `elapsedSec`, `height`, `airtime`, `distance`, ...) ל-`JumpEvaluationHarness`, שנשמר **בנפרד** מקובץ החיישנים (לא נוגע בלוג המקורי — תואם לדרישה). זהו כבר "ground truth store" נפרד. **פער**: השם/הפורמט קשור ל"Surfr" (אפליקציית reference חיצונית) ולא למודל תיוג כללי-ידני (takeoff/apex/landing משוער + label confidence + notes, כמבוקש בסעיף 14). דרוש parser/schema כללי נוסף (`GroundTruthLabel` גנרי) — לא להחליף את הקיים (הוא עדיין רלוונטי להשוואה מול Surfr), אלא להוסיף לצידו.

---

## 15. Metrics and Accuracy Analysis

`JumpEvaluationHarness.Metrics` (JumpEvaluationHarness.swift:113-121) כבר מחשב **בדיוק** precision/recall/F1/timing-error/airtime-error/height-error עם nearest-match matching (לא index-based!) — זה core ה-logic שסעיף 15 מבקש, קיים ועובד. **פער**: ה-harness "קשור בברגים" ל-v10/v11 בלבד (`runEngine`/`runV11` הם hardcoded); דרוש להכליל אותו לכל מנוע דרך `JumpDetecting` (שכולם מממשים), ולהוסיף breakdown לפי small/medium/large jump buckets (לא קיים כרגע).

---

## 16. Batch Runner

**חלקי.** `main.swift` כבר לולאה על `opts.inputs` (יכול לקבל כמה קבצים), ממשיך גם אם קובץ נכשל (`catch { allOK = false }`, עם `fputs` ל-stderr), אבל: (1) אין דגל `--input <dir>` שסורק תיקייה רקורסיבית — היום צריך להעביר רשימת קבצים מפורשת (shell glob עוקף את זה חלקית); (2) אין aggregate report (CSV/HTML) מעבר ל-`engine_comparison_report.json` שכבר קיים ב-`--compare-engines`; (3) אין failure-reason רשומה מסודרת (רק stderr טקסטואלי).

---

## 17. Configuration Management

**פער אמיתי**, ר' סעיף 5 לעיל — `JumpDetectorV14.makeConfigFromSettings()` קורא `UserDefaults.standard` בזמן `init`/`reset`, כך שאין snapshot מפורש+נשמר של הקונפיגורציה שהופעלה בכל run. יש לבנות מנגנון `--config <json>` ב-CLI שמזריק `V14Config`/`V15Config` מפורש (עוקף UserDefaults לגמרי ב-replay), ונשמר יחד עם ה-JSON output כ-`runManifest`.

---

## 18. Export

קיים: JSON מפורט (`Reporter.writeJSON`), comparison JSON, evaluation JSON (`JumpEvaluationHarness.writeJSON`). **לא קיים**: CSV session summary, CSV jump comparison, HTML report, chart images, regression report מסודר (יש רק pass/fail טקסטואלי מ-`Reporter.compare`).

---

## 19. Regression Framework

קיים בסיס עובד: `--bless`/`--compare`/`--expected` ב-main.swift, `Reporter.compare(actual:expected:)` (Reporter.swift:110-138) עם tolerances מוגדרים (airtime ±0.2s, height ±15%, apex ±0.3s). **חולשה אמיתית**: ההשוואה **index-aligned** (`for (i, e) in expected.jumps.enumerated()`) — אם מספר הקפיצות משתנה (בדיוק המקרה שרגרסיה אמורה לתפוס!), ה-diff נהיה חסר משמעות מהקפיצה הראשונה שהזיזה index. יש להחליף ללוגיקת nearest-time matching (כבר קיימת וזמינה ב-`ComparisonRunner.buildReport`!) — שימוש חוזר, לא קוד חדש.

---

## 20. Debug Trace Architecture

**קיים כבסיס לא-טיפוסי**: `engine.onDebug: (TimeInterval, String) -> Void` (JumpEngineV14) ו-`onDebugEvent` (V15, נראה ב-main.swift:246-251) כבר משדרים אירועי state machine כמחרוזות ("CANDIDATE...", "JUMP...", "REJECT..."). זה ה-hook הנכון להתלות עליו. **הפער**: לא טיפוסי (`String` free-text), אין protocol `JumpEngineDebugSink` פורמלי, ואין separation בין production (`no-op`/`SessionLogger.shared.logEvent`, קורה כבר בפועל ב-`JumpDetectorV14.handleDebug`) לבין replay (trace מלא ל-JSON). ה-production overhead כבר מינימלי (`#if DEBUG print` + לוגר), אז שדרוג ל-enum טיפוסי הוא תוספת ולא re-architecture.

---

## 21. Visualization and Timeline UI

**לא קיים כלל.** זו החתיכה הגדולה ביותר של עבודה חדשה אמיתית. הבחירה הטבעית (הקוד כבר ב-Swift, macOS target כבר קיים ב-`Tools/JumpReplay/Package.swift`): להוסיף target SwiftUI (`.executableTarget` נוסף או app bundle נפרד) שקורא את ה-JSON artifacts הקיימים (`ReplayReport`, `JumpEngineComparisonReport`) — **לא** להריץ engines בתוך ה-UI ישירות בהתחלה (מפריד concerns: CLI = מקור אמת דטרמיניסטי, UI = קריאה/הצגה בלבד), עם Swift Charts לסנכרון graphs (pressure/accel/gyro/state/confidence) + event markers.

---

## 22. Ground Truth Annotation UI

חלק מ-Phase 7 (UI), תלוי בסעיף 14/21. לא קיים.

---

## 23. Handling of Imperfect Logs

`Loader`/parsing היום **סובלני בשקט**: `SensorFormat` heuristic (ר' סעיף 9), gaps/duplicates לא מדווחים במפורש. יש כבר עדות מתועדת בקוד עצמו לבעיות אמיתיות שנצפו (`AltimeterTimestampNormalizer`, "CMLogItem.timestamp הופיע בשני clock domains") — כלומר לוגים "נקיים" באמת הכילו כבר היום בעיות אמיתיות שהמערכת מתקנת בשקט. פער מול הדרישה: להוסיף `ParseReport` מפורש (warnings array) שמוצג/נשמר, ומצב `--strict-parser`.

---

## 24. Required File Changes

| Path | אחריות | סיבת שינוי | סיכון | תאימות לאחור | בדיקות נדרשות |
|---|---|---|---|---|---|
| `Tools/JumpReplay/Sources/JumpReplay/ComparisonRunner.swift` | הוספת v14/v15 ל-`runEngine` switch | להשלים V14/V15 ל-parallel comparison (סעיף 12) | נמוך — תוספת case, אין שינוי ללוגיקה קיימת | מלאה | golden comparison JSON ל-log קיים |
| `Tools/JumpReplay/Sources/JumpReplay/Reporter.swift` | להחליף index-aligned compare ב-nearest-time matching | סעיף 19 — regression חסר משמעות כשמספר הקפיצות משתנה | בינוני — משנה סמנטיקת bless/compare קיימת, עלול "לשבור" expected files ישנים | דורש רה-בלס (`--bless`) לכל expected/*.json קיים | הרצת `--compare` על כל ה-goldens הקיימים, לוודא 0 false regressions |
| `Tools/JumpReplay/Sources/JumpReplay/JumpEvaluationHarness.swift` | להכליל ל-engine כלשהו דרך `JumpDetecting` במקום hardcoded v10/v11 | סעיף 15 | נמוך | מלאה (flag חדש `--evaluate-engine`) | הרצה מול קובץ Surfr קיים, לוודא מדדים זהים ל-v10/v11 |
| `Tools/JumpReplay/Sources/JumpReplay/main.swift` | הוספת `--config <path.json>` שמזריק V14Config/V15Config במפורש | סעיף 17 — reproducibility | נמוך | flag אופציונלי | הרצה עם/בלי flag, לוודא ברירת מחדל זהה |
| `Kiters Watch App/Services/JumpDetectorV14.swift` (ואותו ל-V15) | להוסיף init overload שמקבל `V14Config` מוזרק, לצד `makeConfigFromSettings()` הקיים ל-live | לנתק את replay מ-`UserDefaults.standard` (סעיף 5/17) | **בינוני** — קובץ production, גם אם live path לא משתנה | production init ללא ארגומנט נשאר זהה | E2E self-test קיים (`EngineE2ESelfTest`) חייב לעבור ללא שינוי |

---

## 25. New Files (עבודה חדשה, ללא נגיעה בקיים)

| Path (מוצע) | אחריות | Phase |
|---|---|---|
| `Tools/JumpReplay/Sources/JumpReplay/ReplayClock.swift` | `ReplayClock` protocol + `MaxSpeedClock`/`WallPacedClock`, `--mode-speed`/`--realtime` CLI flags | Phase 3 |
| `Tools/JumpReplay/Sources/JumpReplay/DebugSink.swift` | `JumpEngineDebugEvent` enum טיפוסי + `JumpEngineDebugSink` protocol, `JSONDebugSink` למימוש replay | Phase 3 |
| `Tools/JumpReplay/Sources/JumpReplay/GroundTruthLabel.swift` | סכמת ground-truth כללית (לא-Surfr): takeoff/apex/landing/height/airtime/confidence/notes, `GroundTruthLabelImporter`/`Exporter` | Phase 7 |
| `Tools/JumpReplay/Sources/JumpReplay/BatchRunner.swift` | `--input <dir>` סריקה רקורסיבית, aggregate CSV/JSON report, per-log failure isolation | Phase 8 |
| `Tools/JumpReplay/Sources/JumpReplay/HTMLReportExporter.swift` | ייצוא HTML (session report + regression report) | Phase 8 |
| `Tools/JumpViewer/` (SwiftUI app, target חדש) | Desktop UI: file picker, engine picker, playback controls, Swift Charts timeline, jump inspector, engine-comparison view | Phase 6 |
| `Tools/JumpReplay/Sources/JumpReplay/ParseReport.swift` | warnings מפורשים מ-`Loader` (duplicate/out-of-order/gap/NaN), strict/lenient mode | Phase 2 |

---

## 26. Required Testing Strategy

- **Parser**: קובץ תקין, שדות חסרים, timestamps out-of-order, NaN/Infinity, `.kslog` v1 מול v2 — להוסיף ל-`EngineE2ESelfTest.swift` הקיים (1212 שורות, כבר תבנית self-test מוכרת) ולא לבנות harness נפרד.
- **Replay clock**: לוודא שתוצאות V14/V15 **זהות ביט-לביט** בין `MaxSpeedClock` ל-`WallPacedClock` על אותו לוג — זו בדיקת הרגרסיה הכי חשובה בכל הפרויקט (מוכיחה שהשעון לא משפיע על detection).
- **Comparison/regression**: להריץ nearest-time compare החדש על כל `expected/*.json` הקיימים ולוודא 0 diffs לא-מוסברים לפני מיזוג.
- **Config injection**: להריץ replay עם/בלי `--config`, לוודא שברירת המחדל (ללא flag) תואמת בדיוק ל-`V14Config()`/`V15Config()` הסטטי הנוכחי.

---

## 27. Incremental Implementation Phases

| Phase | תוכן | תלות | היקף |
|---|---|---|---|
| 0 | Audit (מסמך זה) | — | הושלם |
| 1 | Config injection (עוקף UserDefaults ב-replay) + parse-report warnings | — | קטן |
| 2 | Parser strict/lenient + ParseReport | Phase 1 | קטן |
| 3 | ReplayClock (real-time/accelerated/step) + typed DebugSink | — | בינוני |
| 4 | ComparisonRunner: הוספת v14/v15; Reporter: nearest-time regression | — | קטן |
| 5 | Regression: הרצה על כל הגולדנים הקיימים, בלס מחדש, tolerance policy מתועד | Phase 4 | קטן |
| 6 | Desktop UI (SwiftUI+Charts) — קורא JSON קיים, playback controls | Phase 3 | גדול |
| 7 | Ground truth כללי + matching + metrics buckets (small/medium/large) | — | בינוני |
| 8 | Batch runner (`--input dir`) + aggregate CSV/HTML | — | בינוני |
| 9 | Validation מול ריצות watch אמיתיות (kslog מהענן) | הכל | מתמשך |

---

## 28. Risks and Needs Verification

1. **סדר streams בעלי timestamp זהה** — לפני מימוש ה-scheduler (Phase 3) יש לאמת אמפירית (לא לנחש) את סדר ה-callbacks כפי שקורה היום ב-live (`JumpDetectorV14.processSample`, קורא ל-baro לפני IMU באותו block) ולשמר אותו זהה ב-scheduler.
2. **שינוי סמנטיקת bless/compare (סעיף 19/24)** — מעבר ל-nearest-time matching ישנה איזה diffs נחשבים regression. יש להריץ side-by-side מול הלוגיקה הישנה על **כל** ה-goldens הקיימים לפני שמחליפים.
3. **הזרקת Config ל-`JumpDetectorV14`/`V15`** — נוגע בקובץ production. חובה E2E self-test ירוק + ביקורת שה-live path (ללא injection) לא משתנה כלל.
4. **"V15 clean engine" ו-"V14 relative-height upgrade" (זיכרון)** — לפי הזיכרון הקיים V14 עבר שדרוג ל-relative-height-first לאחרונה (20/07); יש לוודא שה-Height Analyzer version בזמן ההרצה נרשם ב-run manifest (סעיף 17) כדי ש-regression לא יתבלבל בין קונפיגורציות גובה שונות.
5. **`--speed` בשם כפול** — הדגל הקיים `--speed` הוא GPS mock speed, לא replay clock speed. הוספת `WallPacedClock` תצטרך שם דגל אחר (`--replay-speed`?) כדי לא להתנגש סמנטית — לבדוק מול המשתמש.

---

## 29. Final Recommendation

להתחיל מ-**Phase 1+4** (config injection + regression matching + הוספת v14/v15 ל-ComparisonRunner) — אלה תיקונים קטנים על תשתית קיימת שכבר עובדת, מסירים את הפערים המסוכנים ביותר (רגרסיה חסרת משמעות, קונפיגורציה לא-דטרמיניסטית) בלי לגעת ב-engine עצמו. **Phase 6 (UI)** הוא ההשקעה הכי גדולה וכדאי לדחות אותה עד שה-CLI/regression/ground-truth generalization (Phases 1-5, 7) יציבים — כי ה-UI רק קורא artifacts, ולא כדאי לבנות עליו לפני שהפורמט שלהם התייצב.
