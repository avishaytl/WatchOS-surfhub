# תיקוני Kiters — מדריך תיעוד (יוני 2026)

מסמך אב לסדרת 8 תיקונים שבוצעו מקצה-לקצה בשתי הפלטפורמות (iOS/watchOS ו-Android Wear),
תוך שמירה על זהות התנהגות בין הגרסאות. כל תיקון מתועד בקובץ נפרד: בעיה → פתרון → קבצים שהשתנו → מסקנות.

| # | משימה | קובץ |
|---|--------|------|
| 1 | הפעלת GPS בעלייה (חימום) + אייקון GPS במסך הבית | [task-1-gps-prewarm.he.md](task-1-gps-prewarm.he.md) |
| 2 | הודעת התחברות (הצלחה/כשל) בעליית האפליקציה | [task-2-login-notice.he.md](task-2-login-notice.he.md) |
| 3 | חיווט המשוב ההפטי (מישוש) + אימות נעילת מים | [task-3-haptics-waterlock.he.md](task-3-haptics-waterlock.he.md) |
| 4 | ניקוי מסך ההגדרות (הודעות קוליות, זריקת שעון, Standard) | [task-4-settings-cleanup.he.md](task-4-settings-cleanup.he.md) |
| 5 | כיול מהירות + סף תזוזה מינימלי (מניעת ריצוד בעמידה) | [task-5-speed-deadband.he.md](task-5-speed-deadband.he.md) |
| 6 | אימות כל חיישני הסשן מקצה-לקצה | [task-6-sensor-audit.he.md](task-6-sensor-audit.he.md) |
| 7 | הודעת הצלחת/כשל העלאת סשן לענן | [task-7-upload-notice.he.md](task-7-upload-notice.he.md) |
| 8 | אימות פורמט הלוגים (בינארי חסכוני) | [task-8-log-format.he.md](task-8-log-format.he.md) |

## עקרונות מנחים

- **זהות בין פלטפורמות:** כל שינוי לוגי בוצע גם ב-Swift (`Kiters/Kiters Watch App/`) וגם ב-Kotlin (`android/wear/src/main/`).
- **לוקליזציה:** כל מחרוזת חדשה נוספה באנגלית ובעברית (`en.lproj`/`he.lproj` ב-iOS, `values`/`values-iw` ב-Android).
- **סוללה:** חימום ה-GPS פעיל רק כשמסך הבית בחזית ונעצר ברקע.

## אימות

- **Android:** `:wear:compileDebugKotlin` עבר בהצלחה (JBR 21).
- **iOS:** סקירה ידנית של כל השינויים (Xcode מלא לא זמין בסביבה; רק Command Line Tools). אין שגיאות תחביר/הפניות חסרות שזוהו.
