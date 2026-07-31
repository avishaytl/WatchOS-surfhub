# לוג חישובים מובנה — מנוע 13

מנוע 13 כותב Audit מלא מתחילת סשן ועד סופו לתוך קובץ ה־`.kslog` הרגיל. לכן אין קובץ צדדי שיכול ללכת לאיבוד: כש־`SessionManager` מעלה את לוג הסשן דרך `CloudSyncService.uploadLog`, גם רשומות החישוב עולות איתו.

## רצף הרשומות

1. `schema` — מילון פרמטרים עם יחידה, נוסחה והסבר בעברית.
2. `configuration` — כל ערכי התצורה האפקטיביים של מנוע 13 בסשן.
3. `adapter` — קליטת absolute altitude, בדיקות accuracy/re-anchor, סינון timestamp או held value, בחירת מקור ואיפוס datum.
4. `takeoff` — warm-up, חלון המראה, מספר דגימות baseline, רעש baseline, עלייה בחלון ועלייה מעל baseline.
5. `apex` ו־`landing` — גובה מקסימלי, קצב אנכי, ירידה מהשיא, חזרה ל־baseline וחלון נחיתה יציב.
6. `motionMetrics` ו־`gpsMetrics` — תאוצה, סיבוב, impact, מהירויות ומרחק. אלה מדדים בלבד ואינם חוסמים זיהוי ב־V13.
7. `validation` — זמן אוויר, freshness, מספר דגימות, קשת פיזיקלית, drift וסף הגובה הסופי.
8. `result` — קפיצה שהתקבלה, סיבת דחייה או מניעת כפילות.
9. `pipelineHealth` — כל 5 שניות: קצב מקור ועיבוד IMU/Relative/Absolute/מים, gaps, השהיית תור Absolute, עומק תור המנוע ועומק תור הכתיבה.

אם `CMBatchedSensorManager` אינו מוסר אף batch במשך 3 שניות, ה-watchdog מתעד `imuCallbackGap` ואירוע `IMU stream recovery`, ועובר אוטומטית ל-`CMMotionManager` בלי להפסיק את הסשן.
10. `summary` — ספירת רשומות, החלטות וסיבות, משך הסשן ומספר הקפיצות שדווחו.

לכל רשומה יש `sessionID`, מספר `sequence` רציף, זמן monotonic, שלב, פעולה, החלטה, ערכים, תנאים ו־`candidateID` כאשר קיים מועמד פעיל. בכל תנאי:

- `passed: true` — התנאי עבר.
- `passed: false` — התנאי נכשל.
- `passed: null` — עדיין אי אפשר היה לחשב אותו מפני שחסר prerequisite מוקדם יותר.

## פורמט KSLG

רשומת Audit היא tag מספר `12` ב־KSLG v2:

```text
UInt8 tag = 12
UInt64 relativeMonotonicTimeUs
UInt32 jsonPayloadLength
UTF-8 JSON (V13AuditRecord schemaVersion=1)
```

ה־JSON מאפשר להוסיף בעתיד ערכים או תנאים בלי לשבור לוגים ישנים. `JumpReplay.Loader` מדלג ומפענח את הרשומות, ו־preview של `SessionLogger` מציג sequence, שלב, פעולה, החלטה, candidate, סיבה, גובה וזמן אוויר.

לייצוא כל שרשרת החישוב לקובץ JSON קריא:

```bash
swift run -c release JumpReplay --dump-v13-audit audit.json session.kslog
```

## ביצועים

הזרמים הגולמיים נשארים ברשומות הבינאריות הקומפקטיות הקיימות. IMU מובנה נכתב רק בזמן candidate פעיל וב־4Hz; החישוב עצמו וזרם ה־IMU הבינארי נשארים בקצב המלא. דגימות IMU נשלחות ל־SessionLogger בבאצ׳ במקום ליצור פעולת Dispatch חדשה לכל דגימה. קידוד JSON וכתיבה לקובץ מתבצעים בתור ה־I/O של `SessionLogger`, ולא בתור החיישנים או המנוע.

במסך Settings של V13 ניתן לבחור מרווח עיבוד Absolute של `0.25`, `0.5`, `0.75` או `1.0` שניות. זהו קצב העיבוד המרבי: `CMAltimeter` אינו מספק API לקביעת קצב החומרה, ולכן אם watchOS מוסר דגימות לאט יותר המערכת אינה ממציאה דגימות ביניים. הלוג הבינארי שומר כל callback גולמי, ו־`pipelineHealth` מציג בנפרד `absoluteAltitudeSourceHz` מול `absoluteAltitudeProcessedHz`.
