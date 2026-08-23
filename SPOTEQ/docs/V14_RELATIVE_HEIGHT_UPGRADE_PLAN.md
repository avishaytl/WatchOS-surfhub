# V14 Relative Height Upgrade Plan

## 1. Executive Summary

מיפוי הקוד הקיים (`JumpDetectorV14.swift` 519 שורות + `JumpEngineV14.swift` 924 שורות, ותלויות ב-`MotionManager.swift`, `SessionManager.swift`, `Models/Session.swift`) מגלה חדשות טובות: **ה-detection של V14 כבר לא תלוי ב-absolute altitude**. ה-state machine (`riding → airborne → landingConfirm`) פועל כולו על IMU (vertical load, gyro) ועל הערוץ היחסי (baro relative altitude) — ל-baseline, ל-water-spike filtering ול-landing stability. Absolute altitude נכנס לתמונה רק בשלב **חישוב הגובה הסופי** בתוך `finalize()` (`JumpEngineV14.swift:685-831`), שם הוא כרגע מקבל **עדיפות ראשונה** על פני היחסי (שורות 733-742).

לכן זה **לא** משימת "בניית שכבת גובה חדשה מאפס" — זו משימה ממוקדת בהרבה:
1. להפוך את סדר העדיפות של מקורות הגובה כך שהיחסי (relative) יהיה ראשי וה-absolute יהפוך לאבחוני/אופציונלי בלבד.
2. לבנות שכבת ניתוח עשירה יותר (baseline quality, apex quality, height confidence נפרד מ-detection confidence) שהספק דורש, בלי לגעת ב-state machine.
3. לתקן נקודת קונפליקט אמיתית שהתגלתה באודיט: כשל גובה מוחלט (`noHeightSource`, `JumpEngineV14.swift:774-777`) כרגע **מוחק** קפיצה שה-IMU כבר אישר — זה מנוגד ישירות לדרישה בסעיף 20 של הספק ("כשל בגובה לא מוחק קפיצה שאומתה ב-IMU"). זו נקודת השינוי הארכיטקטונית האמיתית היחידה בתוכנית הזו.

כל שאר הדרישות (ללא GPS חובה, ללא absolute חובה, ring buffer מסונכרן, shadow mode) כבר קיימות בחלקן בקוד או ניתנות להוספה נקודתית ללא רה-רייט.

## 2. Existing V14 Detection Flow

State machine טהור ב-`JumpEngineV14.swift` (enum `Phase`, שורה 281): `.riding` → `.airborne(Flight)` → `.landingConfirm(Flight)` → emit → `.riding`.

**Riding (baseline מתמשך):**
- Baseline = median גולש של הערוץ היחסי (baro) על חלון `baselineWindowSec` (3-5s, ברירת מחדל 4s) — `medianBaseline(before:)`, שורה 860-866.
- Smoothed vertical load = ממוצע נגרר של gravity-projected acceleration על `loadSmoothingSec` (0.15s) — `updateSmoothedLoad`, שורה 849-855.
- `verticalLoadG` מחושב ב-adapter (`JumpDetectorV14.swift:374-382`) כ-`userAcceleration·ĝ + |g|` — פלטפורמה-נטרלי, כבר לא תלוי ב-Apple API ספציפי.

**Takeoff (`trackTakeoff`/`tryOpenTakeoff`, שורות 528-582):**
- `updateUnweight` (504-526): smoothed load ≤ `unweightG` (0.75g) במשך `unweightSec` (0.35s), עם duty-cycle ≥65% (לא streak מוחלט — סיבוב בזמן ההמראה מכניס רעש לגרביטציה המשולבת).
- Pop אופציונלי (`popG`=1.6g, `popLeadSec`=0.8s) — gate רק אם `requirePop=true` (כרגע false).
- Retrigger guard (`retriggerGuardSec`=0.8s).
- **Takeoff turbulence gate** (backward scan, שורות 546-560): gyro/load בחלון `[start-0.3s, start]` — זה ה-gate שסגר את כל ה-false positives בשטח (זיכרון: shakes/drops/throws).
- GPS gate **אופציונלי בלבד** (שורות 562-568): פועל רק אם יש fix; ללא GPS אין gate כלל.
- Takeoff time = תחילת חלון ה-unweight — **IMU בלבד**, לא תלוי בברומטר.
- ברגע הפתיחה: `openAbsoluteWindow` (835-839) — קורא ל-`onAbsoluteWindowRequest(true, …)`, שמזה ל-`MotionManager.beginAbsoluteAltitudeWindow` (`SessionManager.swift:287-289`). **זו הפעלה של הזרם, לא תנאי לזיהוי** — ה-candidate כבר פתוח לפני הקריאה הזו.

**Airborne (`detectTouchdown`, שורות 599-638):**
- Apex tracking על relative (`addRelativeAltitude`, 433-437) ו-absolute (`recordAbsolute`, 640-646) — שני הערוצים רק **נאספים**, לא משפיעים על הזיהוי.
- Touchdown = impact ≥`landingImpactG` (1.9g) עם gyro מיושב (≤`landingMaxGyroRadS`=6 rad/s), **או** load חוזר מעל `flightLoadCeilingG` (0.85g) ומחזיק `flightEndHoldSec` (0.25s).
- `maxFlightSec` (20s) — התקרה הפיזית היחידה.

**Landing confirm (`confirmLandingIfStable`, שורות 650-669):**
- baseline יציב = span ≥`landingStableSec` (2s) עם spread ≤`landingStableBandM` (0.6m) על הערוץ היחסי.
- Timeout (`landingConfirmTimeoutSec`=6s) → emit בכל זאת עם `landingConfirmed=false`.

**Emit → Finalize (שורות 671-831):** כאן, ורק כאן, נכנס חישוב הגובה (ראה סעיף 3).

## 3. Current Absolute-Altitude Dependencies

| מיקום | תפקיד | חובה לזיהוי? |
|---|---|---|
| `JumpEngineV14.finalize()` שורות 710-742 | `heightAbsolute` מקבל **עדיפות ראשונה** על פני `heightRelative` כשהערוץ "בריא" (≥2 ערכים שונים, יש דגימות in-flight וגם post-landing) | **לא** לזיהוי, **כן** לבחירת מקור הגובה |
| `JumpDetectorV14.processAbsoluteAltitude`/`processSample` (292-311, 261-277) | מזין את הערוץ ל-engine, רק בזמן שהחלון פתוח | לא |
| `onAbsoluteWindowRequest` → `MotionManager.beginAbsoluteAltitudeWindow`/`endAbsoluteAltitudeWindow` (`MotionManager.swift:613-638`) | הפעלה/כיבוי פיזי של `CMAltimeter.startAbsoluteAltitudeUpdates` | לא — on-demand, לא רץ כברירת מחדל |
| `JumpDetectorV14.readinessReport()` (159-189) | רושם `absolute altitude: unavailable (height cross-check disabled)` **ל-log בלבד** — **לא** מתווסף ל-`blockers` | **כבר תואם לספק**: לא חוסם |
| `MotionManager.startAbsoluteAltitudeLocked` (677-682) | `guard CMAltimeter.isAbsoluteAltitudeAvailable() else { return }` — נכשל בשקט, לא קורס | **כבר תואם לספק** |
| `SessionManager.makeJumpDetector` (518-523) | גם אם `readiness.isReady == false`, V14 עדיין נבחר ורץ (`"V14 selected despite readiness issue; keeping V14 active"`) | **כבר תואם לספק** |

**מסקנת האודיט המרכזית:** אין היום שום נתיב קוד שבו חוסר ב-absolute altitude מונע session, candidate, jump, או session-save. התלות היחידה היא **סמנטית**: כש-absolute כן זמין וקורא ≥2 ערכים שונים, הוא **דוחק** את היחסי מלהיות מקור הגובה (שורה 735-739: `if let h = passesCeiling(heightAbsolute, …) { height = h; source = .absoluteAltitude }` נבדק **לפני** relative). זה בדיוק מה שהספק אוסר (סעיף 3, 11) וזה מה שהתוכנית הזו הופכת.

## 4. Components That Must Remain Unchanged

אסור לגעת (ללא evidence מלוגים):

- `updateUnweight`, `trackTakeoff`, `tryOpenTakeoff` — כל לוגיקת ה-takeoff, כולל duty-cycle, pop, retrigger guard.
- Takeoff turbulence gate (backward scan `tryOpenTakeoff` 546-560 + forward scan ב-`addIMU` case `.airborne` 371-385) — זה ה-gate שסגר את כל ה-phantoms בשטח (זיכרון `v14-hybrid-engine`).
- `detectTouchdown`, `updateFlightIMU` — קביעת touchdown (impact/ceiling), rotation settling.
- `confirmLandingIfStable` — לוגיקת ה-landing-baseline stability (משתמשת כבר ב-relative altitude, לא ב-absolute — **לא נוגעים**).
- כל הערכים המספריים ב-`V14Config` שמתארים IMU/state-machine: `popG`, `unweightG`, `unweightSec`, `unweightDutyCycleFraction`, `landingImpactG`, `flightLoadCeilingG`, `flightEndHoldSec`, `landingMaxGyroRadS`, `takeoffMaxGyroRadS`, `takeoffMaxLoadG`, `takeoffScanBackSec/ForwardSec`, `minAirtimeSec`, `maxFlightSec`, `retriggerGuardSec`, `minTakeoffGpsSpeedMS`.
- `JumpDetectorV14.verticalLoadG(of:)` — נוסחת ה-load הבסיסית.
- `airtimeSec = touchdown - takeoffT` — נשאר מבוסס IMU בלבד, ללא שינוי.
- **`belowMinRise`, `relativeContradictsBallistic`, `ballisticUncorroborated`** (שורות 760-771, 781-785) — אלה false-positive filters מכוילים על לוגים אמיתיים (זיכרון: "0714 log 10→7: killed 4.45m/6.27m…"), **לא** "כשל טכני בגובה" אלא "הגובה שנמדד סותר את הפיזיקה/הסף שהמשתמש קבע". ראו דיון קריטי בסעיף 13 — אלה נשארים כמו שהם, בכוונה, למרות המתח עם סעיף 20 של הספק.

## 5. Proposed Relative-Altitude Architecture

לא נבנה rewrite; מוסיפים שכבת post-processing מעל ה-`Flight` הקיים, ומחליפים רק את גוף `finalize()` שמחשב גובה (713-785). מבנה קבצים חדש (תואם למוסכמות התיקייה — כל מנוע חי בקובץ Service בודד):

```
JumpEngineV14.swift          — ללא שינוי ב-state machine; finalize() מאציל ל-V14HeightAnalyzer
V14HeightAnalyzer.swift      — חדש: baseline / filter / apex / height / confidence, פר-Flight, טהור (בלי side effects)
```

לא נדרשים V14JumpDetector/V14JumpAnalyzer/V14RelativeAltitudeTracker נפרדים כפי שהספק מציע בסעיף 12 — ה-`Flight` struct כבר **הוא** ה-ring buffer הסינכרוני (`absSamples: [TimedValue]`, וההיסטוריה הגלובלית `relHistory`), וכבר יש הפרדה נקייה בין detection ל-finalize. הוספת 6 מחלקות תיצור abstraction כפול. `V14HeightAnalyzer` הוא struct/enum טהור עם פונקציה אחת: `analyze(flight:) -> V14HeightResult`.

זרימה בפועל (ללא שינוי בזרימת ה-state machine, רק תוכן `finalize`):

```
touchdown מאושר (landingConfirm ידי ה-IMU/relative stability — ללא שינוי)
        ↓
Flight מכיל: baselineRelM, maxRelM/T, relHistory שמור לפני touchdown,
             absSamples (אם נאספו), airtime, takeoffT/landingT (IMU)
        ↓
V14HeightAnalyzer.analyze(flight) — טהור, לא נוגע ב-phase
        ↓
    1. Baseline quality (מתוך relHistory שכבר קיים ב-relHistory, לא נתון חדש)
    2. Apex quality (מתוך maxRelM/maxRelT שכבר נאספים)
    3. heightRelative ראשי; heightAbsolute → diagnostic בלבד
    4. heightConfidence נפרד מ-detectionConfidence
        ↓
V14Jump מורחב (backward compatible) → Jump (Session.swift) — ללא שינוי סכימה
```

## 6. Sensor Timestamp Synchronization

**כבר קיים ותקין, לא נוגעים:** `alignedToMotionClock` (`JumpDetectorV14.swift:401-404`) מיישר baro/absolute ל-motion clock ב-±60s tolerance; `relativeAltitudeFrame` (389-396) עושה de-dup לפי timestamp הברומטר עצמו (`barometerTimestamp`), לא לפי index — כלומר כבר אין הנחת sampling-rate משותף. `Flight.absSamples`/`relHistory` הם `[TimedValue { t, v }]` הממוינים כרונולוגית מטבעם (נוספים לפי סדר קבלה מונוטוני — `guard t > lastRelT`/`lastAbsT`).

מה שחסר: max-age לדגימה בודדת בתוך ה-baseline/apex analysis (כרגע יש רק חלון זמן `baselineWindowSec`, אין בדיקת "פער בין דגימות עצמו"). ראו סעיף 7 — `AltitudeBaseline.sampleGapMaxSec` חדש.

## 7. Pre-Takeoff Baseline Algorithm

הליבה (median על `baselineWindowSec`) כבר קיימת ב-`medianBaseline(before:)` (860-866) ומוזנת ל-`Flight.baselineRelM` ב-`tryOpenTakeoff` (570). **לא נוגעים בזה** — זה כבר חלק מנוסחת ה-detection (baseline נחוץ כדי לפתוח candidate, אם כי candidate נפתח גם בלי baseline: `baseline.map(fmt) ?? "n/a"`, שורה 581 — baseline יכול להיות `nil` ועדיין candidate נפתח).

**תוספת (measurement layer בלבד, לא נוגעת בפתיחת candidate):**

```swift
struct V14AltitudeBaseline {
    let altitudeMeters: Double?
    let sampleCount: Int
    let varianceM: Double
    let maxSampleGapSec: Double
    let isStable: Bool      // variance ≤ stabilityVarianceM AND sampleCount ≥ minBaselineSamples AND maxSampleGapSec ≤ maxGapSec
    let quality: Double     // 0-1, מ-variance + coverage + freshness
}
```

מחושב מתוך `relHistory` הקיים (`[start - preTakeoffWindow, start - guardWindow]`) — לא נאסף נתון חדש, רק ניתוח נוסף על מה שכבר נאסף. ערכים מוצעים כ-config (**לא להמציא — יש לכייל מלוגים אמיתיים בפאזה 5**):

```swift
var preTakeoffWindowSec = 4.0   // = baselineWindowSec הקיים, לשימוש חוזר
var guardWindowSec = 0.1        // חוצץ קטן לפני takeoffT עצמו
var stabilityVarianceM = 0.3    // TBD מכיול — לא ערך מומצא סופי
var maxSampleGapSec = 3.0       // תלוי בקצב baro שנמדד (2.56s בלוג 20260717 לפי v14-hybrid-engine memory!)
```

**הערה קריטית:** זיכרון הפרויקט (`v14-hybrid-engine.md`) מתעד שב-log 20260717_145840 קצב הברומטר היה 2.56s (לא 1Hz) וגרם ל-41% מה-candidates עם `baseline=n/a`. `maxSampleGapSec` חייב להיגזר מהמדידה הזו, לא מהנחה של 1Hz — זו בדיוק הדוגמה לכלל "אין להמציא sampling rates" בסעיף 20.

**Unstable baseline → לא מוחקים קפיצה:** אם `isStable == false`, ה-Flight ממשיך ל-finalize כרגיל; ה-height source יורד ל-fallback הבא (ballistic, אם קיים) עם `heightFailureReason = .unstableBaseline`, ולא ל-`REJECT`.

## 8. Altitude Filtering Strategy

הערוץ היחסי הקיים כבר עובר water-spike filter ברמת ה-engine (`relStepRejectM`=10m, `relStepReacceptCount`=3, שורות 412-424) — **זה נשאר**, הוא detection-adjacent (מגן על ה-baseline מ-poisoning). בעיה מתועדת בזיכרון: reaccept-after-3 קיבל ערכי טבילה של −244m/−311m כ"datum shift" לגיטימי (log 20260717 analysis) — **זה לא בסקופ של התוכנית הזו** (שינוי סף = שינוי detection-adjacent gate, דורש evidence נפרד; ראו סעיף 19).

מעל הערוץ המסונן-בפילטר-הקיים, שכבת ה-measurement מוסיפה **רק** ל-baseline/apex window (לא לזרם הרציף):
- Moving median קצר (כבר יש — `median()` helper, שורה 904-909, נעשה שימוש חוזר).
- EMA קל לגזירת שיפוע (לצורך vertical velocity, סעיף 10) — לא Kalman, לא Savitzky-Golay live (הצעת הספק ל-offline/replay בלבד, לא live).

ברירת מחדל: **ה-median הקיים + חלון derivative פשוט**. שום smoothing חדש לא מוחל על ה-apex עצמו לפני שנקבע (כדי לא "לגלח" את השיא, כפי שהספק מזהיר בסעיף 6).

## 9. Apex Detection Strategy

היום: `flight.maxRelM`/`maxRelT` הוא max sample בודד (שורה 433-437), ללא persistence check, ללא דחיית spike בודד ב-apex עצמו (זה שונה מה-relStepReject, שרץ על הזרם השוטף לפני שהוא נכנס ל-Flight — spike בזמן airborne עצמו לא נבדק שוב).

תוספת ב-`V14HeightAnalyzer` (לא ב-airborne live path — post-hoc על `flight.absSamplesRel`/הרחבה קטנה שנוספת ל-`Flight` כדי לשמור את כל הדגימות היחסיות בזמן הטיסה, לא רק את המקסימום):

```swift
struct V14ApexResult {
    let timestamp: TimeInterval
    let relativeAltitudeMeters: Double
    let confidence: Double       // מ-persistence + proximity לאמצע החלון + עקביות עם gyro/load
    let wasInterpolated: Bool
    let sampleQuality: Double
}
```

דורש שינוי קטן ולא-מסוכן ב-`Flight`: הוספת `relFlightSamples: [TimedValue]` (כבר יש מבנה זהה ל-`absSamples`) שנאסף ב-`addRelativeAltitude` case `.airborne` (שורה 433-437) — תוספת אגרגציה, **לא** משנה שום תנאי airborne/touchdown קיים.

## 10. Relative Jump Height Calculation

```
heightRelative = apexRelativeAltitude − takeoffBaselineRelativeAltitude
```

זה **כבר** מחושב היום (`heightRelative`, שורות 698-703) — השינוי היחיד הוא ב**עדיפות**: הופך למקור ברירת המחדל הראשי במקום שני. `heightAbsolute` ממשיך להיות מחושב **בדיוק כמו היום** (peak − median post-landing, עם health check ≥2 ערכים שונים) אך הופך ל-**diagnostic field** בלבד — לא נבחר כ-source אלא אם המשתמש/QA מבקש explicit override לצורך debugging (feature flag, סעיף 17).

`passesCeiling` (הפיזיקה ceiling מול ballistic×1.3) **נשאר** — הוא מגן פיזי ולא תלוי במקור. הסדר החדש בקוד:

```swift
if let h = passesCeiling(heightRelative, ceiling: ballisticCeiling, "relative") {
    height = h; source = .relativeAltitude
} else if let h = passesCeiling(heightAbsolute, ceiling: max(ballisticCeiling, cfg.absoluteTrustFloorM), "absolute"), diagnosticAbsoluteOverrideEnabled {
    height = h; source = .absoluteAltitude   // רק מאחורי feature flag, לצרכי debug/calibration
} else if cfg.allowBallisticHeightFallback {
    …
} else {
    // heightFailureReason = .noHeightSource — עדיין EMIT, לא REJECT (ראו סעיף 13)
}
```

## 11. Airtime and Vertical Metrics

Airtime **ללא שינוי**: `touchdown − takeoffT`, שניהם IMU-timestamps (סעיף 2). מוסיפים ל-log (לא ללוגיקת ה-gate) את ההשוואה לברומטר:

```swift
let barometricRiseStartT: TimeInterval? // הרגע שה-relative channel חצה מעל baseline+threshold קטן
let barometricReturnT: TimeInterval?    // הרגע שחזר לרמת ה-baseline
let timingDifferenceSec: Double?        // = imuTakeoff/Landing − barometric
```

זה diagnostics-only (סעיף 9 בספק) — לא מחליף טיימינג, רק לומדים ממנו לעתיד.

Vertical velocity: נגזרת יציבה מעל `relFlightSamples` (סעיף 9) — לא הפרש בין 2 דגימות רועשות:

```swift
maxAscentRateMps / averageAscentRateMps / maxDescentRateMps / averageDescentRateMps / timeToApexSec
```

מדדי אבחון בלבד — **אינם** קלט לשום gate קיים.

## 12. Detection Confidence vs Height Confidence

היום `confidence` הוא ערך יחיד (`finalize`, 794-801) שמערבב אמון-בזיהוי (pop, GPS, turbulentTakeoff) עם אמון-במדידה (`heightAbsolute != nil`, `heightRelative >= minRise*0.5`). זה בדיוק הבעיה שהספק מצביע עליה.

**פיצול (שינוי לא-הרסני, מוסיף שדות, לא מסיר):**

```swift
detectionConfidence = f(popImpulse, launchGPS, landingConfirmed, turbulentTakeoff)   // כמו היום, בלי רכיבי גובה
heightConfidence     = f(baselineQuality, apexQuality, altitudeCoverage, sourceRank) // חדש
confidence (legacy)  = min(detectionConfidence, weighted-combine)  // נשאר לתאימות UI קיים, מחושב מה-2 החדשים
```

ה-`confidence` הקיים ב-`Jump` (Session.swift:87) ובשרת/UI **לא נשבר** — ממשיך להתקיים כ-derived value.

## 13. Failure and Degraded Modes

זו הנקודה הכי חשובה בתוכנית — ומקום שבו יש **קונפליקט אמיתי** בין הקוד הקיים לספק שצריך להיפתר במפורש, לא לטשטש.

**מה שהספק דורש (סעיף 20):** "כשל בגובה לא מוחק קפיצה שאומתה ב-IMU".

**מה שקורה היום ב-`finalize()`:**
1. `airtimeTooShort` (692-695), `maxFlightExceeded` (602-606) — אלה **detection-level** rejects (לא height), נשארים `return nil`. תקין.
2. `noHeightSource` (774-777) — מגיע רק אם `allowBallisticHeightFallback=false` וגם absolute וגם relative נכשלו. זה **בדיוק** "כשל טכני בגובה מוחק קפיצה שה-IMU אישר (touchdown+landingConfirm כבר קרו)". **סותר את הספק — משתנה**: הופך מ-`return nil` ל-emit עם `heightSource = .unavailable`, `heightM = 0`(או ‎nil אם משנים סכימה — נשאר `0` לתאימות `Jump.height: Double`, לא `Double?`), `heightFailureReason = .insufficientPreTakeoffSamples/.unstableBaseline/...`.
3. `belowMinRise` (781-785) — **לא** כשל טכני; הגובה **נמדד** אבל קטן מהסף שהמשתמש קבע (1/1.5/2m). זו החלטת "לא נספר כקפיצה" מכוונת שכבר מתועדת בקוד כ"חלק מנוסחת הזיהוי" (הערה בקוד `JumpEngineV14.swift:68`). **נשאר `return nil`** — לא כשל מדידה, זו הגדרת ה-domain (קפיצה של 20cm היא לא "קפיצה" מבחינת המשתמש). מומלץ להשאיר, אך זו נקודה שכדאי לאשר מול המשתמש (סעיף 19).
4. `relativeContradictsBallistic` / `ballisticUncorroborated` (760-771) — אלה rejects **מכוילים על לוגים אמיתיים** (זיכרון v14-hybrid-engine: "killed 4.45m/6.27m … kept 4.62m"), הם false-positive filter על מועמד IMU-בלבד שאין לו שום עדות לחץ תומכת. יש כאן מתח עם רוח הספק, אבל שינוי שלהם דורש evidence מלוגים (סעיף 20 של הספק עצמו אוסר שינוי thresholds ללא ראיה) — **לא נוגעים בפאזה הזו**. מתועד כ-known tension, לא "נפתר בשקט".

**HeightFailureReason (חדש, לא שובר תאימות — שדה אופציונלי חדש ב-`V14Jump`/`Jump`):**

```swift
enum V14HeightFailureReason: String {
    case altimeterUnavailable
    case insufficientPreTakeoffSamples
    case unstableBaseline
    case missingApexSamples
    case excessiveSensorDropout
    case invalidAltitudeDelta
}
enum V14HeightSource: String {   // מרחיב את הקיים, לא שובר
    case relativeAltitude
    case absoluteAltitude   // diagnostic-only override, לא ברירת מחדל
    case ballistic
    case unavailable         // חדש
}
```

## 14. Logging and Shadow Comparison

תשתית ה-logging הקיימת (`SessionLogger.logSample/logBarometer/logAbsoluteAltitude/logEvent`, ראה `SessionLogger.swift:200,245,266`) כבר עשירה ומכוסה ב-`SessionLogger.shared.logEvent` שמופעל מ-`JumpDetectorV14.jumpDetected` (506-516). מוסיפים לשורת ה-JUMP הקיימת (לא שורה חדשה — אותה event) שדות shadow:

```
v14_old_height_value=<heightM לפי הסדר הישן (absolute-first)>
v14_old_height_source=<absolute|relative|ballistic לפי הסדר הישן>
v14_new_height_value=<heightM לפי הסדר החדש (relative-first)>
v14_new_height_source=<relative|absolute|ballistic לפי הסדר החדש>
v14_baseline_variance / v14_baseline_quality / v14_apex_confidence / v14_altitude_coverage
v14_height_confidence / v14_detection_confidence
v14_height_failure_reason
```

**Shadow mode (פאזה 3-4): שני החישובים רצים במקביל, ה-UI וה-`Jump` שנשמר ממשיכים לקבל את התוצאה הישנה עד שנבדק replay validation.** יישום: `finalize()` מחשב את שני הסטים (זול — שני ifs, לא שני engines), שולח את שניהם ל-log, ומחזיר `V14Jump` עם ה-source הישן. מעבר בפועל ל-source החדש קורה בפאזה 6/7 (feature flag ב-`V14Settings`).

## 15. Required File Changes

| קובץ | סוג שינוי | תיאור |
|---|---|---|
| `SPOTEQ/SPOTEQ Watch App/Services/JumpEngineV14.swift` | עריכה ממוקדת | `Flight` מקבל `relFlightSamples: [TimedValue]`; `finalize()` (713-785) מאציל את בחירת המקור ל-`V14HeightAnalyzer`; `V14Jump` מורחב בשדות אופציונליים חדשים (baselineQuality, apexConfidence, heightConfidence, heightFailureReason, altitudeCoverage) |
| `SPOTEQ/SPOTEQ Watch App/Services/V14HeightAnalyzer.swift` | **חדש** | baseline/apex/height/confidence, טהור, ללא side effects, נבדק unit-test בבידוד |
| `SPOTEQ/SPOTEQ Watch App/Services/JumpDetectorV14.swift` | עריכה קטנה | `makeJump(from:)` (465-482) ממפה שדות חדשים ל-`Jump`; feature-flag קריאה מ-`V14Settings` להחלטת absolute-override |
| `SPOTEQ/SPOTEQ Watch App/Models/Session.swift` | עריכה תוספתית בלבד | `Jump` מקבל שדות אופציונליים חדשים (`heightConfidence`, `baselineQuality`, `heightFailureReason`) — כולם `nil`-default, לא שוברים decode של sessions ישנים |
| `SPOTEQ/SPOTEQ Watch App/Services/SessionLogger.swift` | עריכה תוספתית | שדות shadow-log נוספים לאירוע ה-JUMP הקיים |
| `SPOTEQ/SPOTEQ Watch App/Views/SettingsView.swift` | עריכה קטנה | toggle "V14 height source: relative (default) / absolute (debug)" מאחורי debug section קיים (יש כבר `V12DebugSettings` pattern לשימוש חוזר) |
| `SPOTEQ/Package.swift` | עריכה תוספתית | הוספת `V14HeightAnalyzer.swift` ל-sources של `SPOTEQ/Tools/JumpReplay` target (שורה 51 — לצד `JumpEngineV14.swift`) |
| `SPOTEQ/Tools/JumpReplay/Sources/JumpReplay/WatchSources/V14HeightAnalyzer.swift` | **סימלינק חדש** | תואם למוסכמה הקיימת — כל שאר קבצי V14 כבר symlinked שם (זיכרון `v11-live-vs-offline-blindspot`: "WatchSources are symlinks") |
| `SPOTEQ/Tools/JumpReplay/Sources/JumpReplay/EngineE2ESelfTest.swift` | עריכה תוספתית | תרחישי V14 נוספים (ראה סעיף 16) |
| `SPOTEQ/Tests/WatchLiveSessionCoreChecks/main.swift` | עריכה תוספתית | unit checks ל-`V14HeightAnalyzer` |

**לא נוגעים:** `MotionManager.swift` (הזרימה on-demand כבר עובדת כנדרש), `SessionManager.swift` (wiring כבר תקין), פרוטוקול `JumpDetecting.swift` (אין צורך בשינוי חתימה).

## 16. Unit, Replay and Regression Tests

**Unit (ב-`V14HeightAnalyzer`, מבודד מה-state machine):**
baseline יציב/רועש; פחות מ-`minBaselineSamples` דגימות pre-takeoff; spike ליד apex; עלייה/ירידה הדרגתית; מספר local maxima; altimeter dropout (0 דגימות absolute כל הטיסה — המצב השכיח היום, ראה log 20260717); דגימות מאוחרות (gap > `maxSampleGapSec`); delta שלילי (`maxRel < baseline`); קפיצה נמוכה (~1-1.5m, גבול `minRiseM`); קפיצה 10-20m; נחיתה חלקה מול קשה; absolute לא זמין (`isAbsoluteAltitudeAvailable()==false` מדומה); ללא GPS.

**Replay (`JumpReplay --engine v14`, קבצי לוג קיימים ב-`SPOTEQ/Tools/JumpReplay/output/` ובזיכרון הפרויקט):**
- log_20260717_145840 (baro 2.56s cadence — **הבדיקה הקריטית** ל-`maxSampleGapSec`).
- Water 2026-07-14 (47.8min, 10 jumps riding-only, 0 beach FPs — regression baseline).
- Water 2026-07-08 (48min → 5 jumps).
- Land log 2-jump (~2.1m, absolute-heavy — לוודא שה-diagnostic override עדיין עקבי).
- Zero-jump log.
- Noise sessions (shake/drop/throw — לוודא takeoffTurbulence gate לא נגע).

**Regression (חובה, gate ל-merge):** מספר וזהות הקפיצות שמזוהות ב-**כל** לוגי הרפרנס למעלה **חייבים להיות זהים ל-baseline הנוכחי** (takeoffT, landingT, airtime — לא רק count). ה-`heightM`/`heightSource` בלבד רשאים להשתנות, ורק אחרי Phase 7. `--engine-e2e-selftest` (20 תרחישים קיימים, מזה 5 ל-v14) חייב להמשיך לעבור ללא שינוי. `swift run WatchLiveSessionCoreChecks` (4 בדיקות v14 קיימות) — ללא שינוי + תוספות ל-analyzer.

## 17. Incremental Implementation Phases

**Phase 0 — Codebase audit.** ✅ בוצע כאן (סעיפים 2-4). תוצר: המסמך הזה.

**Phase 1 — Preserve current detection.** להריץ `JumpReplay --engine v14` על כל לוגי הרפרנס ולשמור baseline JSON (takeoffT/landingT/airtime/heightSource לכל קפיצה) — regression anchor לכל השלבים הבאים.

**Phase 2 — Altitude collection layer.** הוספת `relFlightSamples` ל-`Flight` (תוספת אגרגציה בלבד ב-`addRelativeAltitude`, לא שינוי logic). Regression run — חייב להיות bit-identical ל-Phase 1 (שום קפיצה לא זזה).

**Phase 3 — Shadow analysis.** `V14HeightAnalyzer` נכתב ורץ **במקביל** לחישוב הישן; שני התוצאות ב-log (סעיף 14); ה-`V14Jump` שיוצא עדיין נושא את המקור הישן.

**Phase 4 — Logging and replay comparison.** הרצת replay על כל הלוגים, השוואת `v14_old_height_value` מול `v14_new_height_value` — דוח אחוזי סטייה, פילוח לפי heightSource ישן/חדש.

**Phase 5 — Calibration.** כיול `stabilityVarianceM`, `maxSampleGapSec`, `apex confidence weights` **רק** מהדוח של Phase 4 — לא מספרים מומצאים.

**Phase 6 — Controlled activation.** Feature flag ב-`V14Settings` (`v14HeightSourcePreference: relative|absolute|auto`), ברירת מחדל **נשארת absolute** (ההתנהגות הנוכחית) עד קריטריוני קבלה.

**Phase 7 — Default migration.** מעבר ל-relative כברירת מחדל, רק אחרי שה-regression ב-Phase 1 עדיין 100% תואם וה-shadow report מראה שהיחסי לא "מוריד" גבהים אמיתיים ביחס לוידאו/רפרנס חיצוני (אם קיים).

**Phase 8 — Remove hard dependency.** בפועל היום **כבר אין** תלות חובה (סעיף 3) — השלב הזה מצטמצם לניקוי: להסיר את ה-branch שמבכר absolute מ-`finalize()` הישן (אחרי Phase 7 מוצלח), ולהשאיר `heightAbsolute`/absolute-window collection כ-diagnostic path בלבד.

## 18. Acceptance Criteria

- [ ] כל לוגי הרפרנס (סעיף 16) מזהים **אותן קפיצות בדיוק** (זהות + טיימינג) לפני ואחרי — לא רק אותו count.
- [ ] `--engine-e2e-selftest` ו-`WatchLiveSessionCoreChecks` עוברים ללא שינוי בציפיות הקיימות.
- [ ] `heightSource=.unavailable` מוחלף פנימה במקום `REJECT reason=noHeightSource` — קפיצה שה-IMU אישר לא נעלמת.
- [ ] `detectionConfidence` ו-`heightConfidence` קיימים כשדות נפרדים ב-`V14Jump`.
- [ ] Shadow log (`v14_old_height_*`/`v14_new_height_*`) קיים על כל קפיצה בזמן Phase 3-5.
- [ ] Build ל-watchOS עובר; sessions ישנים (`Jump`/`Session` עם שדות ישנים) עדיין נטענים (JSON decode לא נשבר — כל שדה חדש `Optional`).
- [ ] הפעלה בלי `CMAltimeter.isAbsoluteAltitudeAvailable()` (מדומה ב-unit test) לא חוסמת session, candidate, או jump.
- [ ] אין שינוי אחד ב-thresholds/state-machine של סעיף 4 ללא PR נפרד עם evidence.

## 19. Risks and Needs Verification

1. **V15 כבר קיים ופותר חלק מהבעיה בכיוון שונה.** `JumpDetectorV15.swift`/`JumpEngineV15.swift` (DetectionEngine.v15Clean, MotionManager `.continuousNoWatchdog`) הוא כבר "the clean engine" מאוחר יותר (2026-07-18, אחרי V14 ב-2026-07-15) עם apex fit רציף. **צריך החלטה מהמשתמש**: האם V14 relative-height הוא מסלול קבע, או האם V15 כבר אמור לרשת את התפקיד הזה ו-V14 נשאר legacy? התוכנית הזו מניחה **V14 ממשיך להתקיים ולהשתפר**, כי זו הבקשה המפורשת — אבל שווה לוודא זה לא כפילות מאמץ.
2. **`baseline=n/a` ב-41% מה-candidates** (log 20260717, לפי הזיכרון) — אם baro cadence אמיתי הוא ~2.5s, לא 1Hz, אז `maxSampleGapSec`/`preTakeoffWindowSec` חייבים לשקף את זה, אחרת ה-baseline quality flag תמיד ידווח unstable. דורש מדידה טרייה, לא הנחה.
3. **`belowMinRise` (סעיף 13, פריט 3)** נשאר reject מוחלט, לא degraded-emit — זו קריאה שנעשתה כאן לפי כוונת הקוד הקיים ("חלק מנוסחת הזיהוי"), אבל **שווה לאשר מול המשתמש** אם זו הפרשנות הרצויה, כי היא טכנית "מוחקת קפיצה" (גם אם קטנה).
4. **submersion channel לא מזין V14 בפועל** — `blockTakeoffWhileSubmerged` מתועד כ"inert" בזיכרון על אף baro dips ל-−350m עם water contact מוכח. זה לא בסקופ ישיר (המשתמש לא ביקש לתקן submersion), אבל relStepReject/reaccept (סעיף 8) הוא הקו הראשון שאמור לתפוס את זה, ולא תמיד תופס (−244m/−311m התקבלו כ-datum shift). דגל אדום ל-baseline quality: אם ה-reaccept מקבל ערך מטבילה כ"baseline legit", כל שכבת ה-quality החדשה תדווח false-confident. **לא בסקופ לתקן, אבל ה-analyzer צריך symptom-flag על variance קיצוני גם בתוך חלון "מקובל".**
5. **Live vs. offline divergence** (זיכרון `v11-live-vs-offline-blindspot`) — replay ב-JumpReplay אינו ולידציה חיה מספקת (log 20260717: live 2 קפיצות, offline 3, אפס חפיפה). Regression testing כאן (סעיף 16) יתפוס רק שינויים ב-offline path; שינוי אמיתי בזמן אמת דורש live session test נפרד (לא ב-scope הזה, אבל *חובה* לפני Phase 7 production rollout).

## 20. Final Recommendation

**להריץ את התוכנית.** ההיקף האמיתי קטן בהרבה ממה שספק המשימה מרמז — כי ה-IMU detection של V14 **כבר** עצמאי מ-absolute altitude, וה-collection של relative altitude **כבר** קיים ומסונכרן כראוי (timestamp-based, לא index-based). העבודה האמיתית היא: (א) להפוך סדר עדיפות בפונקציה אחת (`finalize`), (ב) להוסיף שכבת quality/confidence מעל נתונים שכבר נאספים, (ג) לתקן נקודת קונפליקט אחת אמיתית (`noHeightSource` מוחק קפיצה שה-IMU אישר).

לא לגעת ב-state machine, לא לשנות שום סף IMU, ולא לדחוף ל-production בלי shadow-mode + regression מלא על כל לוגי הרפרנס. הסיכון האמיתי היחיד שדורש בירור מול המשתמש הוא סעיף 19 פריט 1 (חפיפה עם V15) — כדאי לסגור את זה **לפני** Phase 2, כדי לא להשקיע בכיוון שכבר ננטש.
