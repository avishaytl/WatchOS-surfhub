# משימה 2 — הודעת התחברות (הצלחה/כשל) בעליית האפליקציה

## הבעיה

בעליית האפליקציה בוצעה בדיקת התחברות שקטה (iOS: `AuthService.init` בדק pairing ב-Keychain; Android:
נבדקו טוקנים ב-`SettingsStore`). למשתמש **לא הוצגה שום הודעה** האם השעון מחובר בהצלחה או שהחיבור פג —
הוא נותר בלי משוב על מצב החשבון.

## הפתרון

הצגת הודעה חד-פעמית בעליית האפליקציה:
- **הצלחה:** "מחובר כ-<חשבון>" — כשנמצא pairing/טוקן תקף.
- **כשל:** "ההתחברות פגה" — כש-pairing קיים אך אינו תקף יותר (iOS).

ההודעה מוצגת **רק אם היה pairing שמור** — כך התקנה חדשה נשארת שקטה ופשוט מגיעה למסך החיבור.

### iOS

- **`Services/AuthService.swift`** — מבנה חדש `AuthLaunchNotice` (titleKey/messageKey/messageArg) ו-`@Published var launchNotice`.
  ב-`init`: אם `isPaired` ו-`validPairing()` הצליח → notice הצלחה עם תווית החשבון; אחרת → notice כשל.
- **`Views/ContentView.swift`** — `.alert` נוסף הקשור ל-`authService.launchNotice`, עם תמיכה ב-`%@`
  (שם החשבון) דרך `String(format:)`.
- **מחרוזות** (`en.lproj`/`he.lproj`): `account.connected_title`, `account.connected_message`,
  `account.connect_failed_title`, `account.connect_failed_message`.

### Android

- **`session/SessionManager.kt`** — ל-`SessionUserNotice` נוסף שדה אופציונלי `messageArg: String?`.
  פונקציה `emitLaunchAuthNotice()` נקראת ב-`init`: אם הטוקנים קיימים → `_sessionNotice` של הצלחה עם תווית החשבון.
- **`ui/SPOTEQApp.kt`** — ה-`SessionNoticePrompt` משתמש ב-`context.getString(messageRes, messageArg)` כשיש arg.
- **מחרוזות** (`values`/`values-iw`): `account_connected_*`, `account_connect_failed_*` (עם `%s`).

## הבדל בין-פלטפורמי (מתועד במכוון)

ב-iOS קיימת בדיקת תוקף זולה (`validPairing()`), ולכן מוצג גם מסלול **כשל** בעלייה. ב-Android תוקף הטוקן
נבדק רק בזמן העלאה (refresh), ולכן בעלייה מוצגת הודעת **הצלחה** בלבד; מצב כשל מתגלה וצף בעת ההעלאה
(ראו [[task-7-upload-notice]]). המחרוזות לכשל הוגדרו בשתי הפלטפורמות לשימוש עתידי.

## אימות

1. שעון מחובר → פתיחת האפליקציה מציגה "מחובר כ-<מייל>".
2. התקנה חדשה / לא מחובר → אין הודעה, מגיעים ישר למסך החיבור.
3. iOS עם pairing שפג → הודעת "ההתחברות פגה".

## מסקנות

- המשתמש מקבל ודאות מיידית על מצב החשבון בכל פתיחה.
- נוצל מנגנון ה-notice הקיים (`sessionNotice` / `SessionUserNotice`) במקום בניית מנגנון חדש.
- הרחבת `SessionUserNotice` ב-`messageArg` שימושית גם לעתיד (הודעות עם פרמטרים).
