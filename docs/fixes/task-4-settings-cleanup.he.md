# משימה 4 — ניקוי מסך ההגדרות

## הבעיה

מסך ההגדרות הציג שלושה פריטים מיותרים/מבלבלים:
1. **הודעות קוליות** (`voiceAnnouncements`) — toggle ללא מימוש פונקציונלי בשום מקום.
2. **זריקת שעון / Toss Test** (`devMode`) — מצב פיתוח שדילג על דרישת מהירות ה-GPS; לא רלוונטי למשתמש קצה.
3. **כרטיס בחירת מצב זיהוי "Standard"** + תצוגת ספים — בחירה מדומה, שכן יש בפועל **נוסחה אחת בלבד**.

## הפתרון

הסרת שלושת הפריטים מה-UI בשתי הפלטפורמות, תוך **שמירת הלוגיקה הפנימית**: `detectionMode` נשאר
ברירת מחדל `standard` (ה-enum והלוגיקה לא נמחקו), ומיגרציית `custom → standard` נשמרה.

### iOS — `Views/SettingsView.swift`

- הוסר כל מקטע "Jump Detection" (כרטיס Standard + תצוגת הספים) וה-toggle של "Toss Test".
- הוסר ה-toggle "Voice Announcements".
- ניקוי נגזר: הוסרו `@AppStorage("voiceAnnouncements")`, המאפיין המחושב `detectionMode`, והעוזרים
  `modeColor(_:)` ו-`thresholdBadge(...)` שהפכו ללא-בשימוש.
- נשמרה מיגרציית `onAppear` (`detectionModeRaw == custom → standard`).

### Android

- **`ui/screens/SettingsScreen.kt`** — הוסר מקטע זיהוי הקפיצות (כרטיס + ספים), פריט ה-Toss Test,
  ופריט ה-Voice Announcements. הוסר ה-import המיותר `JumpDetectionConfig`.
- **`storage/SettingsStore.kt`** — הוסר המאפיין `voiceAnnouncements` (לא נצרך עוד).

## הערה על מחרוזות

מפתחות הלוקליזציה היתומים (`settings.voice_announcements`, `settings.dev_mode`, `settings.jump_detection`,
מפתחות הספים) הושארו בקבצי המחרוזות — הם בלתי-מזיקים, מצומצמים, ומפנים אליהם רק קוד שהוסר. ניתן לנקותם
בעתיד אם רוצים, אך אין בכך צורך פונקציונלי.

## אימות

1. מסך ההגדרות אינו מציג עוד "הודעות קוליות", "זריקת שעון/Toss Test", או כרטיס "Standard".
2. זיהוי הקפיצות ממשיך לעבוד עם נוסחת ברירת המחדל (`standard`).
3. ערך `detectionMode=custom` ישן ממוּגר אוטומטית ל-`standard`.

## מסקנות

- מסך ההגדרות נקי וברור יותר, ללא בחירות מדומות או כלי פיתוח חשופים למשתמש.
- הלוגיקה נשמרה — רק שכבת ה-UF הוסרה — כך שאין רגרסיה בזיהוי הקפיצות.

## עדכון (החזרת Toss Test)

ה-toggle של **Toss Test (devMode)** **הוחזר** למסך ההגדרות בשתי הפלטפורמות לבקשת המשתמש —
הוא נחוץ לבדיקה בזריקת השעון (סימולציית קפיצה ללא רכיבה אמיתית). בנוסף, מנוע V7 החדש החמיר את
הספים (`minAirTimeSec=2.0`, `minJumpHeightMeters=1.5`), ולכן devMode כעת גם **מרכך את ספי המנוע**
כדי שזריקה קצרה ונמוכה תיתפס: ב-`buildSession` (iOS `JumpDetector.swift`, Android `engine/JumpDetector.kt`)
כש-devMode פעיל מוגדרים `releaseFloorG=1.30`, `minAirTimeSec=0.25`, `hardLandingMinAirTimeSec=0.25`,
`minJumpHeightMeters=0.20`, `landingContactGyro=0.8`, `landingSpikeGyro=0.5`, וסף הביטחון יורד ל-0.20.
שער מהירות ה-GPS כבר עוקף ב-devMode. ראו [[task-3-haptics-waterlock]].

(הודעות קוליות נותרו מוסרות; רק Toss Test הוחזר.)
