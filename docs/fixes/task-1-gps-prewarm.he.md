# משימה 1 — הפעלת GPS בעלייה (חימום) + אייקון GPS במסך הבית

## הבעיה

ה-GPS הופעל **רק** בתחילת סשן (`startSession()` → `locationManager.startTracking()`). תוצאות:
1. בתחילת כל סשן המשתמש המתין שניות ארוכות (10–30ש') עד שה-GPS משיג fix טוב — הנקודות הראשונות לא מדויקות.
2. מסך הבית לא הציג שום חיווי GPS; אייקון איכות האות הופיע רק בתוך סשן פעיל (`GPSTrackerIndicator` / `GpsStatCard`).

## הפתרון

הוספת מנגנון **חימום GPS (prewarm)** שמתחיל לקבל עדכוני מיקום כבר כשמסך הבית בחזית, ומציג אייקון
סטטוס GPS חי במסך הבית — זהה לזה שבסשן פעיל. החימום **נעצר אוטומטית כשהאפליקציה עוברת לרקע**
כדי לא לנקז סוללה (החלטת המשתמש: חימום במסך הבית בלבד).

הפרדה נקייה בין "בעלות" על ה-GPS: סשן פעיל מחזיק את ה-GPS ולכן עזיבת מסך הבית/מעבר לרקע **אינם**
יכולים לעצור סשן רץ.

### iOS

- **`Services/LocationManager.swift`** — הוספת `prewarm()` ו-`stopPrewarm()` ודגל `isPrewarming`.
  - `prewarm()` מפעיל `startUpdatingLocation()` רק אם כבר יש הרשאה (לא מבקש הרשאה — זו עדיין פעולה
    מכוונת של "התחל סשן") ורק אם אין כבר tracking.
  - `stopPrewarm()` עוצר עדכונים רק אם **אין** סשן בבעלות (`wantsToTrack == false`).
  - `startTracking()` מאפס `isPrewarming` כי הסשן נעשה הבעלים של ה-GPS.
- **`Services/SessionManager.swift`** — `prewarmGPS()` / `stopGPSPrewarm()` (no-op כשמקליטים).
  - ב-`handleGPSPoint` עודכן: `gpsSignalQuality` / `isGPSActive` / `lastGPSAccuracy` מתעדכנים **תמיד**
    (לפני בדיקת הסשן), כך שמסך הבית מציג איכות גם ללא סשן. עבודת הסשן (מהירות/מרחק/נקודות/גלאי קפיצות)
    נשמרת מאחורי `guard isRecording` — כדי לא לזהם את חוצץ ההחלקה ולא להזין את הגלאי לשווא.
- **`Views/HomeView.swift`** — שורת סטטוס GPS בראש המסך עם שימוש חוזר ברכיב הקיים `GPSTrackerIndicator`,
  טקסט איכות מתורגם (`gpsStatusText`), ודיוק במטרים. חיווט מחזור-חיים: `onAppear → prewarmGPS()`,
  `onDisappear → stopGPSPrewarm()`, ו-`onChange(scenePhase)` (active מפעיל, background/inactive עוצר).

### Android

- **`sensors/LocationManager.kt`** — `prewarm()` / `stopPrewarm()` + דגלים `isPrewarming` ו-`sessionOwned`.
  `startTracking()` מסמן `sessionOwned=true`; `stopPrewarm()` לא יעצור כל עוד הסשן בבעלות.
- **`session/SessionManager.kt`** — `prewarmGps()` / `stopGpsPrewarm()`; ב-`handleGpsPoint` איכות האות
  מתעדכנת ללא תנאי לפני ה-`guard` של הסשן.
- **`ui/screens/HomeScreen.kt`** — שורת סטטוס GPS (נקודה צבועה לפי `gpsSignalColor` + טקסט מתורגם + דיוק),
  וחיווט `LifecycleResumeEffect { prewarmGps(); onPauseOrDispose { stopGpsPrewarm() } }`.

## אימות

1. פתיחת האפליקציה במסך הבית → אייקון ה-GPS מתעדכן מ"אין אות" (אדום) ל"טוב/חזק" (ירוק) תוך ~10–30ש'.
2. מעבר לרקע → העדכונים נעצרים (לוג `📍 GPS prewarm stopped`); חזרה לחזית → מתחדש.
3. התחלת סשן בזמן חימום → אין כפילות; הסשן ממשיך לקבל נקודות ללא הפרעה.
4. עזיבת מסך הבית לכניסה לסשן → `stopGPSPrewarm` אינו עוצר את ה-GPS של הסשן.

## מסקנות

- **חוויה:** המשתמש רואה שיש לו fix טוב **לפני** התחלת הסשן, והסשן מתחיל עם נתוני מיקום מדויקים מהרגע הראשון.
- **בטיחות סוללה:** ההפרדה foreground/background מבטיחה שאין מעקב GPS מתמשך כשלא צריך.
- **שימוש חוזר:** נוצל הרכיב הקיים `GPSTrackerIndicator` (iOS) ו-`gpsSignalColor` (Android) במקום קוד חדש.
- ראו גם [[task-5-speed-deadband]] ו-[[task-6-sensor-audit]] שמשלימים את אמינות נתוני ה-GPS.
