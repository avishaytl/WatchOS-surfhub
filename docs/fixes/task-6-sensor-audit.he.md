# משימה 6 — אימות כל חיישני הסשן מקצה-לקצה

## הבעיה

החשש: מסך הסשן הפעיל "מזייף" נתונים (GPS, מהירות, חיישנים) — שכל ערך באמת מחובר למקור אמיתי, ושמדדים
לא "תופסים" תזוזות לא-רלוונטיות (רעש בעמידה).

## הביקורת — מיפוי מדד → מקור → סף

| מדד | מקור אמיתי | iOS | Android | סף/סינון |
|------|------------|-----|---------|-----------|
| מהירות נוכחית | `CLLocation.speed` מוחלק | `SessionManager.currentSpeed` | `_currentSpeed` | deadband 1.5 m/s (משימה 5) |
| מקס' מהירות | מהירות מוחלקת | `maxSpeed` | `_maxSpeed` | מתעדכן רק מעל הסף |
| מהירות ממוצעת | ממוצע נקודות ה-GPS | `Session.avgSpeed` | `session.avgSpeed` | מחושב מנקודות מסוננות (<20מ') |
| מרחק | Haversine מצטבר | `runningDistance` (O(1)) | `runningDistance` | דיוק <20מ' |
| נקודות GPS | מונה נקודות הסשן | `gpsPointCount` | `_gpsPointCount` | סשן בלבד |
| דיוק | `horizontalAccuracy` | `lastGPSAccuracy` | `_lastGpsAccuracy` | fix <20מ' מתקבל |
| איכות אות | פונקציה של דיוק | `GPSSignalQuality.from` | `GpsSignalQuality.from` | none/weak/fair/good/strong |
| Airtime / גובה | גלאי IMU+ברומטר | `Jump.airtime/height` | מקביל | confidence + שער מהירות |
| דופק | HealthKit / חיישן | `heartRate` | `_heartRate` | — |
| מצב קפיצה | מכונת מצבים IMU | `jumpDetectionState` | `_jumpState` | — |

**מסקנת הביקורת:** כל הערכים מחוברים למקור אמיתי. אין נתון מסונתז/מזויף. הסינון העיקרי שהיה חסר —
סף-עמידה במהירות — נוסף במשימה 5.

## השינויים שבוצעו במסגרת משימה זו

1. **החלת סף-העמידה** (משימה 5) על המהירות הנוכחית ועל מקס' המהירות — מונע "תפיסת" רעש בעמידה.
2. **סינון דיוק GPS** קיים (`< 20מ'`) אומת בשתי הפלטפורמות (`LocationManager.processLocation` / `onLocationResult`) —
   fix גרוע נדחה לפני שהוא משפיע על מהירות/מרחק.
3. **הפרדת חימום מסשן** (משימה 1): נקודות שמתקבלות בחימום מעדכנות רק את אייקון האיכות, לא את מדדי הסשן
   ולא את חוצץ ההחלקה — כך שהסשן מתחיל "נקי".

## אימות

- מעבר ידני על מסכי `MetricsView`/`GPSRouteView` (iOS) ו-`MetricsPage`/`GpsRoutePage` (Android) — כל כרטיס
  מציג ערך מ-StateFlow/Published אמיתי של `SessionManager`.
- בעמידה: מהירות/מקס' = 0, מרחק יציב, נקודות ממשיכות להצטבר, דיוק מוצג נכון.
- בתנועה: כל הערכים עולים באופן עקבי.

## מסקנות

- אושרה שלמות שרשרת הנתונים: חיישן → `SessionManager` → UI, ללא זיוף.
- מקור ה"זיוף" שנצפה היה רעש GPS בעמידה ללא deadband — טופל במשימה 5 והוחל כאן רוחבית.
- ראו [[task-5-speed-deadband]] ו-[[task-1-gps-prewarm]].
