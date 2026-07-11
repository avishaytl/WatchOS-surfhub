# מנוע קפיצות V13 - מסמך סיכום לפי הקוד האמיתי

מסמך זה מתאר את מנוע V13 כפי שהוא ממומש בפועל בקוד הנוכחי, אחרי המעבר למנוע פשוט שמבוסס על Absolute Altitude ו־GPS. המטרה היא להבין בדיוק איך המנוע עובד מקצה לקצה, מה הוא כן עושה, מה הוא לא עושה, ואיפה יש פרטים שחשוב להכיר לפני בדיקות שטח.

קבצים שעליהם המסמך מבוסס:

- `Kiters/Kiters Watch App/Services/JumpEngineV13.swift`
- `Kiters/Kiters Watch App/Services/JumpDetectorV13.swift`
- `Kiters/Kiters Watch App/Services/SessionManager.swift`
- `Kiters/Tests/WatchLiveSessionCoreChecks/main.swift`
- `Kiters/Tools/JumpReplay/Sources/JumpReplay/EngineE2ESelfTest.swift`

## תקציר

V13 הוא מנוע קפיצות פשוט:

- פתיחת קפיצה נעשית לפי שינוי ב־Absolute Altitude בלבד.
- אין תנאי IMU לפתיחת קפיצה.
- אין buffer ארוך או שחזור offline מתוך 60 שניות.
- יש חלון קצר לזיהוי עלייה, state של קפיצה פעילה, וחלון נחיתה יציב של 2 שניות.
- הגובה הסופי הוא `max absolute altitude` פחות בסיס נחיתה יציב.
- זמן האוויר הוא מתחילת חלון העלייה שפתח את תנאי הקפיצה עד תחילת חלון הנחיתה היציב.
- GPS משמש למהירות ולמרחק, ויש אפשרות להפעיל GPS gates דרך `UserDefaults`.

## מבנה הקוד

### `JumpEngineV13`

זו ליבת המנוע. היא לא תלויה ב־CoreMotion או WatchKit. היא מקבלת ערכים פשוטים:

- `addAltitude(t:altitudeM:)`
- `addIMU(t:accelG:gyroRadS:)`
- `addGPS(t:lat:lng:speedMS:)`
- `addSubmersion(t:submerged:)`

הפלט הוא `V13Jump`.

### `JumpDetectorV13`

זה האדפטר של האפליקציה לשעון:

- קורא `IMUSample`.
- בוחר מקור גובה.
- מסנן דגימות altitude כפולות.
- מזין את `JumpEngineV13`.
- ממפה `V13Jump` למודל `Jump` של האפליקציה.
- קורא הגדרות מ־`UserDefaults`.

### `SessionManager`

כאשר המשתמש בוחר `v13-pure`:

- מתבצעת בדיקת readiness לצורך אבחון ולוג בלבד.
- אין fallback ל־V11. אם המשתמש בחר V13, המנוע הפעיל נשאר V13 גם אם readiness מדווח על בעיה.
- אם V13 פעיל, ה־motion pipeline מתחיל מיד, כמו V12, כדי לקבל altitude/motion בלי לחכות ל־workout path מאוחר.

## מקורות חיישנים

### גובה

ב־`JumpDetectorV13.altitudeFrame`, סדר העדיפויות הוא:

1. `absoluteAltitude`
2. `relativeAltitude`
3. pressure שמומר לגובה ברומטרי

לסשן חי, readiness של V13 דורש:

- device motion זמין.
- הרשאת altimeter אינה denied/restricted.
- `CMAltimeter.isAbsoluteAltitudeAvailable()` זמין.

כלומר המנוע מיועד לעבוד בפועל עם Absolute Altitude. ה־fallback ל־relative/pressure קיים בעיקר כדי להריץ replay על לוגים ישנים או degraded data.

### IMU

IMU לא פותח קפיצה ולא משמש כתנאי.

הקוד כן אוסף ממנו metrics בזמן קפיצה פעילה:

- `takeoffG`
- `peakG`
- `maxRotationRadS`
- `rotationTurns`
- `impactEnergy`

אבל אם אין IMU חזק, הקפיצה עדיין יכולה להתגלות לפי altitude בלבד.

### GPS

GPS נשמר כ־`latestGPS`, ובתחילת קפיצה נשמר `launchGPS`.

השימושים:

- `takeoffSpeedMS`
- `landingSpeedMS`
- `distanceM`
- `launchLat/lng`
- `landingLat/lng`

אם יש קואורדינטות אמיתיות, המרחק מחושב עם haversine. אם אין קואורדינטות אבל יש speed, המרחק מחושב כ־`speed * airtime`.

## הגדרות מרכזיות

ב־`V13Config`:

```swift
minRiseM = 1.0
minGpsSpeedMS = 0.0
minGpsDistanceM = 0.0
landingStableSec = 2.0
landingStableDeltaM = 0.25
landingStableRangeM = 0.6
landingReturnBandM = 0.75
minAirtimeSec = 0.2
maxAirtimeSec = 12.0
maxFlightSec = 20.0
maxJumpHeightM = 30.0
retriggerGuardSec = 0.8
maxBaselineDriftM = 2.0
```

ב־`JumpDetectorV13`, חלק מהערכים נטענים מ־`UserDefaults`, כולל:

- `v13MinRiseM`
- `v13MinGpsSpeedMS`
- `v13MinGpsDistanceM`
- `v13LandingStableSec`
- `v13LandingStableRangeM`
- `v13LandingImpactG`
- `v13MinAirtimeSec`
- `v13MaxAirtimeSec`
- `v13MaxFlightSec`
- `v13MaxResultDelaySec`
- `v13MaxBaselineDriftM`
- `v13MaxJumpHeightM`

חשוב: במסך ההגדרות כרגע חשוף בעיקר `v13MinRiseM` כבחירה של 1.0 / 1.5 / 2.0 מטר. GPS gates קיימים בקוד וב־UserDefaults, אבל לא בהכרח חשופים כרגע UI.

## State Machine

למנוע יש שני מצבים בלבד:

```swift
idle
airborne(ActiveJump)
```

אין `pendingTakeoff` ואין דגימת אישור נוספת. כאשר חלון העלייה עובר את סף הגובה, הקפיצה נפתחת מיד.

## שלב 1: מצב idle וחלון תנאי קפיצה

במצב idle המנוע מחזיק:

```swift
takeoffWindow: [AltPt]
```

כל דגימת altitude חדשה נכנסת לחלון. החלון נחתך לפי:

```swift
takeoffWindowSec = max(0.5, minRiseM)
```

כלומר:

| `minRiseM` | חלון קפיצה בקוד |
|---|---|
| 1.0 מטר | 1.0 שניה |
| 1.5 מטר | 1.5 שניות |
| 2.0 מטר | 2.0 שניות |

התנאי העיקרי:

```text
altitude האחרון בחלון - altitude הראשון בחלון >= minRiseM
```

### פרט חשוב: 80% מהחלון

בפועל הקוד מאפשר בדיקה כאשר אורך החלון הוא לפחות:

```swift
takeoffWindowSec * 0.8
```

כלומר הוא לא מחכה תמיד ל־100% מהחלון. זה כנראה כדי להתאים לדגימת altitude סביב 3Hz, שבה לא תמיד נופלים בדיוק על 1.0/1.5/2.0 שניות.

אם רוצים התנהגות נוקשה לגמרי לפי הדרישה המילולית, צריך לשנות את זה ל־`takeoffWindowSec` מלא.

## שלב 2: פתיחת קפיצה

כאשר חלון הקפיצה מזהה עלייה מעל הסף, המנוע יוצר `ActiveJump` מיד.

ברגע הזה נשמרים:

- `takeoffT`: זמן הדגימה הראשונה בחלון העלייה.
- `baselineAlt`: הגובה בתחילת חלון העלייה.
- `launchGPS`: GPS שהיה ידוע בזמן פתיחת התנאי.
- `maxAlt`: המקסימום הידוע עד עכשיו.
- `apexT`: זמן המקסימום הידוע עד עכשיו.
- counters ו־metrics.

הקפיצה מדווחת ב־debug כ:

```text
CANDIDATE altitude rise=...
```

ב־UI state זה ממופה ל־`airborne`.

## שלב 3: מעקב אחרי שיא הגובה

במצב airborne, כל דגימת altitude חדשה:

- מעדכנת ascent/descent rate.
- מגדילה `altitudePointCount`.
- אם altitude גדול מ־`maxAlt`, אז:
  - `maxAlt` מתעדכן.
  - `apexT` מתעדכן.
  - חלון הנחיתה נמחק, כי עדיין עולים או הגענו לשיא חדש.

הגובה הסופי עוד לא מחושב בשלב הזה.

## שלב 4: התחלת חיפוש נחיתה

המנוע מתחיל לבנות חלון נחיתה רק אחרי ירידה משמעותית מהשיא:

```swift
jump.maxAlt - p.alt >= max(0.25, minRiseM * 0.5)
```

כלומר צריך לרדת לפחות:

- 0.5m עבור סף 1m
- 0.75m עבור סף 1.5m
- 1m עבור סף 2m

ברגע שיש ירידה כזו, הדגימות נכנסות ל־`landingWindow`.

## שלב 5: תנאי נחיתה יציבה

חלון נחיתה עובר בדיקה ב־`stableLanding`.

התנאים:

1. יש דגימה ראשונה ואחרונה.
2. משך החלון הוא בערך 2 שניות:

```swift
last.t - first.t + 0.05 >= landingStableSec
```

ה־`+0.05` הוא tolerance קטן כדי לא ליפול על שגיאות תזמון של דגימה ב־3Hz.

3. ההפרש בין הדגימה הראשונה לאחרונה קטן:

```swift
abs(last.alt - first.alt) <= landingStableDeltaM
```

ברירת מחדל: 0.25m.

4. הטווח המלא בתוך החלון קטן:

```swift
max(window) - min(window) <= landingStableRangeM
```

ברירת מחדל: 0.6m.

אם התנאים מתקיימים:

- `landingT` הוא הזמן של הדגימה הראשונה בחלון היציב.
- `baseline` הוא ממוצע כל ערכי הגובה בחלון.
- `range` הוא טווח הגובה בחלון.

## שלב 6: חישוב גובה

גובה הקפיצה מחושב כך:

```swift
rawHeight = jump.maxAlt - stable.baseline
height = min(rawHeight, maxJumpHeightM)
```

כלומר:

```text
גובה = הגובה האבסולוטי הגבוה ביותר - בסיס הנחיתה היציב
```

זה תואם את ההחלטה האחרונה: לא baseline לפני קפיצה, לא interpolation, אלא בסיס יציב אחרי נחיתה.

## שלב 7: חישוב זמן אוויר

זמן האוויר:

```swift
airtime = stable.landingT - jump.takeoffT
```

כלומר:

```text
זמן אוויר = רגע תנאי קפיצה - רגע תחילת יציבות נחיתה
```

אין תיקון לפי IMU. אין ballistic model.

## שלב 8: GPS speed/distance

המרחק מחושב כך:

1. אם יש GPS קואורדינטות אמיתיות בהתחלה ובסוף:

```text
distance = haversine(launchGPS, landingGPS)
```

2. אחרת, אם יש GPS speed:

```text
distance = speed * airtime
```

ה־GPS gates:

```swift
minGpsSpeedMS
minGpsDistanceM
```

ברירת המחדל היא 0, אז הם לא פוסלים. אם מגדירים ערך מעל 0:

- קפיצה תיפסל אם מהירות GPS בהתחלה נמוכה מהסף.
- קפיצה תיפסל אם מרחק GPS/מהירות כפול זמן נמוך מהסף.

## שלב 9: פסילות אחרי סיום הקפיצה

המנוע לא פוסל לפי IMU, אבל כן פוסל אחרי שיש sequence של altitude/landing:

- גובה מתחת ל־`minRiseM`.
- זמן אוויר מחוץ ל־`minAirtimeSec...maxAirtimeSec`.
- GPS speed gate אם הופעל.
- GPS distance gate אם הופעל.
- max flight exceeded אם הקפיצה נמשכת מעל `maxFlightSec`.
- session ended לפני חלון נחיתה יציב.

## Confidence

ה־confidence פשוט:

מתחיל מ־0.65.

תוספות:

- `+0.1` אם חלון הנחיתה יציב מאוד.
- `+0.1` אם היה GPS בתחילת הקפיצה.
- `+0.05` אם חושב מרחק.

הפחתה:

- `-0.15` אם baseline drift גדול מ־`maxBaselineDriftM`.

בסוף הערך נחתך לטווח 0.05 עד 1.0, ובאדפטר הוא מוכפל ל־0 עד 100.

## פלט `V13Jump`

המנוע מחזיר:

- `heightM`
- `airtimeSec`
- `takeoffT`
- `landingT`
- `apexT`
- `peakAltitudeM`
- `baselinePreM`
- `baselinePostM`
- `baselineRefM`
- `baselineShifted`
- `driftSuspect`
- ascent/descent rates
- IMU metrics אופציונליים
- GPS speed/distance/location
- `altitudePointCount`
- `confidence`
- `triggerSource = altitude`
- `emittedAtT`
- `profile`

האדפטר ממפה את זה ל־`Jump` של האפליקציה.

## מה `JumpDetectorV13` מוסיף

האדפטר:

- בונה `V13Config` מהגדרות.
- בודק readiness ל־Absolute Altitude.
- שומר `activeAltitudeSource`.
- אם timestamp של altimeter לא מיושר לציר ה־motion, משתמש בזמן ה־motion שבו ערך הגובה הופיע.
- מונע הזנת altitude כפולה כאשר אותו timestamp או אותו ערך מוחזק על כמה דגימות IMU.
- מזין GPS למנוע.
- מזין IMU למנוע רק בשביל metrics.
- ממפה state debug:
  - `CANDIDATE` -> airborne
  - `JUMP` / `REJECT` / `CLOSE` -> riding

חשוב: ה־header comment של `JumpDetectorV13` עודכן כך שיתאר את ההתנהגות הנוכחית: altitude-first, ללא ring buffer ארוך וללא IMU כתנאי פתיחת קפיצה.

## בדיקות קיימות

ב־`WatchLiveSessionCoreChecks` קיימות בדיקות:

- קפיצה נקייה מזוהה אחרי נחיתה.
- עלייה שלא השלימה את חלון הזמן המוגדר לא פותחת קפיצה.
- drift בבסיס הנחיתה מחושב לפי בסיס יציב.
- אם הסשן נגמר לפני חלון נחיתה מלא של 2 שניות, לא נפלטת קפיצה.

ב־`JumpReplay --engine-e2e-selftest` קיימת בדיקת adapter:

- 50Hz IMU.
- 3Hz Absolute Altitude.
- GPS.
- קפיצה נפתחת לפי altitude.
- תוצאה נפלטת אחרי חלון נחיתה יציב.

פקודות שעברו:

```bash
swift run WatchLiveSessionCoreChecks
swift run JumpReplay --engine-e2e-selftest
```

## התאמה לדרישה שלך

| דרישה | מצב בקוד |
|---|---|
| אין תנאי IMU | תואם. IMU לא פותח קפיצה. |
| אין buffer ארוך | תואם. יש רק חלונות קטנים ו־state נוכחי. |
| תנאי קפיצה 1/1.5/2 לפי absolute altitude | תואם, עם הערה שהקוד בודק אחרי 80% מהחלון כדי להתאים ל־3Hz. |
| גובה לפי absolute max מרגע תנאי קפיצה | תואם. |
| נחיתה בחזרה מהשיא לבסיס | תואם דרך ירידה מהשיא וחלון יציב. |
| חלון נחיתה 2 שניות | תואם, עם tolerance קטן של 0.05s. |
| בסיס נחיתה יציב וחיסור ממנו | תואם. baseline הוא ממוצע חלון הנחיתה. |
| זמן אוויר מרגע קפיצה עד רגע נחיתה | תואם לפי `takeoffT` עד תחילת חלון הנחיתה היציב. |
| מהירות GPS | קיים ונשמר, gate אפשרי אם `minGpsSpeedMS > 0`. |
| מרחק GPS | קיים ונשמר, gate אפשרי אם `minGpsDistanceM > 0`. |
| שינוי סף במסך הגדרות | קיים עבור `v13MinRiseM`. |
| אין fallback מ־V13 ל־V11 | תואם. readiness של V13 הוא אבחוני בלבד; בחירת V13 משאירה את V13 פעיל. |

## נקודות החלטה להמשך

1. האם להשאיר את בדיקת 80% חלון או להקשיח ל־100%.

2. אילו ערכים לשים ל־GPS gates:

   - `minGpsSpeedMS`
   - `minGpsDistanceM`

3. האם לחשוף GPS gates במסך Settings.

4. האם לשנות את comment הישן ב־`JumpDetectorV13` כדי שלא יטעה מפתחים בעתיד.

5. האם `landingStableDeltaM = 0.25` קשיח מדי לים עם chop.

6. האם `landingStableRangeM = 0.6` רך מדי ויכול לקבל false landing בגלים.
