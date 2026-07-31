# ניתוח V13 - לוג אחרון 2026-07-11 18:30

## הלוג

- קובץ: `log_20260711_183053_DDD90570.kslog`
- הועלה לענן: `2026-07-11T15:32:05.252Z` (18:32:05 שעון ישראל)
- משך: 66.9 שניות
- מנוע: `v13-pure`
- מצב לוג: `sensorOnly=true`
- רשומות: 13,144 motion, 201 absolute-altitude, 25 baro, 0 GPS, 39 events

## מה קרה בשעון

בלוג המקורי לא מכיל אף `JUMP(v13) FINAL`.
הוא מכיל 39 אירועים, מתוכם:

- `notRiding speed=-1.00`: 3 דחיות
- `noisyBaseline`: 31 דחיות
- `sensorWarmup`: דחייה אחת
- `endSession flush lateJumps=0`

שורש הכשל המקורי בלוג הזה: אין אף רשומת GPS, ולכן `gpsPoint(near:)` החזיר `nil`.
ברירת המחדל הקודמת של V13 דרשה `minGpsSpeedMS = 3.0`, ולכן candidate אמיתי נפל על:

```text
v13 REJECT(candidate) reason=notRiding speed=-1.00
```

## הסיגנל שכן רואים בלוג

חלון הגובה סביב הקפיצה:

```text
  9.901s  absAlt=6.694m
 10.902s  absAlt=8.225m
 11.902s  absAlt=7.436m
 12.898s  absAlt=6.535m
 17.902s  absAlt=6.845m
```

כלומר יש rise של כ-1.5m מעל baseline שקט. באותו חלון יש גם IMU חזק:

- 10.3-11.2s: max accel כ-6.04g, max vertG כ-6.17g
- 10.8-17.95s: max accel כ-32.24g, max rot כ-30.67rad/s

## למה replay הטעה

`JumpReplay` מכניס `MockGPS(speed=8.0m/s)` כאשר אין speed בלוג, אלא אם מריצים `--no-gps`.

לפני התיקון:

- replay רגיל: קפיצה אחת, כי mock GPS עקף את המחסום
- replay עם `--no-gps`: 0 קפיצות, כמו השעון

אחרי התיקון הסופי:

- replay עם `--no-gps`: קפיצה אחת, `t=9.80s`, `air=8.10s`, `h=1.42m`, `dist=0.0m`

## תיקון

V13 עכשיו נשען לזיהוי על absolute altitude בלבד:

- אין fallback ל־relative altitude או pressure.
- אין gate של GPS.
- אין gate של IMU.
- baseline הוא ממוצע absolute altitude בחלון של 4 שניות לפני תחילת העלייה.
- height מחושב כ־`apex absolute altitude - pre-jump baseline average`.
- absolute altitude עם `accuracy` גרוע מדי נפסל כ־quality gate של אותו ערוץ ברומטרי.

נוספה בדיקת E2E:

```text
v13 accepts a barometer-only jump without GPS or IMU spike
```

שער הרגרסיה עבר:

- לוג 2026-07-11 12:56 ללא קפיצות: נשאר 0
- לוג חיובי 2026-07-07: נשאר 1
