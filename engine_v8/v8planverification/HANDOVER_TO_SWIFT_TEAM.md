# Handover — Kitesurf Jump Detection V8 (for the Swift implementation team)

מסמך מסירה: כל מה שצריך כדי לממש את אלגוריתם V8 ב‑Swift, להקליט את הלוגים
הנכונים, ולאמת מול Hoolan/Surfr. כתוב באנגלית לנוחות מימוש (מונחי קוד/סנסורים
אוניברסליים), עם תקציר עברי בכל חלק.

---

## 0. TL;DR (תקציר)

- **גובה קפיצת קייט מגיע מהברומטר**, לא מהאקסלרומטר — הוכחנו פיזיקלית שהעלייה
  החלקה תחת העפיפון אינה קיימת בתאוצת היד.
- **זמן‑אוויר נגזר מהגובה** (הברומטר איטי מכדי לתזמן) ומוצלב עם ה‑IMM.
- **זריקות** מזוהות במסלול בליסטי נפרד (time‑of‑flight), מבודד ממהירות.
- **ה‑single source of truth הוא `core/jumpEngineV8.ts`** — לתרגם line‑for‑line ל‑Swift.

---

## 1. מה להעביר לצוות (Documents + Code)

### 1.1 קוד — מקור האמת היחיד
| קובץ | תפקיד |
|---|---|
| **`surfhub-watch/core/jumpEngineV8.ts`** | **האלגוריתם המלא** (TypeScript) — **מקור האמת**. כל הפרמטרים, הנוסחאות, הגייטים, מסלול הזריקה, ההצלבה. |
| **`surfhub-watch/core/KitesurfJumpEngineV8.swift`** | **תרגום Swift מלא** (line‑for‑line) — נקודת התחלה לצוות. גם הועלה ל‑DB כפרופיל #14 הפעיל בדאשבורד. לאמת מול ה‑TS ולחבר ל‑CoreMotion (CMDeviceMotion+CMAltimeter, מיפוי §6). |
| `surfhub-watch/core/jumpEngineV8.test.ts` | טסטים סינתטיים (6) — לשכפל ב‑Swift כ‑unit tests |
| `surfhub-watch/core/types.ts` | מבנה `SensorSample` (פורמט הקלט) |
| `surfhub-watch/core/csvLog.ts`, `kslog.ts` | מפענחי לוג (CSV legacy / KSLOG binary) — לעיון, לא חובה ב‑Swift |

### 1.2 תיעוד — לקרוא בסדר הזה
1. **`ALGORITHM_V8_HEBREW.md`** — התיאוריה, הפיזיקה, הארכיטקטורה, הנוסחאות,
   הפסאודו‑קוד, וטבלת מיפוי הסנסורים לכל פלטפורמה (Apple/Samsung/Garmin). **הקובץ
   המרכזי למימוש.**
2. **`JUMP_V8_PLAN.md`** — התוכנית המלאה: מדוע baro‑centric, ההצלבה הרב‑ערוצית,
   מסלול הזריקות, מה נדרש (DSP/מטריצות/באפר).
3. **`NEXT_LOG_RECORDING_SPEC.md`** — **דרישות הקלטת הלוג הבא** (קצב סנסורים,
   אילו סנסורים) — חובה לפני ההקלטה הבאה.
4. **`SENSOR_RESEARCH_S9_ULTRA.md`** — מחקר סנסורי Apple Watch (CMBatchedSensorManager
   800Hz, CMWaterSubmersionManager, מגבלות הברומטר).
5. **`TESTING_AND_VALIDATION.md`** — **בדיקות, תוצאות בפועל מול כל לוג, טבלת כל
   הפרמטרים (ערך+איך נקבע), וצ'קליסט מפורט מה ה‑AI/המממש חייב לבדוק ואיך.**
6. **`HANDOVER_TO_SWIFT_TEAM.md`** (המסמך הזה) — אינדקס + תוצאות האימות.

---

## 2. תוצאות האימות (מול איזה לוגים, מה התוצאות)

### 2.1 הלוגים שנבדקו
| לוג | מקור | רפרנס | תיאור |
|---|---|---|---|
| `4173200D` (Surfr kite) | שעון הקליט, Surfr על שעון שני | **Surfr** | סשן קייט אמיתי 28 דק', 50Hz IMU + 0.36Hz baro |
| `00DC2259` (Hoolan throws) | שעון נזרק ביד | **Hoolan** | 6 זריקות שעון לבדיקה |

שניהם ב‑DB: `surfr-kite/...4173200D.kslog`, `watch/...00DC2259.kslog`.

### 2.2 גובה + זמן‑אוויר — קייט מול Surfr
top‑4 לפי גובה (Surfr מציג רק את הגבוהות), rank‑matched:

| V8 גובה / זמן | Surfr גובה / זמן |
|---|---|
| **3.82m / 4.65s** | 3.77m / 4.33s ← הקפיצה הגדולה: Δגובה **0.05m** |
| 3.17m / 4.23s | 3.45m / 4.12s |
| 2.54m / 3.78s | 3.17m / 4.59s |
| 2.21m / 3.53s | 3.14m / 4.37s |

- **Height RMS = 0.58m**, **Airtime RMS = 0.61s** (9 קפיצות קייט סה"כ).
- **הקפיצה הגדולה והדגומה‑הכי‑טוב תואמת ל‑0.05m** — מוכיח שהשיטה נכונה.
- הקפיצות הקטנות **מזלזלות** כי הברומטר ב‑**0.36Hz** מחמיץ את ה‑apex (תת‑נייקוויסט).
  → **עם ברומטר ≥1Hz צפוי ≤0.2m** (ראו §3).

### 2.3 זריקות — מול Hoolan
| | תוצאה |
|---|---|
| זוהו | **6 זריקות** ב‑t=10,37,59,68,80,94s |
| Hoolan (אמיתי) | זריקות ב‑37,59,68,80,94,106s — **תזמון תואם** |
| גבהים V8 | 2.5, 2.5, 3.4, 3.2, 3.8, 4.6m |
| Hoolan גבהים | 3.9–8.8m — **היד מזלזלת** (time‑of‑flight על זריקה רועשת) |
| זיהום לקייט | **0** (מסלול הזריקה מבודד‑מהירות, לא יורה בזמן רכיבה) |

### 2.4 טסטים (`jumpEngineV8.test.ts`) — 6 עוברים
1. `baroAltitudeSeries` משחזר גובה מעל קו‑בסיס
2. מזהה קפיצת baro בודדת עם גובה סביר
3. מדווח שדות ההצלבה (measuredAirtime/airborne/barPull)
4. דוחה hops < 1.5m
5. אין baro → אין גובה קייט (אבל מסלול זריקה עדיין רץ)
6. מסלול זריקה: מזהה זריקה בליסטית בעמידה, לעולם לא בזמן רכיבה

---

## 3. דרישות מהסנסורים + הקלטות הלוג הבא (קריטי)

הלוג הנוכחי (0.36Hz baro, 50Hz IMU) **מגביל את הדיוק ל‑~0.58m**. ה‑bottleneck
הוא הברומטר. הלוג הבא חייב (פירוט מלא ב‑`NEXT_LOG_RECORDING_SPEC.md`):

| זרם | Apple API | קצב מטרה | למה |
|---|---|---|---|
| **לחץ ברומטרי** (יחסי + מוחלט) | `CMAltimeter` | **≥1Hz** (היום 0.36) | מקור הגובה; ≥4–5 דגימות/קפיצה לתפיסת ה‑apex |
| **תאוצה מהירה** | `CMBatchedSensorManager.accelerometer` | **800Hz** (S8/9/Ultra) | water‑release/contact → זמן‑אוויר מדויק |
| **device‑motion** | `CMBatchedSensorManager.deviceMotion` | **200Hz** | attitude נקי, פופ/סיבוב |
| **טבילה במים** (Ultra) | `CMWaterSubmersionManager` | events | אות "מחוץ למים" ישיר = ground‑truth airtime |
| GPS + **lat/lng** | `CLLocationManager` | 1Hz | מרחק אמיתי (בלוג היה רק spd) |

**הערות:** לשמור `HKWorkoutSession` פעיל (חובה ל‑Batched); להקליט absolute altitude;
חותמות‑זמן גולמיות פר‑זרם (קצבים שונים, לא לדגום‑מחדש על השעון); להוסיף lat/lng.

**Samsung/Garmin:** `Sensor.TYPE_PRESSURE` **אינו נעול** — לדגום 10–25Hz, פותר
ישירות את ה‑bottleneck. מיפוי מלא ב‑`ALGORITHM_V8_HEBREW.md` §6.

---

## 4. ארכיטקטורת המימוש ב‑Swift (צ'קליסט)

1. **`struct Sample`** בפורמט §5.1 של `ALGORITHM_V8_HEBREW.md`. בנה מתאם רכש לכל
   פלטפורמה שמייצר `Sample` (Apple: CMDeviceMotion+CMAltimeter; מיפוי בטבלה §6).
2. **פרימיטיבים** (תרגום מ‑`jumpEngineV8.ts`): `vertAccelG` (היטל אנכי = מכפלה
   סקלרית מול וקטור הגרביטציה), `rollingMedianBaseline`, `parabolicApex`,
   חישוב `chop` (סטיית תקן מתגלגלת של |userAccel|).
3. **`detectJumps`**: `baroAltitudeSeries` → apexes → גובה פרבולי → airtime נגזר
   (`kiteGlideFactor·2√(2h/g)`) → סינון רעשים (run‑up speed) → הצלבה (calm window
   + bar‑pull, confidence בלבד) → פלוט.
4. **מסלול זריקות** (`detectThrowsBallistic`): launch≥2.5g → first‑landing≥2.0g
   תוך ≤2.5s (מעוף יד פיזיקלי; ארוך יותר = פער‑עמידה, לא מעוף → 12m שגוי), בעמידה
   (≤3m/s), גובה בליסטי capped 8m. מבודד‑מהירות מהקייט.
5. **פרמטרים** מ‑`DEFAULT_V8_PARAMS` (ב‑`jumpEngineV8.ts` ו‑§5.2 בעברית).
6. **באפר אופליין**: הקלט → בזיהוי קפיצה, נתח (מותר 5–7s אחרי הנחיתה). אין real‑time.
7. **שכפל את 6 הטסטים** כ‑Swift unit tests.

### עקרונות שאסור להפר (מתוך הניסיון)
- **גובה רק מ‑baro** — אל תנסה לאנטגרל תאוצת‑יד (הוכח שנכשל).
- **אל תפסול על סיבוב/תנועת‑יד באוויר** — תרגילי קייט מסתובבים; זו קפיצה לגיטימית.
- **הסינון היחיד על גובה: < 1.5m.** ההצלבה מעלה confidence, לא פוסלת.
- **מסלול זריקה מבודד‑מהירות** — שומר על הקייט נקי.

---

## 5. סטטוס בדאשבורד (surfhub‑admin)

- מנוע V8 כבר מחווט ב‑WATCH CALIB: בורר engine מפורש (Auto/V8/V7/v4), טבלת
  diagnostics ל‑V8 (Source/Meas‑air/Airborne/Pull/Conf), פאנל Reference‑compare.
- שני לוגי הייחוס ב‑DB וניתנים לטעינה+ניתוח בדאשבורד.
- ה‑TS engine הוא ה‑single source of truth; ה‑Swift צריך להיות line‑for‑line זהה.
