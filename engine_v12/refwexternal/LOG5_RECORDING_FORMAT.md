# LOG5 — מפרט הקלטה + פורמט בינארי KSLG v2

**מטרה:** לוג אחד שמאפשר ניתוח מלא של סשן — כיול ספי V12 (yank/chop ב-200Hz אמיתי),
ולידציית גובה מול Surfr, אבחון drift, ו-replay מדויק של מה שהשעון ראה.
**עיקרון-על:** כל זרם נרשם **באירועים, עם חותמת הזמן של החיישן** (`data.timestamp`,
שניות מ-boot) — אף פעם לא polling, אף פעם לא resample. זה בדיוק הכשל של v1
(שורת 50Hz אחת עם forward-fill שמחקה את זמני הברומטר האמיתיים ונתנה 0.36Hz).

---

## 1. מה חייב להיות בלוג, ובאיזה קצב

| # | זרם | API | קצב נדרש | שדות | למה חובה |
|---|---|---|---|---|---|
| 1 | **Device Motion** | `CMBatchedSensorManager.deviceMotionUpdates()` | **200Hz** (כל דגימה בכל batch) | t, userAccel xyz, rotationRate xyz, quaternion | תזמון המראה/נחיתה ±5ms ⇒ airtime; chop; כיול ספי yank על הסקאלה המכוילת (userAccel) |
| 2 | **Raw Accel** (ללוג כיול בלבד) | `CMBatchedSensorManager.accelerometerUpdates()` | **800Hz** | t, ax ay az (raw, כולל כבידה) | רזולוציית אימפקט מקסימלית לכיול חד-פעמי; בייצור כבוי |
| 3 | **ברומטר יחסי** | `CMAltimeter.startRelativeAltitudeUpdates` | **כל callback** (מצופה ~1Hz; חובה למדוד!) | t, relativeAltitude (m), pressure (kPa) | **מקור הגובה.** ה-relAlt של Apple מפולטר ומפוצה-טמפרטורה — עדיף על לחץ גולמי |
| 4 | **גובה אבסולוטי** | `startAbsoluteAltitudeUpdates` (אם זמין) | כל callback | t, altitude (m), accuracy, precision | רפרנס drift איטי + debug |
| 5 | **GPS** | `CLLocationManager` | **1Hz** | t, lat, lng, speed, course, hAcc, vAcc, gpsAlt | שער planing; מרחק קפיצה; יישור מול Surfr |
| 6 | **טבילה** (Ultra בלבד, אופציונלי) | `CMWaterSubmersionManager` | אירועים | t, state / depth / waterTemp | ground-truth ליציאה/כניסה למים; אבחון wet-port |
| 7 | **אירועי מנוע** | פנימי | אירועים | t, state, evt string | מה השעון חשב בזמן אמת (v-current + v12 candidates) |
| 8 | **סנכרון** | ידני | פעם בסשן | ראה §4 | יישור מול Surfr בלי ניחושים |

**תנאי רכישה מחייבים:** `HKWorkoutSession` פעיל לכל אורך ההקלטה; handler של
ה-altimeter על תור serial ייעודי `.userInteractive`; אסור לרשום מ-main queue.
**בדיקת קבלה של הלוג עצמו (לפני ניתוח):** היסטוגרמת מרווחי baro — חציון ≤1.3s
ו-95% ≤2.0s; מרווחי deviceMotion — חציון 5ms. לוג שלא עומד בזה = ההקלטה שבורה,
לחזור לשטח.

## 2. פורמט בינארי — KSLG v2 (stream-tagged records)

Little-endian. תואם-משפחה ל-v1 (אותם magic/סנטינלים/קונבנציות סקיילינג):

```
Header:
  magic        4B    "KSLG"
  version      u8    2
  headerLen    u16
  headerJson   headerLen bytes UTF-8 (ראה §3)

אחר-כך זרם רשומות עד EOF. כל רשומה נפתחת ב-tag u8.
זמן בכל הרשומות: tUs u64 — מיקרו-שניות מ-t0 של הסשן (t0 מוגדר ב-header).
                 (v1 השתמש ב-u32 ms; ב-200-800Hz נדרשת רזולוציית µs.)

MOTION record (tag 3) — 200Hz deviceMotion:            28B
  tag u8=3 · tUs u64
  uax uay uaz   3×i16  ×1000  (userAcceleration, g)
  rrx rry rrz   3×i16  ×1000  (rotationRate, rad/s)
  qw qx qy qz   4×i16  ×10000 (attitude quaternion, unit)

RAWACC record (tag 4) — 800Hz raw accel (כיול בלבד):   15B
  tag u8=4 · tUs u64
  ax ay az      3×i16  ×1000  (raw accel כולל כבידה, g)

BARO record (tag 5) — כל callback של relativeAltitude:  17B
  tag u8=5 · tUs u64
  relAlt        i32    ×1000  (m — רזולוציית מ"מ; טווח ±2,147km)
  pressure      i32    ×10    (Pa — כלומר hPa×1000... ראה הערה)
  ↳ הערה: pressure נשמר ב-Pa×10 = 0.1Pa quantum (0.001 hPa) — עשירית
    מהקוונטום של החיישן (0.01 hPa), בלי אובדן.

ABSALT record (tag 6) — absolute altitude:              21B
  tag u8=6 · tUs u64
  alt           i32    ×1000  (m)
  accuracy      i32    ×1000  (m)
  precision     i32    ×1000  (m)

GPS record (tag 7):                                     41B
  tag u8=7 · tUs u64
  lat lng       2×i32  ×1e7   (deg — ~1.1cm רזולוציה)
  spd           u16    ×100   (m/s; sentinel u16.max = invalid)
  course        u16    ×10    (deg; sentinel = invalid)
  hAcc vAcc     2×u16  ×10    (m; sentinel = invalid)
  gpsAlt        i32    ×1000  (m; sentinel = missing)

SUBMERSION record (tag 8):                              11B
  tag u8=8 · tUs u64
  kind          u8     0=state,1=depth,2=waterTemp
  value         i16    state: 0/1 · depth: ×100 m · temp: ×100 °C

EVENT record (tag 9) — כמו v1 EVENT אבל עם tUs:
  tag u8=9 · tUs u64 · state u8 · evtLen u16 · evt UTF-8

SYNC record (tag 10) — סימון סנכרון ידני (§4):
  tag u8=10 · tUs u64 · wallClockUnixMs u64 · labelLen u16 · label UTF-8

סנטינלים: i16→-32768, i32→-2147483648, u16→65535 (כמו v1).
```

**תקציב גודל (סשן 60 דק'):** MOTION ‏200Hz×28B ≈ 20MB · RAWACC ‏800Hz×15B ≈ 43MB ·
BARO ‏~1Hz ≈ 60KB · GPS ‏1Hz ≈ 148KB · **סה"כ ~63MB עם RAWACC, ‏~20MB בלעדיו.**
ללוג כיול זה סביר (העברה בטלפון); בייצור RAWACC כבוי ו-MOTION אפשר לדלל ל-100Hz.

## 3. header JSON (חובה כל שדה)

```json
{
  "format": "kslog", "version": 2, "schemaVersion": 2,
  "date": "YYYYMMDD_HHMMSS", "session": "<UUID>",
  "t0BootUs": 123456789012,          // ה-timestamp (boot µs) שמוגדר כ-0 של הלוג
  "wallClockAtT0Ms": 1789000000000,  // Unix ms באותו רגע — גשר לשעון קיר
  "device": { "model": "Watch7,1", "watchOS": "11.x", "appVersion": "x.y.z" },
  "engines": { "active": "v9", "candidates": ["v12"] },
  "streams": { "motionHz": 200, "rawAccHz": 800, "baroExpectedHz": 1,
               "gpsHz": 1, "submersion": true|false },
  "reference": { "surfr": true, "surfrWatch": "second watch same wrist",
                 "syncMethod": "filmed stopwatch + SYNC records" },
  "columnsNote": "stream-tagged records — see LOG5_RECORDING_FORMAT.md"
}
```

## 4. פרוטוקול סנכרון מול Surfr (לקח LOG4 — עלה לנו שעות)

1. שני השעונים על אותה יד; מתחילים הקלטה בשניהם.
2. **מצלמים את שני השעונים יחד מול סטופר רץ** (5 שניות וידאו).
3. מיד אחרי הצילום: לחיצת "sync" באפליקציה → נרשם SYNC record (tUs + wallClock
   + label "start-sync"). אותו דבר בסוף הסשן ("end-sync").
4. שלוש מכות אגרוף קלות על החפה (spike משולש ב-IMU) מיד אחרי ה-sync — עוגן
   יישור עצמאי גם אם הווידאו אבד.

## 5. שימוש בבאפר — ניצול תקציב ה-≤5s לתוצאה טובה יותר

**התובנה:** עד עכשיו V12 פלט מיידית בנחיתה עם עוגן חד-צדדי (עבר בלבד), ותיקון
drift הגיע רק כ-refinement מאוחר. עם תקציב 5s, ההצגה הראשית יכולה לחכות
‏~3.5s ולכלול **2–3 דגימות baro שאחרי הנחיתה** ⇒ עוגן דו-צדדי:

```
עוגן קדמי  B₀ = median(4 דגימות לפני ההמראה)      @ t̄₀
עוגן אחורי B₁ = median(2–3 דגימות אחרי הנחיתה)     @ t̄₁
קצב drift  d = (B₁ − B₀)/(t̄₁ − t̄₀)                 ← נמדד, לא משוער
תיקון כל נקודת קשת:  z′(t) = z(t) − B₀ − d·(t − t̄₀)
fit מעוגן-קצוות על z′ ⇒ גובה שממנו drift ליניארי הוסר במלואו
```

- ‏drift ליניארי (הרוב המוחלט של רכיב ה-wind/thermal על פני 8–10s) — **מבוטל
  אנליטית**, לא "מוערך". על LOG4 זה ההבדל בין ±1.5m ל-±0.3m.
- תקציב זמן: נחיתה + ~2.6s (2–3 דגימות @1Hz) + חישוב ⇒ **תצוגה ב-3.5–4s** ✓.
- ה-instant (~1s, חד-צדדי) נשאר זמין כ-provisional על ה-HUD; המספר הקובע
  מגיע ב-≤4s. |rtz| שנשאר גדול אחרי התיקון ⇒ drift לא-ליניארי ⇒ דגל
  driftSuspect והורדת confidence (לא דחייה).
- זיכרון: ring baro ‏~40 דגימות + motion features ‏60 דגימות — ללא שינוי.

מומש ב-`core/jumpEngineV12.ts` + ‏`core/JumpEngineV12.swift`
(‏`refine()` = עכשיו fit דו-צדדי מלא, לא תיקון ‎−rtz/2 גס).
