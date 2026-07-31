# V15 vs Surfr Session Analysis

תאריך ניתוח: 27.7.2026  
לוג: `log_20260727_144243_F3386A6C.kslog`  
מנוע בזמן ההקלטה: `v15-clean` בגרסת השעון שהקליטה את הסשן  
רפרנס: צילום Surfr `WhatsApp Image 2026-07-27 at 16.49.21.jpeg`  
שינויי אלגוריתם שבוצעו במסגרת ניתוח זה: **אין**

## 1. Executive Summary

המסקנה המרכזית היא שהלוג **לא חסר IMU**. הוא מכיל 420,368 דגימות לאורך
2,107.328 שניות, בקצב אפקטיבי 199.48Hz, ללא timestamp לא-מונוטוני וללא פער
IMU מעל 55ms אחרי שניית האתחול. כל עשר קפיצות Surfr שהזמן שלהן גלוי בתמונה
נמצאות בתוך טווח הלוג.

היישור הקודם, שבו Surfr #9 הותאמה לתוצאה ב־`+295.971s`, היה שגוי. היישור
הנתמך על ידי רצף הזמנים הוא:

`log elapsed = Surfr elapsed - 122.467s`

הראיה החזקה היא רצף Surfr #4–#6: המרווחים הם 46 ו־52 שניות, מול רצף התוצאות
של V15 ב־348.356, 395.286, 446.533 שניות, שהמרווחים בו 46.930 ו־51.247
שניות. ה־offset החציוני של השלישייה הוא `-122.467s`. אימות בלתי תלוי מתקבל
מכך ש־V15 פתח candidates לקפיצות #9 ו־#10 בסטיות של 0.404 ו־0.264 שנייה
בלבד. אין עדות ל־timestamp drift.

בגרסת V15 שרצה על השעון:

- Surfr מציג 14 קפיצות; עשר הראשונות כוללות זמן/גובה/airtime מדויקים בתמונה.
- V15 פלט 33 קפיצות לאורך הלוג.
- עד Surfr #10, V15 פלט 19 קפיצות.
- שלוש קפיצות הן strict matches בתוך ±3s: #4, #5, #6.
- #8 קשורה סיבתית לאותה קפיצה, אבל ה־takeoff שלה הוזז ב־3.162s אל אזור
  הנחיתה ולכן אינה strict match.
- שש קפיצות נוספות (#1, #2, #3, #7, #9, #10) הוחמצו ברמת התוצאה הסופית.
- מתוך ארבע הקפיצות הקשורות סיבתית, רק #6 נמצאת ביעד הגובה ±0.30m.

הכשל הראשי אינו סף GPS יחיד ואינו איבוד דגימות. הוא שילוב של:

1. `single-flight ownership`: false flight מוקדם תופס את ה־state machine,
   וקפיצה אמיתית שמתרחשת בתוכו אינה מקבלת מעטפת עצמאית.
2. נחיתות רכות אינן מזוהות. candidates נכונים ב־#9/#10 נשארים פתוחים
   22–30 שניות עד impact אקראי או `maxFlightExceeded`.
3. `retriggerGuard` חסם ישירות את #7.
4. גרסת השעון עדיין השתמשה ב־GPS בשערי החלטה. הדבר דחה rescues ב־#1
   ואת המעטפת המקורית של #8.
5. לא היה ערוץ גובה אבסולוטי שמיש באף אחת מעשר הקפיצות. #1–#8 הגיעו עם
   accuracy של כ־23.2m ונזרקו; ב־#9/#10 הערך היה קפוא בדיוק על 2.073m.
6. ערוץ ה־relative היה רציף אך איטי, 0.390Hz. בקפיצה קצרה הוא מספק בדרך כלל
   1–2 נקודות בלבד ולכן אינו מספיק ל־apex fit אמין.

בקוד הנוכחי GPS כבר metrics-only, ואימות GPS/no-GPS נותן אותן תוצאות פיזיקליות
(זמן, גובה, airtime; רק distance נעלם ללא GPS). אין להציע שוב “להסיר GPS”:
השינוי כבר בוצע. עם זאת, replay של הקוד הנוכחי ללא GPS מפיק רק 11 תוצאות
בכל הלוג ואינו נותן strict match לאף אחת מעשר הקפיצות הגלויות. לכן הסרת
GPS לבדה אינה פותרת את בעיית ה־state machine.

לא ניתן לחשב Precision/Recall מלאים לכל 14 הקפיצות בלי הזמנים המדויקים של
#11–#14. התמונה מציגה את ארבעת הברים שלהם אך לא את שורות הזמן/airtime/distance.
אין בדוח זמני קפיצה מומצאים.

## 2. Previous Analysis Review

נקרא `V15_1_SPEC_HE.pdf`, המסכם את מחזור V15.1 מ־21–22.7, וכן
`V15_FIX_SPEC_HE.pdf`. השיפורים שכבר קיימים בתכן ואין להציעם מחדש הם:

- freeze detector משולב ל־absolute altitude.
- `noRiseAbort` שמתעלם מערוץ disturbed.
- `reanchor` אחרי flight שגוי שנוחת על impulse חזק.
- קיבוץ ניסיונות rescue למקסימות מקומיות והגבלת מספרם.
- `lastEmittedLandingT` במקום חסימה לפי כל נחיתה שנדחתה.
- הגדלת yank lookback.
- Bayesian airtime prior ומודל גובה עם rotation integral.
- הגנות hard-cap ודרישה לראיית לחץ/impact בגובה ballistic.
- GPS כ־metrics-only בקוד הנוכחי.

הדוח הקודם השיג 11/12 על 12 goldens משלושה לוגים, Height MAE של 0.33m
ו־Airtime MAE של 0.35s. הסשן הנוכחי חושף תנאי שלא נפתר על ידי אותו כיול:
ה־absolute unusable כמעט כל הסשן, ה־relative איטי, ורצף false flights
מונע מהקפיצות האמיתיות לקבל ownership.

הנחות העבודה:

- עמודת `Time` של Surfr היא elapsed time מתחילת סשן Surfr, בהתאם למסמך
  הכיול הקיים בריפו.
- Surfr מציג רק קפיצות בגובה 1m ומעלה.
- matching מחמיר הוא `|Δtakeoff| ≤ 3s`, בהתאם למתודולוגיה הקיימת בריפו.
- התאמה “סיבתית” יכולה להיות מסומנת גם כשהמנוע הגיב לאותה קפיצה אבל בנה
  לה מעטפת שגויה. היא אינה נספרת כ־strict match.
- אירועי on-device הם מקור האמת למה שקרה בשעון. replay של source נוכחי
  מנותח בנפרד מפני שהקוד השתנה מאז ההקלטה.

## 3. Session Quality Assessment

### שלמות ורציפות

| מדד | תוצאה |
|---|---:|
| משך header/replay | 2,108.022s |
| דגימת IMU ראשונה/אחרונה | 0.000 / 2,107.328s |
| מספר דגימות | 420,368 |
| קצב אפקטיבי | 199.479Hz |
| median / p99 Δt | 5ms / 5ms |
| max Δt אחרי 2s | 55ms |
| פערים מעל 30ms אחרי 2s | 21 |
| פערים מעל 50ms אחרי 2s | 5 |
| פערים מעל 100ms אחרי 2s | 0 |
| timestamps לא מונוטוניים | 0 |

הפער היחיד מעל 100ms הוא gap אתחול של 541ms סביב השנייה הראשונה. הוא אינו
חופף לגלישה או לקפיצה. אין logger dropout שיכול להסביר את ההחמצות.

### זמן מוחלט וסנכרון

- `wallClockAtT0Ms=1785152563637`, כלומר 14:42:43.637 בשעון ישראל.
- תום הלוג הוא בקירוב 15:17:51.659.
- צילום Surfr אינו מכיל timestamp מוחלט לכל קפיצה או SYNC marker.
- שדה האירועים הראשון ב־CSV המפוענח שלילי ושגוי; זמני ה־boot המוטמעים
  בטקסט האירוע תקינים ושימשו בניתוח.
- רצף #4–#6 וה־candidate times של #9/#10 מוכיחים offset קבוע וללא drift
  נראה לעין עד דקה 22 של Surfr.

המשמעות של offset 122.467s אינה שחסרות קפיצות בתחילת הלוג. Surfr #1 מתרחשת
ב־`+221.533s` של V15, ולכן כל עשר הקפיצות הגלויות נמצאות בתוך הלוג. היא כן
מראה ששני מקורות ה־elapsed לא הופעלו באותה שנייה.

## 4. Sensor Health Analysis

### IMU

IMU הוא הערוץ הבריא בסשן. הקצב יציב, אין drift או dropout משמעותי, ובחלונות
הקפיצה קיימות חתימות load/gyro. לדוגמה:

- #4: peak load 4.94g, 0.24s לפני זמן Surfr המיושר.
- #5: peak load 5.03g, 0.69s אחרי הזמן המיושר.
- #6: peak load 3.38g, 0.05s לפני הזמן המיושר.
- #9/#10 חלשות יותר, אך candidates נפתחו בזמן, ולכן ה־IMU הספיק לזיהוי
  takeoff גם שם.

### Absolute altitude

| מדד | תוצאה |
|---|---:|
| עדכוני מקור | 1,681 |
| קצב מקור | 0.798Hz |
| accuracy לא תקין (≥12m) | 474 |
| accuracy תקין (<12m) | 1,207 |
| עדכון תקין ראשון | 596.022s |
| טווח ערך מלא | ‎-142.804 עד 2.369m |
| datum steps של 5m ומעלה | 11 |

מצב הערוץ חמור:

- עד `596.022s` ה־accuracy הוא כ־23.18–23.26m ולכן המדידות נזרקות.
- מ־596.022 עד 1297.021 הערך קפוא בדיוק על `2.073m` במשך 700.999s.
- מ־1302.021 עד 1543.021 הוא שוב קפוא 241s.
- אחרי חלון תנועה קצר הוא קפוא מ־1558.021 עד 2108.022 עוד 550.001s.
- סך ה־exact holds האלה הוא כ־1,492s. כלומר כמעט כל התקופה שבה accuracy
  נראה “טוב” עדיין אינה מדידת גובה חיה.

זה אינו חוסר callback. callbacks ממשיכים להגיע; **הערך הממוזג קפוא**.
לכן הבעיה רצינית ברמת sensor fusion, אבל לא ברמת שלמות קובץ הלוג.

בכל #1–#8 לא הייתה דגימת absolute מאושרת. ב־#9/#10 היו 6–7 עדכונים עם
accuracy טוב, אך כולם היו בדיוק 2.073m. אין `apexFit` אמיתי באף קפיצה גלויה.

### Relative altitude / pressure

| מדד | תוצאה |
|---|---:|
| עדכוני מקור | 820 |
| קצב | 0.390Hz |
| median / p99 gap | 2.564 / 2.596s |
| max gap | 2.664s |
| טווח | ‎-192.63 עד 10.33m |
| צעדים של 5m ומעלה | 31 |
| צעד מקסימלי | 118.18m |

התזמון של הערוץ רציף מאוד; אין dropout. הבעיה היא cadence נמוך והפרעות מים/
datum. בקפיצה של 2–4 שניות מתקבלות רק 1–2 נקודות in-flight. דרישת שתי
נקודות חיוביות ל־Floor B מוצדקת נגד fits מתפוצצים, אך משמעותה שבסשן הזה
הערוץ אינו יכול להיות מקור הגובה ברוב הקפיצות.

### GPS

GPS היה קיים והמהירות נעה בין 0 ל־11.42m/s. בקובץ samples יש speed, אך אין
מסלול מלא, horizontal accuracy או course גולמי שמאפשרים quality audit מלא.
גרסת השעון השתמשה ב־GPS בהחלטות:

- 177 `gpsSpeedBelowRiding`.
- 50 `gateEntrySpeed`.
- 301 `gateNoJumpEvidence`.

בקוד הנוכחי אין gate שקורא GPS. replay עם GPS ובלעדיו מפיק אותם 11
takeoff/height/airtime values; ההבדל הוא distance בלבד. דרישת המוצר
“אין תלות GPS” מתקיימת בקוד הנוכחי, אך לא התקיימה בגרסה שהקליטה את הסשן.

### State machine ו־debug

| אירוע on-device | כמות |
|---|---:|
| `CANDIDATE` | 186 |
| `CANDIDATE(reanchor)` | 6 |
| `LANDING` | 164 |
| `IMPACT pending` | 96 |
| `IMPACT discarded` | 6 |
| `JUMP FINAL` | 33 |
| `maxFlightExceeded` | 16 |
| `floatBelowMin` | 55 |
| `retriggerGuard` | 81 |

היחס 186 candidates מול 33 finals והמספר הגדול של flights באורך 22–30s
מראים שה־state machine מסגמנט smooth riding כטיסה לעיתים קרובות. כאשר אין
pressure אמין, false flight כזה מקבל ownership ארוך מדי.

## 5. Jump Matching

### הוכחת היישור

| Surfr | זמן Surfr | זמן V15 | offset |
|---|---:|---:|---:|
| #4 | 471.000 | 348.356 | -122.644s |
| #5 | 517.000 | 395.286 | -121.714s |
| #6 | 569.000 | 446.533 | -122.467s |

נבחר offset חציוני `-122.467s`, עם אי־ודאות שמרנית של ±0.8s. אימות:

| Surfr | זמן V15 צפוי | candidate V15 | residual |
|---|---:|---:|---:|
| #9 | 743.533 | 743.937 | +0.404s |
| #10 | 1202.533 | 1202.797 | +0.264s |

ההתאמה אינה מבוססת על גובה, ולכן אינה circular. היא מבוססת על מרווחי זמן
ורצף events.

### טבלת התאמה

`ΔApex*` הוא הפרש midpoint בלבד (`takeoff + airtime/2`). Surfr אינו מציג
apex timestamp, ולכן אין אפשרות לחשב ΔApex אמיתי מן התמונה.

| # | Surfr Height | V15 Height | Δ Height | זוהה? | Δ Takeoff | Δ Apex* | Δ Landing | Root Cause | תיקון מומלץ | השפעה צפויה |
|---:|---:|---:|---:|---|---:|---:|---:|---|---|---|
| 1 | 2.54 | — | — | לא | — | — | landing evidence ‎-0.18s | קפיצה בתוך false flight של 22.29s; rescues נדחו ב־GPS gate | candidates מקבילים + landing hypotheses | הצלת FN בלי GPS |
| 2 | 3.08 | — | — | לא | candidate מאוחר +4.43s | — | — | false flight תפס 30s; פתיחה מחדש אחרי הנחיתה | candidates מקבילים | הצלת FN |
| 3 | 2.14 | — | — | לא strict | flight התחיל ‎-3.99s; echo סופי +9.44s | — | echo מאוחר | נחיתה רכה לא נסגרה; reanchor מאוחר יצר תוצאה אחרת | landing estimator סנסורי | הפרדת הקפיצה מה־echo |
| 4 | 2.73 | 1.76 | -0.97 | כן | -0.177s | -0.697s | -1.217s | נחיתה 1.22s מוקדם; אין pressure fit | תיקון landing segmentation לפני height | שחזור airtime/height |
| 5 | 3.93 | 1.61 | -2.32 | כן | +0.753s | -0.072s | -0.897s | impact מוקדם סגר לפני נקודת relative שנייה; ballistic בלבד | landing hypotheses + שמירת arc | פוטנציאל השיפור הגדול ביותר בגובה |
| 6 | 1.84 | 1.61 | -0.23 | כן | 0.000s | +0.085s | +0.170s | segmentation תקין; ballistic fallback | לשמר כרגרסיה | כבר בתוך ±0.30m |
| 7 | 1.05 | — | — | לא | — | — | — | `retriggerGuard` חסם openings בזמן הקפיצה | collect תמיד, dedupe רק ב־finalize | הצלת back-to-back jump |
| 8 | 1.42 | 1.79 | +0.37 | causal בלבד | +3.162s | +3.617s | +4.072s | המעטפת המקורית נדחתה `vin=4.96<5`; reanchor על אזור הנחיתה + soft 5s | GPS כבר הוסר; נדרש segmentation | זמן נכון וגובה קרוב יותר |
| 9 | 1.31 | — | — | לא | candidate +0.404s | — | — | takeoff נמצא; נחיתה רכה לא נמצאה; flight נמשך 30s | landing estimator + bounded hypothesis | הצלת FN מוכח |
| 10 | 2.00 | — | — | לא | candidate +0.264s | — | — | takeoff נמצא; relative rise מנע abort אך לא היה return; flight נמשך 22.45s | landing estimator; relative כראיה חלשה | הצלת FN מוכח |

## 6. Jump-by-Jump Investigation

### #1 — Surfr 5:44, V15 expected 221.533s

- מנוע V15 כבר היה ב־flight שהתחיל ב־199.937s.
- impact נרשם ב־222.578s ונחיתה ב־224.574s.
- נחיתת Surfr הצפויה היא 224.753s: residual של ‎-0.179s. כלומר ראיית
  הנחיתה קיימת בזמן הנכון.
- המעטפת הראשית הייתה 22.29s, יצרה `hBal=90.25m` ונדחתה ב־hard cap.
- rescues נבדקו, אך `gateNoJumpEvidence` דחה אותם עם course change
  20.45°–23.24°, drop סביב 0.98 ו־yank עד 1.76g.
- absolute כולו accuracy≈23.21m; relative נע בכ־0.86m בחלון הרחב.

מסקנה: זו FN בגלל ownership מוקדם ושער GPS, לא בגלל חוסר IMU. replay הקוד
הנוכחי ללא GPS עדיין אינו פולט אותה: הוא דוחה מעטפה קרובה ב־
`ballisticWithoutBaroLanding`, ואחר כך פולט אירוע לא קשור ב־234.279s.

### #2 — Surfr 6:29, V15 expected 266.533s

- false flight התחיל ב־241.957s.
- הוא נשאר פתוח עד `maxFlightExceeded` ב־272.571s.
- זמן הנחיתה הצפוי הוא 270.793s, בתוך המעטפה השגויה.
- candidate הבא עוגן ב־270.967s, אחרי הקפיצה, נסגר soft ב־276.575s
  ונדחה ב־`gateNoJumpEvidence`.
- relative עלה בכ־2.35m בחלון הרחב, אך לא סיפק return/landing אמין.
- absolute accuracy≈23.22m ונזרק.

מסקנה: הקפיצה נבלעה במלואה בתוך false flight. הסף הבעייתי אינו takeoff
בודד; המנוע לא מאפשר hypothesis חדש בזמן שכבר קיים flight.

### #3 — Surfr 6:49, V15 expected 286.533s

- candidate קיים עוגן ב־282.547s, כ־3.99s מוקדם.
- לא נמצאה נחיתה סביב 289.253s.
- flight נסגר רק ב־298.567s, 13.43s אחרי העוגן.
- ה־finalize/rescue נדחו ב־GPS/float.
- impact של 3.99g יצר reanchor ב־295.971s, ותוצאה של 1.67m/2.32s.
- התוצאה המאוחרת אינה strict match: takeoff שלה +9.438s מהזמן הצפוי,
  וה־landing שלה מתרחש אחרי חלון הקפיצה של Surfr.

מסקנה: זוהה אירוע מאוחר שקשור לשרשרת, אך הקפיצה עצמה הוחמצה בגלל
landing segmentation. אין pressure height: absolute invalid ו־relative range רק 0.32m.

### #4 — Surfr 7:51, V15 expected 348.533s

- false flight קודם נחת על impulse של 4.39g.
- `reanchor` פתח ב־348.356s: residual ‎-0.177s.
- V15 נחת ב־351.096s, 1.217s לפני נחיתת Surfr הצפויה.
- airtime 2.74s מול 3.78s.
- הגובה 1.76m מול 2.73m.
- absolute invalid. נקודות relative הופיעו ב־+0.47s וב־+3.04s ביחס
  ל־Surfr; השנייה כבר מחוץ ל־landing המוקדם של V15.

מסקנה: reanchor תפס את ה־takeoff, אך impact מוקדם נבחר כנחיתה והוציא את
נקודת הלחץ השנייה מה־arc. מכאן המעבר ל־ballistic והטיית הגובה מטה.

### #5 — Surfr 8:37, V15 expected 394.533s

- reanchor ב־395.286s, residual +0.753s, yank 5.48g.
- landing ב־398.286s, 0.897s לפני נחיתת Surfr הצפויה.
- airtime 3.00s מול 4.65s; height 1.61m מול 3.93m.
- relative עלה בכ־1.52m בחלון. נקודת העלייה המאוחרת, שיכלה להשלים
  Floor B, הגיעה אחרי ה־landing שבחר המנוע.
- כל absolute samples נזרקו עם accuracy≈23.24m.

מסקנה: שגיאת הגובה היא תוצאה ישירה של חלון טיסה קצר מדי ושל העדר fit,
לא baseline barומטרי שגוי. עם airtime של Surfr, הנוסחה הבליסטית המקורית
עם `floatFactor=2.6` נותנת בקירוב 3.92m, כמעט גובה Surfr. אין הצדקה לכייל
את scale לפני שמתקנים את זמן הנחיתה.

### #6 — Surfr 9:29, V15 expected 446.533s

- reanchor בדיוק ב־446.533s.
- landing ב־449.073s מול 448.903s צפוי.
- airtime error +0.17s.
- height 1.61m מול 1.84m: error ‎-0.23m, בתוך היעד.
- גם כאן אין pressure fit, אבל segmentation טוב וה־ballistic fallback סביר.

מסקנה: זו דוגמת הרגרסיה החיובית. תיקון state machine חייב לשמר אותה.

### #7 — Surfr 9:51, V15 expected 468.533s

- V15 פלט קודם אירוע ב־459.638–463.948s שאינו קפיצת Surfr #7.
- בין 467.573 ל־473.573 נרשמו שוב ושוב `REJECT(open) reason=retriggerGuard`.
- חלון Surfr #7 נמצא במרכז החסימה.
- candidate הבא נפתח רק אחרי 474.5s.
- peak load בחלון הוא כ־1.43g; אין impulse של 4g שיכול להפעיל reanchor.

מסקנה: FN ישירה של guard. ההגנה מפני echo מבוצעת מוקדם מדי, בשלב איסוף
ה־candidate, ולכן היא מוחקת מידע על קפיצה אמיתית סמוכה.

### #8 — Surfr 10:50, V15 expected 527.533s

- מעטפה מוקדמת התחילה סביב 522.107s.
- היא נסגרה ב־532.577s על 3.69g.
- המועמד העיקרי נדחה ב־`gateEntrySpeed vin=4.96`, ארבע מאיות מתחת לסף 5.
- לאחר מכן reanchor ב־530.695s, קרוב לאזור הנחיתה ולא ל־takeoff.
- soft close ב־535.695s יצר 1.79m/5.00s, confidence 35.
- מול Surfr: Δtakeoff +3.162s, Δlanding +4.072s, Δheight +0.37m.

מסקנה: זו אותה שרשרת פיזית ולכן causal match, אבל segmentation שגוי. הסרת
GPS כבר בוצעה; replay נוכחי ללא GPS עדיין אינו פולט את הקפיצה, מפני שהמעטפה
נדחית בהמשך על דרישות corroboration. לכן אין לסמן את הבעיה כ“GPS בלבד”.

### #9 — Surfr 14:26, V15 expected 743.533s

- candidate נפתח ב־743.937s: residual +0.404s.
- אין final.
- flight נשאר פתוח עד `maxFlightExceeded` ב־774.572s.
- תוצאת V15 ב־736.074s קדמה לקפיצה ואינה #9.
- absolute מסר עדכונים עם accuracy טוב אך כולם 2.073m.
- relative: נקודה ב־+0.38s היא ‎-8.66m, והנקודה הבאה ב־+2.95s
  כבר אחרי נחיתת Surfr הצפויה. אין return שניתן למדוד בזמן.

מסקנה: takeoff נתפס כמעט בדיוק. הכשל היחיד שמונע final של הקפיצה הוא
זיהוי נחיתה רכה/סיום hypothesis.

### #10 — Surfr 22:05, V15 expected 1202.533s

- candidate נפתח ב־1202.797s: residual +0.264s.
- relative עלה בכ־1.45m בתוך החלון ולכן `noRiseAbort` לא סגר את ה־flight.
- אין impact או pressure return סביב נחיתת Surfr הצפויה 1205.963s.
- ה־flight נמשך עד impact אקראי ב־1225.573s: 22.45s.
- `hBal=84.27m` נדחה ב־hard cap; rescues נדחו גם ב־`gateEntrySpeed`.
- reanchor מאוחר יצר תוצאה ב־1226.915s, שאינה הקפיצה המקורית.
- absolute קפוא 2.073m בכל החלון.

מסקנה: candidate מדויק הפך ל־FN בגלל נחיתה רכה. relative rise יחיד משמש
כיום להוכחת “לא לבצע abort”, אך אותו ערוץ איטי מכדי לספק return. זה יוצר
מצב חד־כיווני שמאריך false flight.

## 7. False Positives

עד זמן Surfr #10 יש 19 תוצאות V15 וארבע התאמות סיבתיות. 15 התוצאות הבאות
אינן מקבילות לשורת Surfr באותו interval:

| זמן V15 | זמן בציר Surfr | Height | Airtime | Confidence |
|---:|---:|---:|---:|---:|
| 183.591 | 5:06.06 | 1.68 | 2.95 | 50 |
| 234.346 | 5:56.81 | 1.70 | 2.31 | 50 |
| 295.971 | 6:58.44 | 1.67 | 2.32 | 50 |
| 459.638 | 9:42.11 | 1.65 | 4.31 | 50 |
| 515.743 | 10:38.21 | 1.41 | 1.21 | 50 |
| 566.090 | 11:28.56 | 1.60 | 5.07 | 50 |
| 666.549 | 13:09.02 | 1.89 | 2.70 | 50 |
| 736.074 | 14:18.54 | 1.52 | 2.28 | 50 |
| 799.185 | 15:21.65 | 2.55 | 3.18 | 50 |
| 863.331 | 16:25.80 | 2.10 | 2.66 | 50 |
| 932.280 | 17:34.75 | 1.96 | 2.20 | 50 |
| 940.350 | 17:42.82 | 2.03 | 3.03 | 50 |
| 1018.343 | 19:00.81 | 2.05 | 1.93 | 50 |
| 1066.194 | 19:48.66 | 1.77 | 5.91 | 50 |
| 1130.465 | 20:52.93 | 1.61 | 2.34 | 50 |

כולן `ballistic`, עם `hFit=-1`, `hRel=-1` ו־`arcPts=0`. לכן הלוג אינו
יכול להוכיח אם כל אחת היא:

- false flight מלא;
- קפיצה אמיתית מתחת ל־1m ש־Surfr מסתיר אך V15 העריך גבוה מדי;
- קפיצה נוספת ש־Surfr עצמו לא זיהה.

בהתאם לכלל “לא לנחש”, הן מסווגות כ־**Surfr-negative V15 outputs** ולא כ־FP
פיזיקלי מוכח. מבחינת יעד המוצר “להציג אותו מספר כמו Surfr”, הן apparent
false positives: V15 הציג אותן בגובה 1.41–2.55m ולכן המשתמש רואה עוד קפיצות.

## 8. False Negatives

במיפוי הסיבתי יש שש FNs מתוך עשר השורות הגלויות:

| # | השלב שבו אבדה | ראיה |
|---:|---|---|
| 1 | flight ownership + rescue gate | landing נמצא בסטייה ‎-0.18s; rescues נדחו `gateNoJumpEvidence` |
| 2 | flight ownership | false flight של 30s מכסה את חלון הקפיצה |
| 3 | landing | אין סגירה בזמן; echo נפלט +9.44s |
| 7 | open gate | `retriggerGuard` פעיל בכל חלון הקפיצה |
| 9 | landing | candidate +0.404s; `maxFlightExceeded` אחרי 30s |
| 10 | landing | candidate +0.264s; impact אקראי אחרי 22.45s |

ב־strict matching גם #8 היא FN, משום שה־takeoff המדווח שלה חורג מעט מ־3s
ומייצג למעשה reanchor באזור הנחיתה.

## 9. Height Accuracy Analysis

עבור ארבע ההתאמות הסיבתיות:

| מדד | תוצאה |
|---|---:|
| Mean absolute height error | 0.973m |
| Median absolute height error | 0.670m |
| Maximum absolute height error | 2.320m |
| בתוך ±0.30m | 1/4 |
| Mean absolute airtime error | 0.943s |
| Median absolute airtime error | 0.975s |
| Maximum absolute airtime error | 1.650s |

שגיאות הגובה הן `[-0.97, -2.32, -0.23, +0.37]m`. אין כאן apex barometric
שגוי; **אין apex barometric בכלל**. כל 33 התוצאות on-device השתמשו
ב־ballistic fallback. ב־#4/#5 שגיאת הנחיתה קיצרה את airtime והטתה את הגובה
מטה. ב־#8 המעטפת כולה הוזזה לאחר ה־takeoff.

אסור לכייל height coefficients על ארבעת המספרים האלה לפני תיקון segmentation.
הקלט של מודל הגובה — airtime/rotation window — כבר שגוי.

## 10. Root Cause Analysis

### RC1 — State monopoly

ה־state machine מחזיק `Phase.airborne` יחיד. smooth planing שעובר
`pop→quiet` יכול לפתוח flight שגוי. עד שהוא נסגר, pops אמיתיים אינם מקבלים
hypothesis עצמאי. זה מוכח ב־#1, #2, #3, #9 ו־#10.

### RC2 — נחיתה רכה ללא observability מספקת

ב־#9/#10 takeoff נמצא בדיוק, אבל אין impact/pressure-return בזמן. ה־relative
מגיע כל 2.56s וה־absolute אינו חי. מנגנון הנחיתה מחכה עד 22–30s. זהו הכשל
הישיר הגדול ביותר ב־Recall ובגובה.

### RC3 — Guard שמוחק evidence

`retriggerGuard` פועל בזמן פתיחת candidate. ב־#7 הוא חוסם את חלון הקפיצה
עצמו. suppression של duplicate צריך להתבצע לאחר שאוספים evidence, לא על
עצם הזכות לבנות candidate.

### RC4 — GPS בגרסה ההיסטורית

גרסת השעון השתמשה ב־GPS בשערי open/finalize/rescue. #1 ו־#8 מכילות דחיות
ישירות שלו. זה מנוגד לדרישת המוצר הנוכחית. הקוד הנוכחי כבר מתקן זאת ומוכח
GPS-invariant; אין צורך בשינוי נוסף כאן.

### RC5 — Absolute altitude לא שמיש

הערוץ אינו חסר, אלא invalid ולאחר מכן frozen. הוא אינו תורם baseline, apex
או height. זה מסביר מדוע כל התוצאות ballistic ומדוע confidence לא משקף
דיוק height אמיתי.

### RC6 — Replay/source provenance

השעון פלט 33 תוצאות; replay של source נוכחי ללא GPS פולט 11. header בשם
`v15-clean` אינו כולל git SHA/config hash, ולכן אינו מאפשר לשחזר בדיוק את
הבינארי שרץ בשטח. זה אינו root cause של קפיצה, אבל הוא root cause של קושי
באימות ובמניעת רגרסיה.

## 11. Recommended Algorithm Changes

אלו המלצות בלבד; הן לא יושמו במסגרת הניתוח.

### 1. Multi-hypothesis candidate segmentation

1. שינוי: לאסוף pop candidates גם כאשר `phase == airborne`, ולשמור מספר
   קטן ומוגבל של hypotheses מקבילים. לבחור מעטפה רק אחרי שקיימת ראיית
   landing/משך פיזיקלי.
2. קובץ: `Kiters/Kiters Watch App/Services/JumpEngineV15.swift`.
3. מודולים: `tryOpenFlight`, `airborneIMU`, `rescueFoldedJump`, `Phase`.
4. למה: false flight לא יקבל בלעדיות ל־30s.
5. קפיצות: #1, #2, #3, #9, #10.
6. סיכון: candidates נוספים, CPU וזיכרון.
7. סיכון FP: כן, אם כל hypothesis נפלט. לכן יש לבצע selection/dedup לפני emit.
8. replay: לדרוש hypothesis עם t0 בתוך ±1s ב־#9/#10, ולוודא שאין תוספת
   outputs בקטעי החוף/רכיבה.

### 2. Sensor-only soft-landing hypothesis

1. שינוי: לכל candidate ליצור כמה הצעות landing — impact, שינוי quiet,
   pressure descent/return, ו־bounded low-jump duration prior — ולדרג אותן
   בדיעבד. ה־prior שכבר קיים לחישוב height לא צריך להפוך לטיימר שפולט לבד;
   הוא רק מגביל/מדרג hypotheses עם ראיית IMU.
2. קובץ: `JumpEngineV15.swift`.
3. מודולים: `airborneIMU`, `landingWaitIMU`, `confirmLanding`, `finalize`.
4. למה: #9/#10 מוכיחות takeoff מדויק ונחיתה חסרה; #4/#5 מוכיחות landing מוקדם.
5. קפיצות: #3, #4, #5, #8, #9, #10.
6. סיכון: smooth planing נראה quiet ועלול לקבל landing מלאכותי.
7. סיכון FP: גבוה אם prior לבדו מאשר. נדרש score רב־ראיות ומינימום evidence.
8. replay: להשוות Δlanding ו־Δairtime לכל goldens, לא רק count.

### 3. להעביר retrigger suppression לשלב final selection

1. שינוי: לא לחסום candidate ב־`tryOpenFlight` רק מפני שהוא בתוך 5s
   מ־landing קודם. לאסוף אותו, ואז לדחות רק אם המעטפות חופפות/דומות ומוכח
   שזה echo.
2. קובץ: `JumpEngineV15.swift`.
3. מודולים: `tryOpenFlight`, `softEcho guard`, emitter/deduper.
4. למה: #7 נחסמה ישירות למרות שהיא Surfr jump אמיתית.
5. קפיצות: #7.
6. סיכון: duplicate של אותה נחיתה.
7. סיכון FP: בינוני; נדרש interval-overlap dedupe.
8. replay: #7 חייבת להופיע, וכל echoes קיימים חייבים להישאר suppressed.

### 4. להפוך relative rise לראיה חלשה ולא ל־one-way flight latch

1. שינוי: נקודת relative יחידה או rise ללא descent לא תמנע abort עד 30s.
   היא תעלה score של hypothesis אך לא תוכיח לבדה שה־flight עדיין פעיל.
2. קובץ: `JumpEngineV15.swift`.
3. מודולים: `flightAbortNoRiseSec`, pressure routing, hypothesis scorer.
4. למה: ב־#10 rise של 1.45m מנע abort, אך cadence 0.39Hz לא סיפק return.
5. קפיצות: #2, #9, #10.
6. סיכון: קפיצת big-air עם pressure חלקי עלולה להיסגר מוקדם.
7. סיכון FP: נמוך; סיכון FN קיים אם עושים hard abort במקום דירוג.
8. replay: לבדוק גם big-air logs, לא רק הסשן הנוכחי.

### 5. לתקן segmentation לפני כיול height

1. שינוי: אין לשנות כרגע `floatFactor`, rotation slope או airtime prior.
   תחילה לתקן t0/landing; לאחר מכן לחשב מחדש residuals.
2. קובץ עתידי: `JumpEngineV15.swift`, רק לאחר שלב 1–4.
3. מודול: height floors.
4. למה: #5 עוברת מ־1.61m לכ־3.92m בנוסחת floatFactor המקורית אם משתמשים
   ב־airtime הנכון 4.65s. scale אינו הבעיה הראשונה.
5. קפיצות: #4/#5 בעיקר.
6. סיכון: כיול מוקדם ייצור overfit ויפגע בלוגים הקודמים.
7. סיכון FP: שינוי height יכול להפוך sub-1m ל־visible output.
8. replay: לכייל רק אחרי strict detection parity על כמה sessions.

### 6. Sensor recovery experiment, לא gate חדש

1. שינוי ניסויי: לאחר absolute invalid/frozen ממושך, למדוד אם controlled
   reacquisition של ספק ה־absolute מחזיר ערך חי בלי לפגוע ב־IMU/relative.
2. קבצים: `MotionManager.swift`, `JumpDetectorV15.swift`.
3. מודול: lifecycle של absolute altitude.
4. למה: הערוץ frozen/invalid כמעט כל הסשן.
5. קפיצות: פוטנציאלית כולן.
6. סיכון: restart יכול ליצור datum step, gap או תחרות consumer.
7. סיכון FP: אם הערך הראשון אחרי restart נכנס ל־arc ללא quarantine.
8. אימות: בדיקת שעון פיזית; replay לבדו אינו יכול להוכיח recovery.

### 7. Versioned forensic header

1. שינוי: לרשום `algorithmRevision`, git SHA, config hash וכל ערכי V15Config
   ב־KSLG header.
2. קבצים: `SessionLogger.swift`, `JumpDetectorV15.swift`.
3. מודול: session metadata.
4. למה: 33 live outputs מול 11 current replay אינם ניתנים לשחזור חד־משמעי
   מהשם `v15-clean`.
5. קפיצות: כל ניתוח עתידי.
6. סיכון: זניח, metadata בלבד.
7. סיכון FP: אין.
8. אימות: replay צריך לסרב לטעון config לא תואם או להציג אזהרה מפורשת.

## 12. Expected Impact of Each Change

| עדיפות | שינוי | השפעה צפויה המבוססת על הלוג |
|---:|---|---|
| P0 | Multi-hypothesis segmentation | מאפשר ל־#1/#2/#3/#9/#10 לקבל מעטפה גם בתוך false flight |
| P0 | Soft-landing hypotheses | סוגר candidates המדויקים של #9/#10 ומתקן את landing של #4/#5 |
| P1 | Late retrigger dedupe | מציל ישירות את #7 |
| P1 | Relative כראיה חלשה | מונע latch של 22–30s ב־#2/#10 |
| P2 | Sensor recovery experiment | עשוי להחזיר Floor A, אך אינו מובטח מהלוג |
| P2 | Versioned header | מבטל ambiguity בין live/replay ומונע RCA על בינארי לא ידוע |

אין התחייבות מספרית ל־14/14 לפני replay. ה־upper bound התיאורטי מהקפיצות
הגלויות הוא ששלושת שינויי ה־state machine נוגעים בכל שש ה־FNs, אך כל recovery
חייב לעבור FP regression.

## 13. Risks

- multi-hypothesis יכול להכפיל events אם selection חלש.
- soft-landing prior יכול להפוך smooth riding לקפיצה אם הוא משמש ראיה יחידה.
- הסרת guard מוקדם יכולה להחזיר echoes.
- relative altitude מכיל 31 datum steps ומים; אין להשתמש בנקודה יחידה כגובה.
- controlled restart של absolute עלול להחמיר את הבעיה או ליצור consumer
  competition.
- כיול גובה על ארבע התאמות בלבד יהיה overfit.
- Surfr censored מתחת 1m; Precision “מול התצוגה” אינו Precision פיזיקלי מלא.
- ללא שורות #11–#14 אפשר בטעות לשייך להן outputs מאוחרים. הדוח נמנע מכך.

## 14. Validation Plan

1. להשלים ground truth: צילום/ייצוא של שורות Surfr #11–#14 עם time, height,
   airtime ו־distance.
2. בסשן הבא לבצע SYNC שנרשם בשני המכשירים, או לצלם את שני שעוני ה־elapsed
   באותו פריים. offset יחיד חייב להיות מתועד ולא מוסק.
3. להקפיא revision/config ולשמור אותם ב־header.
4. להריץ baseline replay של הקוד הנוכחי ללא GPS ולשמור:
   TP/FN/Surfr-negative outputs, Δtakeoff, Δlanding, Δairtime, Δheight.
5. להוסיף את #1–#10 כ־golden windows. #9/#10 חייבות לשמור candidate residual
   מתחת 1s ולהשיג landing בתוך ±0.5s–1s.
6. ליישם כל שינוי מאחורי flag ולהריץ ablation:
   multi-hypothesis בלבד, landing scorer בלבד, dedupe בלבד, ואז שילובים.
7. להריץ רגרסיה על שלושת הלוגים ו־12 ה־goldens של V15.1, ועל negative
   beach/smooth-riding segments.
8. יעד detection: כל 14 קפיצות Surfr, strict ±3s, ללא visible extras.
9. יעד height: MAE ≤0.30m ו־max error מדווח בנפרד; לא להסתפק בממוצע.
10. להריץ GPS invariance: GPS/no-GPS חייבים להפיק בדיוק אותם IDs, takeoff,
    landing, height, airtime ו־confidence. distance בלבד רשאי להשתנות.
11. לבצע בדיקת שעון פיזית ל־absolute recovery; replay אינו תחליף.

## 15. Final Conclusions

1. הלוג הקליט את כל ה־IMU הרלוונטי. אין data gap שמסביר את ההחמצות.
2. ה־offset הנכון הוא בקירוב `-122.467s`, לא `-570.033s`.
3. כל עשר הקפיצות הגלויות נמצאות בלוג; #9/#10 אף קיבלו candidates מדויקים.
4. V15 נכשל בעיקר בסגירת נחיתות רכות ובכך ש־false flight יחיד תופס ownership.
5. #7 מוכיחה שה־retrigger guard הנוכחי יכול למחוק קפיצה אמיתית.
6. GPS היה root cause בגרסת השטח, אך כבר הוסר מהחלטות בקוד הנוכחי.
7. ה־absolute altitude היה unusable בכל הקפיצות הגלויות; callbacks קיימים,
   אבל תחילה accuracy גרוע ואחר כך ערך קפוא.
8. כל 33 גבהי השעון היו ballistic. לכן סטיית הגובה אינה שגיאת apex fit;
   היא בעיקר שגיאת segmentation/airtime.
9. אין לכייל height thresholds או coefficients לפני שמתקנים את גבולות הטיסה.
10. נדרשים נתוני #11–#14 כדי לפרסם מדדי session מלאים ואמינים.

### מדדים שניתן לפרסם כעת

| מדד | on-device, visible prefix |
|---|---:|
| Surfr labels עם זמן מדויק | 10 |
| V15 outputs עד #10 | 19 |
| strict TP (±3s) | 3 |
| causal matches | 4 |
| strict recall | 30.0% |
| causal recall | 40.0% |
| apparent strict precision | 15.8% |
| apparent causal precision | 21.1% |
| causal FN | 6 |
| Surfr-negative outputs | 15 |
| Height MAE על causal matches | 0.973m |
| Median absolute height error | 0.670m |
| Maximum absolute height error | 2.320m |

`apparent precision` הוא יחס מול הקפיצות ש־Surfr מציג. הוא אינו קובע שכל
output נוסף הוא קפיצה פיזיקלית שקרית, מפני ש־Surfr מסתיר קפיצות מתחת 1m
ול־V15 לא היה גובה לחץ שמאפשר להכריע.
