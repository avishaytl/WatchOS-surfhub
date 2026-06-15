# משימה 5 — כיול מהירות + סף תזוזה מינימלי (מניעת ריצוד בעמידה)

## הבעיה

בצילום המסך שסיפק המשתמש (שעון מונח, ללא תנועה) הוצגו **מהירות 3.9 קמ"ש** ו**מקס' מהירות 3.9 קמ"ש** —
ערכים מזויפים שנובעים מרעש GPS בעמידה. שורש הבעיה: ה-UI הציג את `CLLocation.speed` **הגולמי**:
- iOS: `SessionManager.swift` — `self.currentSpeed = point.speed`, `self.maxSpeed = max(self.maxSpeed, point.speed)`.
- Android: `SessionManager.kt` — `_currentSpeed.value = point.speed`, `_maxSpeed.value = maxOf(..., point.speed)`.

החלקת המהירות (`speedSmoothingBuffer`, חלון 5) קיימת — אך הוזנה **רק לגלאי הקפיצות**, לא לתצוגה.

## הפתרון

הזנת ה-UI מהמהירות ה**מוחלקת** (שימוש חוזר בחוצץ ההחלקה הקיים) + **סף-עמידה (deadband)**:
מתחת ל-`1.5 m/s` (≈ 5.4 קמ"ש) המהירות הנוכחית נכפית ל-0, ו**מקס' המהירות אינו מתקדם**. ערך זה נמוך
בהרבה מכל מהירות גלישת-קייט אמיתית, ולכן תנועה אמיתית לעולם אינה נחתכת, בעוד רעש בעמידה נחסם.

בנוסף, מקס' המהירות מתעדכן מ**המהירות המוחלקת** (ולא מקפיצת fix בודדת), כך שספייק GPS חד-פעמי אינו מנפח אותו.

### iOS — `Services/SessionManager.swift`

- קבוע חדש `stationarySpeedThreshold = 1.5` (מתועד בקוד).
- ב-`handleGPSPoint`:
  ```swift
  let displaySpeed = smoothedSpeed >= self.stationarySpeedThreshold ? smoothedSpeed : 0
  self.currentSpeed = displaySpeed
  if displaySpeed > 0 { self.maxSpeed = max(self.maxSpeed, smoothedSpeed) }
  ```

### Android — `session/SessionManager.kt`

- קבוע מקביל `stationarySpeedThreshold = 1.5`.
- אותה לוגיקה: `displaySpeed` עם deadband, ו-`_maxSpeed` מתקדם רק מעל הסף ובערך מוחלק.

## בחירת הסף

- דיוק GPS כבר מסונן ל-`< 20מ'` ב-LocationManager, כך שספיד גולמי סביר.
- החלון של 5 דגימות מחליק תנודות ±1–3 m/s.
- 1.5 m/s נבחר כתקרה בטוחה: רכיבה אמיתית בקייט היא 20–40 קמ"ש — הרבה מעל הסף; עמידה היא 0–1 m/s — מתחת לסף.
- הסף עקבי בכוונה עם מושגי `minSpeed` / `stationarySpeed` של גלאי הקפיצות.

## אימות

1. הנחת השעון בעמידה → מהירות נוכחית **0**, מקס' מהירות **0** (במקום 3.9).
2. תנועה אמיתית → הערכים עולים באופן חלק; ספייקים בודדים אינם מנפחים את המקס'.
3. השוואת iOS↔Android — התנהגות זהה.

## מסקנות

- בוטלה תצוגת המהירות ה"מזויפת" בעמידה — התלונה המרכזית מצילום המסך.
- נוצל חוצץ ההחלקה הקיים במקום הוספת החלקה כפולה.
- ראו [[task-6-sensor-audit]] להחלת אותו עיקרון על שאר מדדי הסשן.
