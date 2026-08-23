# V14 Raw Pressure Jump Height Upgrade Plan

## 1. Executive Summary

זהו שדרוג המשך לעבודה שכבר בוצעה ב-[V14_RELATIVE_HEIGHT_UPGRADE_PLAN.md](./V14_RELATIVE_HEIGHT_UPGRADE_PLAN.md) (מומש בפועל ב-`JumpEngineV14.swift`/`JumpDetectorV14.swift`/`V14HeightAnalyzer.swift`): שם הפכנו את **Apple's `CMAltitudeData.relativeAltitude`** למקור הגובה הראשי במקום `absoluteAltitude`. הבקשה הנוכחית הולכת צעד אחד עמוק יותר: **גם `relativeAltitude` של Apple ייפסל** — הוא "black box" מחושב על ידי המערכת, לא בשליטתנו, ולא ניתן לשחזור בפלטפורמות אחרות (Garmin/Wear OS). המקור היחיד המותר הוא `CMAltitudeData.pressure` הגולמי, עם נוסחת המרה פיזיקלית שאנחנו כותבים ובודקים בעצמנו.

**ממצא מרכזי מהמדידה בפועל (לא הנחה):** מדדתי את קצב הברומטר על שני לוגים אמיתיים (`log_20260714_135926`, `log_v14_20260717_145840`) — **2.56 שניות בין דגימות** (סטיית תקן ~12-16ms, ללא gaps), לא 1Hz כפי שמקובל לחשוב על iPhone. `pressure` ו-`relativeAltitude` מגיעים **באותו callback בדיוק** (`CMAltimeter.startRelativeAltitudeUpdates`) — אין API נפרד ומהיר יותר לגישה לגלחץ גולמי. המשמעות: **המעבר לגלחץ גולמי לא ישפר את קצב הדגימה כלל** — היתרון הוא בשליטה על הנוסחה ובניידות, לא במהירות.

**ממצא קריטי שני, גם הוא ממדידה בפועל:** בדקתי כמה דגימות ברומטר נופלות *בתוך* חלון הטיסה של כל אחת מ-9 הקפיצות שזוהו בלוג 0714 (airtime 0.42–1.94s): **5 מתוך 9 קפיצות קיבלו 0 דגימות בתוך הטיסה, 4 מתוך 9 קיבלו בדיוק דגימה אחת — אף קפיצה לא קיבלה 2+ דגימות.** משמעות: local quadratic interpolation בין כמה דגימות airborne (סעיף 12 בספק) הוא המקרה **הנדיר**, לא הנפוץ, בהינתן החומרה/הקצב הנוכחיים. התוכנית חייבת להיבנות סביב זה, לא להתעלם ממנו.

השינוי הארכיטקטוני עצמו קטן יחסית: תשתית ה-baseline/apex quality/confidence-separation שכבר נבנתה ב-`V14HeightAnalyzer.swift` **נשארת כמעט כולה** — היא לא תלויה במקור הנתון. מה שמוחלף הוא רק **המקור**: input חדש (`pressureToHeightMeters` שלנו) במקום `sample.relativeAltitude` של Apple, בתוספת מודול קונברסיה חדש, שכבת סינון מפורשת, ומנגנון interpolation מוגבל בין דגימות.

## 2. Existing V14 IMU Detection Flow

ללא שינוי מהמסמך הקודם — ראו [V14_RELATIVE_HEIGHT_UPGRADE_PLAN.md §2](./V14_RELATIVE_HEIGHT_UPGRADE_PLAN.md#2-existing-v14-detection-flow). תמצית: `riding → airborne → landingConfirm` ב-`JumpEngineV14.swift`, כולו IMU (smoothed vertical load, gyro, turbulence gate, pop, retrigger guard). ה-state machine לא נגע בערוץ הלחץ/גובה כלל — האינטגרציה היחידה היא ב-`finalize()`, בדיוק כמו קודם.

## 3. Components That Must Remain Unchanged

זהה לרשימה ב-[V14_RELATIVE_HEIGHT_UPGRADE_PLAN.md §4](./V14_RELATIVE_HEIGHT_UPGRADE_PLAN.md#4-components-that-must-remain-unchanged): `updateUnweight`/`trackTakeoff`/`tryOpenTakeoff`, takeoff turbulence gate (backward+forward scan), `detectTouchdown`/`updateFlightIMU`, `confirmLandingIfStable`, כל ה-thresholds ב-`V14Config` שמתארים IMU (`popG`, `unweightG/Sec`, `landingImpactG`, `flightLoadCeilingG`, `landingMaxGyroRadS`, `takeoffMaxGyroRadS/LoadG`, `minAirtimeSec`, `maxFlightSec`, `retriggerGuardSec`), `verticalLoadG(of:)`, `airtimeSec = touchdown - takeoffT`.

**נוסף לרשימה הפעם:** `belowMinRise`, `relativeContradictsBallistic`, `ballisticUncorroborated` (finalize-time false-positive filters, מכוילים על לוגים אמיתיים) — נשארים כמו שהם, כפי שהוחלט בסבב הקודם. שינוי שלהם עדיין דורש evidence נפרד.

## 4. Removal of Apple Absolute and Relative Altitude Dependencies

מיפוי מדויק של כל מקום שעדיין קורא ל-`sample.relativeAltitude` (Apple):

| קובץ | מיקום | תפקיד היום | מה קורה אחרי השינוי |
|---|---|---|---|
| `Models/Session.swift:161` | `IMUSample.relativeAltitude: Double?` | שדה שמכיל את ערך Apple | **נשאר בסכימה** (backward-compat לוגים ישנים, diagnostic), אך מפסיק להיות input לחישוב |
| `MotionManager.swift:656-664` | `startRelativeAltitudeLocked()` — מחלץ `data.relativeAltitude.doubleValue` **וגם** `data.pressure.doubleValue * 10.0` מאותו callback | שני הערכים כבר נאספים **יחד**, היום | **ללא שינוי** — `pressure` כבר זורם ל-`IMUSample.pressure` בכל דגימה, בלי קוד acquisition חדש |
| `JumpDetectorV14.swift:389-396` | `relativeAltitudeFrame(from:fallbackT:)` — קורא `sample.relativeAltitude` | ה-source שמוזן ל-engine | **מוחלף**: קורא `sample.pressure` ומעביר דרך `V14PressureToHeightConverter` |
| `JumpEngineV14.swift` | `addRelativeAltitude`, `relHistory`, `medianBaseline`, `Flight.baselineRelM/maxRelM/relFlightSamples` | כל "הערוץ היחסי" מבוסס על מה שמוזן לו | **ללא שינוי בלוגיקה** — רק סוג הקלט משתנה (עדיין meters, עדיין אותו pipeline) |

**חשוב:** אין היום, ולא היה, קוד שקורא ל-`CMAltimeter.startAbsoluteAltitudeUpdates`/`isAbsoluteAltitudeAvailable` בתור **חובה** לפעולת V14 — זה כבר טופל בסבב הקודם (absolute הוא diagnostic-fallback אופציונלי גרידא בקדימות השלישית). המשימה הזו לא נוגעת בערוץ ה-absolute כלל; היא מבטלת את **הביניים** (Apple's relative) ולא את ה-fallback השלישי.

## 5. Raw Pressure Acquisition

**אין acquisition חדש לבנות.** `MotionManager.swift:641-673` כבר קורא ל-`relativeAltimeter.startRelativeAltitudeUpdates(to:withHandler:)`, וה-callback היחיד הזה מחזיר `CMAltitudeData` שמכיל **גם** `relativeAltitude` **וגם** `pressure` — אין ב-CoreMotion (מאומת מול Apple Developer Documentation + Apple Developer Forums, סעיף מקורות בסוף) שום API נפרד או מהיר יותר לגישה ל-pressure גולמי בלבד. המשמעות המעשית:

- `pressure` ו-`relativeAltitude` **תמיד** יגיעו באותו קצב, מאותה דגימת חומרה, עם אותו timestamp.
- המרה עצמאית ל-pressure **לא** תשפר sampling rate, latency, או jitter ביחס למה שכבר קיים.
- **עובדה מתועדת רשמית (Apple Developer Documentation):** `pressure` ← kilopascals (kPa); `relativeAltitude` ← metres, "the change in altitude since the first reported event" — Apple לא מתעד fixed update rate בשום מקום רשמי.
- **עובדה נמדדת (לא רשמית, לא מתועדת על ידי Apple, נמדדה כאן ישירות):** על watchOS, בזמן workout session פעיל, קצב בפועל הוא **~2.56s**, לא ~1Hz שמדווח בפורומים לגבי iPhone. אסור להניח את המספר הזה עבור מכשירים/OS-versions אחרים — יש למדוד מחדש בכל שינוי גרסת watchOS.
- `MotionManager.swift:658`: `let pressureHPa = data.pressure.doubleValue * 10.0` — כלומר קיימת כבר המרה מ-kPa (Apple-native) ל-hPa בקוד. **זה יישאר** — hPa הוא היחידה הקנונית של הפרויקט, `IMUSample.pressure` כבר ב-hPa.

**מה כן נבנה:** רק שכבת **צריכה** (consumption) — הפונקציה שממירה `pressure` ל-height. שום שינוי ל-`MotionManager.swift` לא נדרש בפאזה הזו.

## 6. Timestamp Synchronization

זהה למנגנון הקיים (`JumpDetectorV14.swift:401-404`, `alignedToMotionClock`) — `pressure` ו-`relativeAltitude` חולקים את אותו `barometerTimestamp` בדיוק (אותה דגימה!), כך שכל הקוד הקיים ל-de-dup לפי timestamp (`relativeAltitudeFrame`, שורה 393: `guard baroT <= last`) ו-alignment ל-motion clock (±60s tolerance) **ממשיך לעבוד ללא שינוי** — רק שם השדה שנקרא משתנה מ-`sample.relativeAltitude` ל-`sample.pressure`.

`V14PressureRingBuffer` (סעיף 10) לא צריך מנגנון סנכרון חדש — `Flight.absSamples`/`relFlightSamples` הקיימים כבר עושים בדיוק את זה (`[TimedValue(t:v:)]`, ממוינים לפי timestamp אמיתי, לא index). ההרחבה היחידה: לשמור גם pressure גולמי (hPa) לצד הגובה המומר, לצורך diagnostics/shadow logging (סעיף 18).

## 7. Pre-Takeoff Pressure Baseline

**קיים כבר, כמעט מדויק, ב-`JumpEngineV14.swift`:**
- `medianBaseline(before:)` — median על `baselineWindowSec` (4s) לפני takeoff.
- `baselineDiagnostics(before:)` (נוסף בסבב הקודם) — `sampleCount`, `varianceM`, `maxGapSec` על אותו חלון.
- `V14HeightAnalyzer.baselineQuality(...)` — `isStable`/`quality` מהמטריקות האלה.

**מה שמשתנה:** היום `relHistory` מכיל ערכי **meters** (של Apple). אחרי השינוי, `relHistory` יכיל ערכי **meters** גם כן — אבל מחושבים על ידינו מ-pressure. כל ה-variance/gap logic **ממשיך לעבוד זהה**, כי הוא כבר עובד ביחידות meters ולא ביחידות pressure. שקול מבנה `PressureBaseline` שהספק מציע, אך **לא** להכפיל state: `baselineSampleCount`/`baselineVarianceM`/`baselineMaxGapSec` הקיימים על ה-`Flight` כבר מספיקים; להוסיף רק `baselinePressureKPa: Double?` בתור שדה דיאגנוסטי גולמי (לא לחישוב, רק ל-log).

**ללא שינוי מהקודם:** אם ה-baseline לא יציב, לא נמחקת קפיצה — `heightFailureReason = .unstableBaseline`, `heightSource = .unavailable`, הקפיצה שה-IMU אישר נשמרת.

## 8. Pressure-to-Relative-Height Conversion

**נוסחה שנבחרה:** hypsometric formula בקירוב איזותרמי (isothermal barometric formula) — הפתרון הסטנדרטי, מתועד בפיזיקה אטמוספרית ובשימוש נרחב (ISA / hypsometric equation):

```
Δh = (R · T) / (M · g) · ln(P_baseline / P_current)
```

כאשר:
- `R = 8.314462618 J/(mol·K)` — קבוע הגזים האוניברסלי.
- `T` — טמפרטורה אבסולוטית בקלווין. **אין לנו חיישן טמפרטורה חי ב-CoreMotion** — קבוע קונפיגורציה `V14Config.assumedAirTempKelvin`, ברירת מחדל `288.15K` (15°C, ISA sea-level standard). זו הנחה מתועדת, לא כיול שרירותי — ותועד כ-**מקור שגיאה ידוע** (סעיף 23).
- `M = 0.0289644 kg/mol` — מסה מולרית של אוויר יבש.
- `g = 9.80665 m/s²` — תאוצת הכובד הסטנדרטית.
- `P_baseline`, `P_current` — **חייבים להיות באותה יחידה** (יחס בלבד, ה-`ln` מבטל יחידות). היחידה הקנונית בפרויקט: **hPa** (תואם ל-`IMUSample.pressure` הקיים).

בערכי `T=288.15K`: `H = RT/(Mg) ≈ 8434.5 m` (scale height).

**בדיקת כיוון סימן (נדרש בספק, מאומת):** לחץ יורד כשגובה עולה → `P_current < P_baseline` → `P_baseline/P_current > 1` → `ln(...) > 0` → `Δh > 0`. נכון.

**למה קירוב איזותרמי מספיק כאן:** קפיצות קייט הן 1–20 מטר. שגיאת הקירוב האיזותרמי גדלה עם הגובה המוחלט מעל פני הים ועם טווח הגובה הנמדד — עבור טווח של 20 מטר בגובה פני הים, השגיאה ביחס למודל ISA המלא (עם gradient טמפרטורה) היא זניחה (סאב-מילימטר). **אין צורך** במשוואת ברומטר מלאה רב-שכבתית.

**רגישות לטמפרטורה (מקור שגיאה מתועד, לא מכוסה):** בין 0°C ל-30°C, `H` נע בין ~7985m ל-~8859m (±5%) — על קפיצה של 20m זו סטייה של כ-±1m. זה תלוי-אקלים אמיתי (קיץ מול חורף, מים קרים) ולא ניתן לפתור בלי קלט טמפרטורה אמיתי. **לא להוסיף offset תיקון ללא כיול אמיתי** — לתעד את זה כמגבלה ידועה בלבד, ולשקול (עתידי, לא בסקופ) קריאת טמפרטורה מ-`CMDeviceMotion` אם/כאשר Apple תחשוף אותה, או כיול עונתי-ידני.

**ממצא אמפירי חשוב:** השוויתי בפועל, על לוג 0714, את הנוסחה שלנו מול `relativeAltitude` של Apple (אותם timestamps, אותו pressure input) — הם **לא** זהים. לדוגמה: t=6.11s ו-t=8.66s נושאים בדיוק אותו ערך pressure (1005.7210 hPa) אך Apple מדווחת שני ערכי `relativeAltitude` שונים (−0.53m ואז −0.37m). המסקנה: **ל-Apple יש smoothing/state פנימי לא-חשוף** שלא ניתן לשחזר מ-`pressure` בלבד — הפלט שלנו **יהיה שונה** מ-Apple's relativeAltitude, ולפעמים **רועש יותר** (כי Apple מסננת עבורנו כיום, ואנחנו מוותרים על זה). זו לא בעיה בנוסחה — זו סיבה ישירה לכך שסעיף 9 (סינון) הוא לא nice-to-have אלא **תחליף הכרחי** למסנן שהיה חבוי בתוך Apple's relativeAltitude.

```swift
struct PressureHeightSample {
    let timestamp: TimeInterval
    let rawPressureHPa: Double
    let filteredPressureHPa: Double
    let relativeHeightMeters: Double
    let quality: Double
}

enum V14PressureToHeightConverter {
    static func relativeHeightMeters(baselineHPa: Double,
                                     currentHPa: Double,
                                     airTempKelvin: Double) -> Double {
        let H = 8.314462618 * airTempKelvin / (0.0289644 * 9.80665)
        return H * log(baselineHPa / currentHPa)
    }
}
```

**Unit tests (מחייב, סעיף 20):** ln(1)=0 → Δh=0 בלי שינוי לחץ; pressure יורד → height עולה (סימן חיובי); pressure עולה → height שלילי (ירידה מתחת ל-baseline); 1 hPa ≈ 8.3m ב-scale height זה (בדיקת סדר גודל); אותה תוצאה בין hPa ל-kPa קלט (יחס משומר) — **מבחן חובה נגד ערבוב יחידות**; ערך קלט לא-פיזיקלי (pressure ≤ 0, NaN) → לא קורס, מטופל ב-guard.

## 9. Pressure Filtering and Noise Rejection

Pipeline (עדכון ל-diagram בספק, מותאם לקוד הקיים):

```
Raw pressure (hPa, from IMUSample.pressure — already ZOH-held + barometerTimestamp de-duped)
    ↓
Timestamp/finite validation (קיים: guard t.isFinite, altitudeM.isFinite, t > lastT)
    ↓
Spike/outlier rejection — קיים חלקית: relStepRejectM=10m / relStepReacceptCount=3
    על ערוץ ה-METERS (אחרי המרה) — לא על pressure עצמו. נשאר כך: קל יותר
    לכייל סף במטרים (משמעות פיזית ברורה) מאשר בלחץ (תלוי-scale-height).
    ↓
Robust short-window filter — **חדש, נדרש**: Apple's relativeAltitude כלל smoothing
    חבוי (סעיף 8) שאנחנו מוותרים עליו; בלעדיו pressure→height גולמי יהיה רועש יותר.
    ↓
Optional low-pass (EMA קצר) — רק אם replay מראה שהמדיה הקצרה לא מספיקה.
    ↓
Pressure-to-height conversion (סעיף 8)
    ↓
Apex analysis (סעיף 11-12)
```

**סדר הפעולות (החלטה מפורשת, מנוגד-לכאורה לספק):** הספק מציע לסנן pressure ואז להמיר לגובה. אני ממליץ **להמיר ראשון, לסנן שני**, מהסיבה הבאה: הטווח היחסי של pressure סביב baseline בקפיצה (±20m ⇒ ±0.24hPa) קטן מספיק שה-mapping `pressure→height` הוא **כמעט לינארי** לכל אורך הטווח (נגזרת `ln` כמעט קבועה בטווח כזה) — כלומר סינון לפני/אחרי ההמרה שקולים מתמטית עד כדי סטייה זניחה, אבל סינון **אחרי** המרה מאפשר שימוש חוזר ב-1:1 בכל תשתית ה-spike-rejection/baseline/apex הקיימת ב-`JumpEngineV14.swift` שכבר עובדת ב-meters (`relStepRejectM`, `landingStableBandM` וכו') בלי לשכפל אותה בשתי יחידות.

**Filters להשוואה ב-replay (כנדרש, סעיף 6 בספק):**

| Filter | ציפייה מנומקת מראש (לאמת ב-replay, לא להניח) |
|---|---|
| Moving median (קיים כבר כ-`median()` helper) | חוסן טוב ל-spikes בודדים, latency אפס — ברירת המחדל הטבעית |
| Hampel filter | דומה ל-median אך עם threshold מבוסס MAD — עדיף אם spikes לא-קבועי-גודל |
| Trimmed moving average | פשרה בין median ל-mean — פחות רלוונטי בהינתן ~2.56s cadence (כמעט אין "חלון" משמעותי בין דגימות) |
| EMA | latency-מבוקר, אך **מסוכן ל-apex attenuation** בהינתן 0-1 דגימות בטיסה — a EMA איטי ימחק את הדגימה הבודדת שיש |
| Butterworth / Savitzky-Golay | **לא רלוונטי בקצב 2.56s** — אלה כלים ל-multi-sample-per-event; עם 0-1 דגימה בטיסה אין "אות" לסנן בתוכה |
| Kalman | דורש כיול process/measurement noise מדוייק; ללא נתוני שדה אמיתיים על variance, זה ניחוש — **לא בפאזה 1** |

**מסקנה מוקדמת (ניתנת לסתירה ב-replay, לא סופית):** בהינתן קצב 2.56s, ה-filter המשמעותי ביותר הוא זה שפועל **על הערוץ הרציף** (riding + pre-takeoff + post-landing), לא על הדגימות הבודדות בתוך הטיסה עצמה — כי בפועל אין שם "אות" לסנן. Moving median על החלון הקיים (`baselineWindowSec`) ו-`landingStableSec` post-landing נשאר ה-workhorse; EMA/Kalman על 0-1 נקודות הן over-engineering.

## 10. Jump Window Extraction

`Flight.absSamples`/`relFlightSamples` (נוספו בסבב הקודם) הם כבר ה-ring buffer הזה: pre-takeoff (via `relHistory`, נשמר `historySec`=60s גלובלית), airborne (`relFlightSamples`), post-landing (`relHistory` ממשיך להצטבר, `confirmLandingIfStable` קורא ממנו). **לא נדרש buffer נפרד** (`V14PressureRingBuffer` בספק) — זה כבר קיים בשם אחר, עם אותה סמנטיקה (`historySec` = max buffer duration, `pruneHistory` = dropout/age policy). התוספת היחידה: לשמור גם `rawPressureHPa` לצד כל `TimedValue` (כרגע רק `v: Double` בערכי meters) — שינוי מבני קטן ל-`TimedValue` או struct מקביל.

## 11. Apex Detection Between Samples

**המצב הקיים (מהסבב הקודם):** `V14ApexQuality`/`V14HeightAnalyzer.apexQuality` מזהים apex כ-`samples.max { $0.v < $1.v }` — sample בודד, בלי interpolation, עם ציון persistence/edge-distance/coverage. זה בסדר להיום כי המקור (Apple's relativeAltitude) כבר "מוחלק" חלקית.

**מה שחייב להשתנות, בהינתן הממצא מסעיף 1:** ברוב הקפיצות (5/9 בלוג הייחוס) **אין אף דגימה** בתוך הטיסה — ה-apex "measured" היחיד הזמין הוא בפועל **הדגימה האחרונה לפני takeoff ו/או הראשונה אחרי landing**, לא משהו "בתוך" הקשת. במקרים כאלה, **אין apex אמיתי למדוד** — יש רק bounds (baseline ≤ apex, וקירוב פיזי מה-airtime כ-sanity check עליון, סעיף 13). זה חייב להיות `heightSource=.unavailable` או `.pressureInterpolated` עם `confidence` נמוך מאוד ו-`sampleCoverage=0`, **לא** אקסטרפולציה אגרסיבית.

ב-4/9 המקרים עם דגימה אחת בטיסה: ה-apex "measured" הוא פשוט אותה דגימה יחידה — אין "בין דגימות" למדוד, אין interpolation אמיתי אפשרי (צריך ≥2 נקודות בטיסה + אולי גבול baseline/landing כנקודה שלישית, סעיף 12).

## 12. Local Quadratic and Alternative Interpolation Methods

**Option A — Local quadratic, עם ההגבלה הריאלית:** מכיוון שברוב המקרים אין 3 דגימות בטיסה, ה-fit האמיתי ברוב הקפיצות משתמש ב-**3 נקודות עוגן לא-סימטריות**: `(takeoffBaseline, t_takeoff)`, `(measuredSample, t_sample)` (אם קיימת), `(landingBaseline, t_landing)` — לא 3 דגימות pressure "אמיתיות" בתוך הטיסה. זה עדיין `at²+bt+c` פורמלית, אבל יש להיות **שקוף** שזו אקסטרפולציה מוגבלת מ-boundary conditions, לא אינטרפולציה בין מדידות אמיתיות — התיוג ב-`ApexInterpolationMethod` צריך להבחין בין:

```swift
enum ApexInterpolationMethod {
    case measuredSample        // דגימה בודדת בטיסה, ללא fit — הרוב
    case quadraticMultiSample  // ≥2 דגימות אמיתיות בטיסה — נדיר בקצב הנוכחי
    case boundaryAnchored      // fit מ-baseline+landing בלבד, אין דגימה בטיסה
    case unavailable
}
```

**Bounds (חובה, כנדרש בספק):** אסור ל-fit "להמציא" שיא. הגבלה מוצעת: התיקון (`interpolatedHeight - nearestMeasuredHeight`) לא יעלה על `min(0.5m, 0.15 × nearestMeasuredHeight)` — ואם ה-vertex `t*` נופל **מחוץ** לחלון `[takeoffT, landingT]` (אקסטרפולציה, לא אינטרפולציה) → נדחה, fallback ל-`nearestMeasuredHeightMeters` בביטחון נמוך. אם `a ≥ 0` (הפרבולה לא נפתחת כלפי מטה — אין peak אמיתי) → נדחה מיידית.

**Option B — Spline:** לא מומלץ לפאזה 1. Spline דורש ≥4 נקודות בדרך כלל לתוצאה יציבה (cubic), וב-0/9 מהקפיצות הנבדקות יש אפילו 3 דגימות אמיתיות בטיסה. שקול אותו רק עבור hang-time ארוך במיוחד (>3s) שבו קצב 2.56s נותן סיכוי סביר ל-2+ דגימות — validate קודם על replay אם יש כזה סוג session בכלל.

**Option C — Piecewise ascent/apex/descent:** אותה בעיה — דורש מספיק דגימות בכל קטע. ריאלי רק עבור airtime ארוך.

**Option D — IMU-assisted (טיימינג/shape constraints בלבד, לא double-integration לגובה):** הכי ישים בפועל: להשתמש ב-`touchdownT`/`takeoffT` (כבר קיימים, IMU-accurate) כ-**bounds** ל-`t*`, ובקצב הזוויתי (gyro) המתמתן קרוב לנחיתה כאינדיקציה משנית לכך שה"תנועה האנכית" מתקרבת לסיום (לא מקור גובה — רק constraint). **אסור** (כפי שהספק מדגיש) להשתמש ב-double integration של accelerometer כמקור גובה ראשי — לא מוצע כאן בשום צורה.

**המלצה:** פאזה 1 מיישמת Option A (quadratic, עם bounds) + Option D (IMU בתור bounds בלבד) — זה כל מה שהנתונים בפועל תומכים בו. B/C נשארים "future, אם replay מראה שיש מספיק hang-time ארוך בפועל".

## 13. Limits of the Ballistic Model for Kite Jumps

כפי שכבר קיים ב-`JumpEngineV14.swift` (`ballisticHeight = 9.80665 * airtime² / 8`, `maxHeightBallisticFactor=1.3`, `ballisticCorroborationFraction=0.4`, `absoluteTrustFloorM=2.5`) — **זה נשאר בדיוק כמו שהוא**, ומשמש **רק** בתור:
1. Physics ceiling (`passesCeiling`) — פוסל ערך מדוד שגבוה יותר מפי 1.3 מהבליסטי, סימן ל-noise.
2. Sanity-check corroboration ל-fallback הבליסטי עצמו (`relativeContradictsBallistic`/`ballisticUncorroborated`).
3. **לא** מקור גובה ראשי, **לא** מניח סימטריה עלייה/ירידה, **לא** ממקם apex באמצע ה-airtime כברירת מחדל (`apexT` היום כבר גזור מ-`maxAbsT`/`maxRelT` בפועל, עם `(takeoffT + airtime/2)` כ-**fallback אחרון בלבד** כשאין שום דגימה — ראו §11: עם ה-boundary-anchored interpolation החדש, ה-fallback הזה אמור להיעלם כמעט תמיד, כי גם ללא דגימה בטיסה יש עכשיו הערכה מבוססת boundary ולא ניחוש-אמצע-נאיבי).

**נדרש שינוי קטן, לא מבני:** לוודא ש-`apexT` הנגזר מ-boundary-anchored quadratic (§12) מחליף את ה-`(takeoffT + airtime/2)` fallback הקיים — זה שיפור אמיתי, מבוסס physics-informed interpolation ולא ניחוש שרירותי.

## 14. Final Height Calculation Policy

```
jumpHeight = estimatedApexRelativeHeightMeters − 0   // ה-baseline עצמו הוא נקודת הייחוס (0m ביחס לעצמו)
```

מדיניות בחירת מקור (מרחיבה את מה שכבר קיים ב-`finalize()`, לא מחליפה):

```
if apex ∈ {measuredSample, quadraticMultiSample} with confidence ≥ threshold:
    finalHeight = interpolatedPeakHeight  (source = .pressureInterpolated)
elif apex ∈ {boundaryAnchored} or raw measured sample exists:
    finalHeight = filteredMeasuredPeakHeight  (source = .pressureFiltered / .pressureMeasured)
elif ballistic fallback passes corroboration (§13, unchanged):
    finalHeight = ballisticHeight  (source = .ballistic)
else:
    heightSource = .unavailable, heightM = 0, jump KEPT (לא נמחק — כמו בסבב הקודם)
```

זהו בדיוק אותו skeleton שכבר קיים ב-`finalize()` (השורה `if let h = passesCeiling(heightRelative...) ... else if ... else if cfg.allowBallisticHeightFallback ... else { .unavailable }`) — **רק** ש-`heightRelative` עצמו מחושב עכשיו מ-pressure+interpolation שלנו במקום מ-Apple's relativeAltitude token בודד. **אין להוסיף global correction factor** — נאסר גם בספק וגם בעקרונות העבודה הקיימים בקוד (`// אין correction שרירותי`).

## 15. Airtime and Vertical Metrics

`airtimeSec = touchdown − takeoffT` — **ללא שינוי**, IMU בלבד, כמו קודם.

חדש/מורחב (אפשרי כבר היום דרך `V14HeightAnalyzer`, רק שה-samples שמוזנות אליו משתנות): `timeToApexSeconds`, `maxAscentRateMps`/`averageAscentRateMps`, `maxDescentRateMps`/`averageDescentRateMps`. **אזהרה נוספת לאור הממצא ב-§1:** נגזרת אנכית מחושבת מ-≤1 דגימה בטיסה **אינה** אמינה — `maxAscentRateMps` וכו' צריכים להיות `nil` (לא 0, לא ערך מומצא) כשאין ≥2 דגימות אמיתיות למדוד נגזרת ביניהן. אין "לחשב נגזרת" משתי נקודות boundary-anchored — זו לא מדידה.

## 16. Detection Confidence vs Height Confidence

**קיים כבר** מהסבב הקודם (`V14Jump.detectionConfidence`/`heightConfidence`, `V14HeightAnalyzer.heightConfidence(source:baseline:apex:)`). מה שמשתנה: `heightConfidence` צריך גם לשקף במפורש **כמה דגימות אמיתיות** תמכו במדידה (`sampleCoverage`/`interpolationQuality` בספק) — היום `apexQuality.sampleCount`/`altitudeCoverage` כבר קיימים, אבל בהינתן ש-0-1 יהיה הרוב, `heightConfidence` הנוסחה הקיימת (`0.5×baseline.quality + 0.5×apex.confidence`) צריכה להיבדק ב-replay שהיא לא "אופטימית מדי" עבור `boundaryAnchored`/`measuredSample` יחיד. המלצה: להוסיף weight נפרד ל-`interpolationMethod` בתוך `heightConfidence` — `measuredSample`/`boundaryAnchored` מקבלים תקרת confidence נמוכה יותר מ-`quadraticMultiSample`, גם אם שאר המדדים טובים — **לא לכייל את המספרים המדויקים כאן**, רק את הכיוון; המספרים עצמם דורשים replay (פאזה 5).

## 17. Shadow Mode and Comparison

**קריטי: יש כרגע 2 גרסאות "ישנות" להשוות, לא 1.** ה-shadow mode הזה צריך שלוש עמודות, לא שתיים:

```
v14_old_height (Apple relativeAltitude, priority: relative-first מהסבב הקודם — זו הגרסה שרצה היום)
v14_pressure_measured / v14_pressure_filtered / v14_pressure_interpolated (החדש, מה-pressure שלנו)
```

יישום: אין להריץ שני engines מלאים — `JumpEngineV14.finalize()` ימשיך לחשב `heightRelative` בדיוק כפי שהוא היום (מוזן מ-Apple's relativeAltitude, ללא שינוי), **וגם** יחשב את השרשרת החדשה (pressure→convert→filter→interpolate) מקבילית, מלוגים אל `SessionLogger`, אך `Jump.height`/`heightSource` שנשמר ל-session **ממשיך להיות מהמקור הישן** עד שה-replay מאמת. רק אחרי אימות (§20-21) מוחלף ה-input בפועל של `relativeAltitudeFrame` (§4) מ-`sample.relativeAltitude` ל-pressure-converter output — וברגע שזה קורה, "old" הופך פשוט ללא-רלוונטי (אין יותר Apple relativeAltitude בשום מקום בקוד).

## 18. Logging and Replay

הרחבה של השדות שכבר נוספו בסבב הקודם (`v14_detection_confidence`, `v14_height_confidence`, `v14_baseline_quality`, `v14_apex_confidence`, `v14_altitude_coverage`, `v14_height_failure_reason`) — מוסיפים:

```
v14_raw_pressure_hpa
v14_filtered_pressure_hpa
v14_baseline_pressure_hpa
v14_pressure_delta_hpa
v14_pressure_relative_height        (המקור החדש)
v14_old_relative_height             (Apple's relativeAltitude — לצורך השוואה, עד שמוסר)
v14_apex_interpolation_method
v14_apex_fit_residual
v14_pressure_sample_interval_sec    (נמדד בפועל, לא קבוע — ~2.56s בלוגי הייחוס, לרשום לכל session בנפרד)
v14_pressure_sample_age_sec
v14_pressure_dropout_count
v14_pressure_sample_coverage
```

עמודות **מתווספות בסוף** ל-CSV הקיים (`SessionLogger.swift`), אין שינוי שמות, `schema version` field אם עדיין לא קיים ברמת ה-session header — יש לוודא (בדיקה נדרשת, §19) ש-`SessionLogger` כבר תומך בהוספת עמודות ללא שבירת parsers ישנים (ה-pattern הזה כבר קיים היום, `heightSource`/`absoluteTakeoffAltitude` וכו' כבר נוספו כך בעבר ל-`Jump`, אז זה מסלול מוכח).

## 19. Required File Changes

| קובץ | שינוי |
|---|---|
| `Services/V14PressureToHeightConverter.swift` | **חדש** — נוסחת ln(P0/P), config לטמפרטורה, unit-testable בבידוד |
| `Services/V14HeightAnalyzer.swift` | עריכה — `apexQuality` מורחב ל-interpolation (§11-12: `ApexInterpolationMethod`, bounds, boundary-anchored fit). Baseline logic נשארת כמעט זהה |
| `Services/JumpEngineV14.swift` | עריכה ממוקדת — `finalize()` מקבל apex-interpolation call; `Flight`/`TimedValue` מרחיבים לשאת `rawPressureHPa` אופציונלי לצד ה-meters value |
| `Services/JumpDetectorV14.swift` | עריכה — `relativeAltitudeFrame` (389-396) קורא `sample.pressure` דרך `V14PressureToHeightConverter` במקום `sample.relativeAltitude`. שאר ה-de-dup/alignment logic ללא שינוי |
| `Models/Session.swift` | ללא שינוי סכימה נדרש — `IMUSample.pressure` כבר קיים; שדות `Jump` הקיימים מהסבב הקודם (`heightConfidence` וכו') מספיקים; לשקול רק `interpolationMethod: String?` נוסף אם replay מראה ערך אמיתי ב-UI |
| `Services/SessionLogger.swift` | עריכה תוספתית — שדות §18 |
| `Views/SettingsView.swift` | אין שינוי חובה בפאזה זו (shadow mode לא חושף UI חדש) |
| `Package.swift` (root) | הוספת `V14PressureToHeightConverter.swift` ל-`sources:` allowlist (כמו שנעשה ל-`V14HeightAnalyzer.swift` בסבב הקודם) |
| `Tools/JumpReplay/.../WatchSources/V14PressureToHeightConverter.swift` | **סימלינק חדש**, אותה מוסכמה קיימת |
| `Tools/JumpReplay/.../EngineE2ESelfTest.swift` + `Tests/WatchLiveSessionCoreChecks/main.swift` | תרחישים חדשים (§20) |

**לא נוגעים:** `MotionManager.swift` (§5 — אין acquisition חדש), `SessionManager.swift`, `JumpDetecting.swift`.

## 20. Unit, Replay and Regression Tests

**Unit (על `V14PressureToHeightConverter` ו-`V14HeightAnalyzer` המורחב, מבודד):**
ln(1)=0; pressure יורד→height חיובי; pressure עולה→height שלילי; קלט hPa מול kPa נותן תוצאה זהה (יחס משומר) — **חובה, נגד ערבוב יחידות**; pressure≤0/NaN לא קורס; baseline יציב/רועש; spike בודד נדחה; חסרות דגימות pre-takeoff; timestamps לא-סדירים; דגימה מאוחרת; baseline drift מתמשך (שינוי שמתחיל *לפני* חלון הקפיצה — נבדל מ-spike חד); קפיצה נמוכה (~1m, 0 דגימות בטיסה — התרחיש **השכיח** לפי המדידה); קפיצה 10-20m; local quadratic עם 2/3 דגימות אמיתיות; `boundaryAnchored` fit; אקסטרפולציה (vertex מחוץ לחלון) נדחית; parabola פתוחה כלפי מעלה (`a≥0`) נדחית; spline overshoot prevention (אם/כש-Option B ממומש); apex בין 2 דגימות; מספר local minima בלחץ; ללא GPS; ללא absolute altitude; ללא Apple relativeAltitude (כבר לא בשימוש, אז זה "given" ולא תרחיש נפרד).

**Replay:** אותם 3 לוגים שכבר שימשו לregression בסבב הקודם (`log_20260714_135926_BF228815`, `log_20260708_141804_1C077C74`, `log_v14_20260717_145840_FD5F91F0`) — עכשיו עם focus נוסף: **כמה קפיצות מקבלות `heightSource=.unavailable` או `boundaryAnchored`** (צפוי רוב, לפי §1) לעומת `quadraticMultiSample` (צפוי נדיר/אפס בקצב הנוכחי). session ללא GPS. Hang-time ארוך (אם קיים לוג כזה — לחפש).

**Regression (gate למיזוג, זהה בעיקרון לסבב הקודם):** מספר וזהות הקפיצות (takeoffT/landingT/airtime) ב-3 הלוגים חייבים להישאר **זהים בדיוק** למה שנמדד היום (9/8/6 בהתאמה, §אימות קודם) — **רק** `heightM`/`heightSource`/`apexT` רשאים להשתנות, ורק בפאזה שאחרי shadow validation.

## 21. Incremental Implementation Phases

**Phase 0 — Baseline capture.** להריץ replay על 3 הלוגים עם המצב הנוכחי (relative-first, Apple relativeAltitude) ולשמור JSON — regression anchor, בדיוק כמו בסבב הקודם.

**Phase 1 — Converter + unit tests.** `V14PressureToHeightConverter` בבידוד מלא, טסטים כמו §20, ללא חיבור למנוע.

**Phase 2 — Shadow wiring.** `finalize()` מחשב את שרשרת ה-pressure במקביל (§17), לוגים בלבד, `Jump.height` הנשמר עדיין מה-Apple relativeAltitude הישן.

**Phase 3 — Replay comparison.** להריץ על כל הלוגים הקיימים (כולל הרבה יותר משלושה, אם זמינים) ולהשוות `v14_old_relative_height` מול `v14_pressure_*` — דוח: כמה קפיצות "מאבדות" apex (0 דגימות בטיסה), כמה שומרות אותה height בטווח סביר (±0.5m?), כמה סוטות משמעותית ולמה.

**Phase 4 — Interpolation calibration.** לכייל bounds/thresholds ל-quadratic fit **רק** מהדוח של Phase 3 — לא מספרים מומצאים.

**Phase 5 — Controlled activation.** להחליף את ה-input בפועל (`relativeAltitudeFrame` קורא `sample.pressure` במקום `sample.relativeAltitude`) — **רק** אחרי ש-Phase 3-4 מראים שמספר/זהות הקפיצות לא השתנו ושה-height לא נחות משמעותית מהמקור הישן (Apple).

**Phase 6 — Cleanup.** להסיר את קריאת `sample.relativeAltitude` הישנה מכל מקום (השדה עצמו נשאר בסכימה ל-backward-compat של לוגים ישנים בלבד, לא נקרא יותר).

## 22. Acceptance Criteria

- [ ] אין קריאה ל-`CMAltimeter.isAbsoluteAltitudeAvailable`/`startAbsoluteAltitudeUpdates` כתלות חובה (כבר מתקיים).
- [ ] אין קריאה ל-`sample.relativeAltitude` (Apple) בשום מסלול חישוב גובה חי — נשאר רק כשדה legacy בסכימה.
- [ ] `pressure` (hPa, מ-`CMAltitudeData.pressure`) הוא הקלט היחיד לחישוב גובה.
- [ ] הנוסחה מתועדת, יחידות מפורשות, כיוון סימן נבדק ב-unit test.
- [ ] Baseline נמדד לפני כל קפיצה מ-`relHistory`/pressure, לא דגימה בודדת.
- [ ] Interpolation מוגבל (bounds, extrapolation-rejection, `a<0` check) — לא מסוגל "להמציא" שיא.
- [ ] מודל בליסטי משמש **רק** constraint/sanity-check — נשאר בדיוק כמו שהוא היום.
- [ ] אין הנחת סימטריה עלייה/ירידה, אין airtime כמקור גובה, אין double-integration.
- [ ] Shadow mode מריץ את שתי השרשראות (Apple relativeAltitude מול pressure שלנו) עד לאימות.
- [ ] `detectionConfidence`/`heightConfidence` נפרדים (כבר קיים, מורחב).
- [ ] כשל מדידה לא מוחק קפיצה שה-IMU אישר (כבר קיים כעיקרון, `heightSource=.unavailable`).
- [ ] מספר/זהות הקפיצות ב-3 לוגי הרפרנס זהים לפני/אחרי (regression, כמו בסבב הקודם).
- [ ] כל עובדה על sampling rate/units/threading מגובה במקור (Apple docs, פורום מתועד, או מדידה ישירה מלוג אמיתי) — לא הנחה.

## 23. Risks and Needs Verification

1. **הממצא המרכזי (§1, §11):** בקצב מדוד של ~2.56s, רוב הקפיצות (5/9 בלוג הייחוס) לא מקבלות אף דגימת pressure בתוך הטיסה. המשמעות: רוב "השיפור" המובטח מ-interpolation (§12) פשוט **לא ישים** על רוב הקפיצות בהינתן החומרה/הקצב הנוכחי — יש לתקשר את זה בבירור למשתמש/למוצר: זו לא כשל בתכנון, זו מגבלת חומרה אמיתית. אם יש רצון אמיתי לשפר את זה, האפשרות היחידה היא לבדוק אם `startRelativeAltitudeUpdates` ניתן להאצה (לא ידוע שיש דרך רשמית — Apple לא חושפת קונפיגורציית קצב, בניגוד לגירוסקופ/accelerometer).
2. **Apple's relativeAltitude כולל סינון חבוי לא-משוחזר (§8).** המעבר ל-pressure גולמי צפוי להיות **רועש יותר**, לא פחות, אלא אם השכבה החדשה של סינון (§9) מפצה על זה במלואה. יש לאמת ב-replay שהמדידה החדשה לא **גרועה** מה-baseline הקיים (relative-first, Apple), לא רק "שונה".
3. **תלות בטמפרטורה לא-מכוילת (§8).** ±5% ב-scale height ≈ ±1m על קפיצת 20m. ידוע, לא פתור, מתועד כמגבלה.
4. **קצב 2.56s נמדד על watchOS session אחד/שני מכשירים בלבד** — ייתכן שמשתנה בין דגמי Watch, גרסאות watchOS, או מצבי צריכת חשמל. אין להניח שהוא קבוע גלובלית; יש למדוד מחדש בכל שינוי סביבה.
5. **חפיפה עם V15** (כבר עלה בסבב הקודם) — `JumpEngineV15`/`JumpDetectorV15` כבר קיימים כמנוע "clean" נפרד עם absolute apexFit רציף. שני מסלולי פיתוח מקבילים (V14→pressure-only, V15→clean+absolute) עשויים לסתור זה את זה בכיוון המוצרי (V14 הולך *מרחוק* מ-Apple altitude products, V15 הולך *לקראת* שימוש רציף בהם). שווה החלטה מוצרית מפורשת: האם V14 raw-pressure הוא מסלול production אמיתי (למשל, לצורך ניידות ל-Garmin/Wear OS), או אימות טכני בלבד.
6. **פוטנציאל cross-platform (המניע המוצהר, §2 בבקשת המשתמש)** — אם המטרה האמיתית היא Garmin/Wear OS, שווה לוודא מוקדם (**לפני** פאזה 4) שחיישן הלחץ בפלטפורמות האלה נותן קצב/יחידות ברי-השוואה — אחרת בונים תשתית "עצמאית מ-Apple" שעדיין לא תואמת בפועל לפלטפורמה השנייה.

## 24. Final Recommendation

**להתקדם בזהירות, בהינתן הממצא המרכזי.** התשתית הארכיטקטונית (baseline quality, apex confidence, detection/height confidence split, `.unavailable` path) כבר קיימת ועובדת מהסבב הקודם — זה לא rewrite, זה subsitution ממוקד של input source אחד (`sample.pressure` במקום `sample.relativeAltitude`) פלוס שכבת סינון וinterpolation חדשה ומוגבלת. אבל המדידה בפועל על שני לוגים אמיתיים מראה שה-value proposition המרכזי של הספק — "אינטרפולציה בין דגימות בטיסה לשיפור דיוק ה-apex" — ישים על **מיעוט** מהקפיצות בקצב הדגימה הנוכחי (2.56s). יש להיכנס לפרויקט הזה עם ציפייה נכונה: השיפור העיקרי הוא **עצמאות/ניידות** (לא תלוי ב-Apple, ניתן למימוש ב-Garmin/Wear OS), **לא** בהכרח דיוק גובה גבוה יותר על אותה חומרה — וייתכן שהמדידה החדשה תהיה **רועשת יותר** מ-Apple's relativeAltitude (§8, §23-2) עד שהסינון שלנו יפוצה עליה. Shadow mode ו-replay validation (§17, §20-21) הם לא "nice to have" כאן — הם התנאי לדעת אם השינוי בכלל שווה את המעבר.

---

**מקורות (Apple Developer Documentation + Forums, מאומתים ב-web search לצורך המסמך הזה):**
- [CMAltitudeData.pressure](https://developer.apple.com/documentation/coremotion/cmaltitudedata/pressure) — kilopascals.
- [CMAltitudeData.relativeAltitude](https://developer.apple.com/documentation/coremotion/cmaltitudedata/relativealtitude) — metres, change since first reported event.
- [CMAltimeter.startRelativeAltitudeUpdates](https://developer.apple.com/documentation/coremotion/cmaltimeter/1616004-startrelativealtitudeupdates) — יחיד callback, מחזיר `pressure` ו-`relativeAltitude` יחד; קצב עדכון אינו מתועד רשמית.
- מדידות מקומיות: `SPOTEQ/Tools/JumpReplay --dump-samples` על `log_20260714_135926_BF228815.kslog` ו-`log_v14_20260717_145840_FD5F91F0.kslog` (ראו §1, §5, §11 — מספרים גולמיים בתוך המסמך, לא בקובץ נפרד).
