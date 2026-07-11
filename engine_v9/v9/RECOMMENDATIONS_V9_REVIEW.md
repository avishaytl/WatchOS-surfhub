# Code Review V9 — מסמך המלצות ושינויים

**קבצים שנסקרו:** `jumpEngine.ts` (863 שורות) · `jumpScanV9.ts` (285 שורות) · `ALGORITHM_V9.md`
**קבצים מתוקנים מצורפים:** `jumpEngine.ts` · `jumpScanV9.ts` · `verify.ts` (בדיקות שקילות)

---

## 0. סיכום מנהלים

הקוד במצב טוב מאוד — הארכיטקטורה (סריקה אחורנית על באפר ציקלי, provisional→final,
baro-primary) נכונה ומגובה בכיול אמפירי. נמצאו **2 באגים אמיתיים** (אחד יכול לאבד
קפיצות אמיתיות, אחד יכול לפלוט פנטום ב-flush), **2 סיכוני תפעול** (אינווריאנטים לא
נאכפים, באפר ללא תקרה), ו-**3 שיפורי ביצועים/עמידות**. כל התיקונים **שומרי-התנהגות
בברירת המחדל** — פרמטרים חדשים מאותחלים לערכי legacy, בהתאם לפילוסופיית הפרויקט
("every change must pass validate_v9"). שני שיפורי-דיוק פוטנציאליים נוספו **כבויים**
מאחורי פרמטרים, להפעלה רק אחרי ולידציה על ה-goldens.

**חובה לפני merge: להריץ `validate_v9.ts` על LOG2 / LOG3 / Hoolan.** הבדיקות
המצורפות (`verify.ts`) מוכיחות שקילות מתמטית של ה-baseline החדש ותקינות ה-scanner,
אבל הן לא תחליף ל-goldens.

---

## 1. באגים שתוקנו ישירות

### B1 · HIGH · `jumpEngine.detectJumps` — sep-conflict eager pop מאבד שתי קפיצות

**הקוד הישן:**
```ts
if (s[i]!.t - lastApexT < sepMs) {
  if (out.length && alt[i]! > out[out.length - 1]!.jumpHeightM) out.pop(); else continue;
}
```
כששני apexים נמצאים בתוך `jumpSepSec` והמועמד החדש גבוה יותר, הקפיצה שכבר
**התקבלה** נמחקת (`pop`) **לפני** שהמועמד החדש עבר את שאר השערים (run-up speed,
measured-airtime, confidence...). אם המועמד נכשל בשער מאוחר — **שתי הקפיצות אבדו**.
תרחיש אמיתי: קפיצה תקינה 2.5m, ואחריה bump ברומטרי גבוה יותר בזמן שהרוכב כבר איטי
(נכשל ב-`jumpRunUpSpeed`) → הקפיצה האמיתית נמחקה לחינם. זו הפרה ישירה של עקרון
הפרויקט *"prefer a plausible false positive over a miss"*.

**התיקון:** ה-pop נדחה לנקודת הקבלה — `replaceIdx` מסומן, וה-`splice` מתבצע רק
אחרי שהמועמד עבר את **כל** השערים. בתרחישים תקינים ההתנהגות זהה; רק ה-edge case
מתוקן. מכוסה ב-`verify.ts` TEST 3.

### B2 · MEDIUM · `jumpScanV9.flush` — פליטת FINAL לקפיצות "רקובות"

`scan()` זורק pending שלא זוהה-מחדש במשך `8 s` (ה-baseline המלא דחה אותו —
false positive של קצה חתוך). אבל `flush()` פלט **כל** pending כ-FINAL, כולל
כאלה שנראו לאחרונה לפני 7.9 שניות ושהסריקה הבאה הייתה זורקת. תוצאה: פנטום של
סוף-session בדיוק מהסוג שהארכיטקטורה נבנתה למנוע.

**התיקון:** `flush()` מחיל את אותו כלל `pendingDropGapSec` — pending שלא זוהה
בטרייק האחרון של ה-flush (או בתוך ה-gap) נזרק ולא נפלט. עקבי עם כלל הזריקה של
`scan()` עצמו.

### B3 · HIGH (תפעולי) · `JumpScannerV9` — אינווריאנטים לא נאכפים

המסמך (§1.1) מזהיר במפורש: *"these are not free knobs... Get them wrong and V9
produces phantoms (we did, once: 29 jumps / a 4.6 m phantom)"* — אבל הקוד לא בדק
אותם. מי שמשנה קונפיג ב-Swift בלי לקרוא את המסמך משחזר את התקלה בשקט.

**התיקון:** הקונסטרקטור מוודא:
- `settleSec ≥ baselineHalfWinSec`
- `windowSec ≥ settleSec + 2·baselineHalfWinSec + maxAirTimeSec`
- `provisionalSettleSec ≤ settleSec`

מפר → `console.warn` מפורט (לא exception — session חי לא ייפול). מכוסה ב-TEST 5.

### B4 · MEDIUM (בטיחות) · `addSample` — באפר ללא תקרה

אם ה-Timer הנייטיבי נתקע (throttling של watchOS ברקע, באג ב-shell), `scan()` —
שהוא היחיד שמפנה — לא רץ, וה-buffer גדל בלי גבול (50Hz ≈ 180K דגימות/שעה).
**התיקון:** `maxBufferedSamples` (ברירת מחדל 60,000 ≈ 75s @ 500Hz עם מרווח; שיא
נורמלי ~4K) — חיתוך מהעבר בחריגה. מכוסה ב-TEST 6.

### B5 · LOW · `dropGapMs = 8000` hardcoded → `pendingDropGapSec` בקונפיג

עכשיו מתועד, ניתן לכיול, ומשותף ל-`scan()` ול-`flush()`.

### B6 · PERF · `baroAltitudeSeries` — שני לולאות O(U²) → two-pointer O(U·W)

חישוב ה-baseline וה-garbage clamp סרקו **את כל** נקודות העדכון עבור כל נקודה.
בחלון ה-watch (75s, U≈28) זה זניח, אבל בכלי ה-whole-log (ולידציה, dashboard,
WATCH CALIB) session של 3 שעות = ~15M איטרציות בכל אחת משתי הלולאות. הוחלף
ב-sliding window עם שני מצביעים — **חברות בחלון זהה בדיוק** (הוכח bit-for-bit
ב-TEST 1: maxΔ=0.0 מול המימוש הישן). בנצ'מרק 3 שעות: 457ms סה"כ לכל הפייפליין.

### B7 · MEDIUM · `estimateDtMs` — dt מ-60 הדגימות הראשונות בלבד

לוג שנפתח בקצב warm-up (1Hz לפני שה-50Hz מתייצב — קורה ב-CoreMotion) מקבל dt
שגוי פי 50 **לכל הלוג**, וכל חלונות-הדגימות (`maxAirSamp`, `runUpSamp`, chop,
bar-pull) נשברים. **התיקון:** median של שלוש בדיקות — התחלה, אמצע, סוף (60 זוגות
כ"א). על לוג בקצב אחיד התוצאה **זהה** ל-legacy → ה-goldens לא מושפעים.

### B8 · PERF · `scan()` — no-op מוקדם

טיק בלי דגימות ובלי pendings (פערי דגימה ארוכים; fast-forward ב-replay) חוזר מיד
בלי להריץ את המנוע.

---

## 2. שיפורים ממותגי-פרמטר (ברירת מחדל = legacy, כבויים)

### P1 · `heightPreGateFrac` (ברירת מחדל 1.0 = התנהגות זהה)

היום שער הגובה מוחל על דגימת ה-grid **לפני** עידון הפרבולה. קפיצה אמיתית שה-apex
האמיתי שלה 1.7m אבל הדגימות הדלילות שלה כולן 1.3–1.45m נפסלת לפני שהפרבולה יכלה
לשחזר אותה — פספוס מובנה בקפיצות גבוליות ב-0.34Hz. עם `heightPreGateFrac = 0.85`
ה-pre-gate יורד ל-1.28m, הפרבולה רצה, והשער הסופי (שנוסף בקוד) נאכף על
ה-apex המעודן. **להפעיל רק אחרי ריצה על ה-goldens** — צפוי להוסיף קפיצות גבוליות
אמיתיות ב-LOG3, אבל חובה לוודא שאין עליית פנטומים.

### P2 · `baselineMinPoints` (ברירת מחדל 0 = כבוי)

בקצה המוביל (provisional, שניות אחרי נחיתה) חלון ה-baseline מכיל לפעמים 1–2
נקודות עדכון בלבד — percentile 0.6 על 2 נקודות = **המקסימום** → baseline מנופח →
provisional מנופח. עם `baselineMinPoints = 4`, חלון דל-נקודות נופל ל-median
(שמרני). מומלץ להפעיל אחרי ולידציה של ה-provisional RMS (הצפי: ישפר את ה-0.21m
או ישאיר; לא יכול להזיק ל-FINAL כי שם החלון תמיד מלא).

---

## 3. ממצאים מתועדים — ללא שינוי קוד (החלטה מודעת)

| # | ממצא | המלצה |
|---|---|---|
| D1 | **סחיפת מסמך↔קוד:** `ALGORITHM_V9.md` §6 אומר `tickSec 5`, `dedupTolSec 3`, dedup לפי **apex**; הקוד: `tickSec 2`, `dedupTolSec 1.0`, dedup לפי **arc overlap** (+ שלב provisional שלא מופיע ב-§1.1) | לעדכן את המסמך — הקוד הוא מקור האמת המוצהר. חשוב במיוחד לצוות ה-Swift שמצווה "verify against the TS" |
| D2 | `minAirTimeSec = 2.0` הוא **שער מת**: airtime נגזר מגובה, ו-h ≥ 1.5m ⇒ airtime ≥ 2.63·2·√(2·1.5/g) = **2.91s** > 2 תמיד | להשאיר (לא מזיק) או להסיר בניקוי הבא; לתעד שהשער האפקטיבי הוא `minMeasuredAirSec` |
| D3 | `estLandingMs` (עוגן ה-ripeness) משתמש ב-airtime הנגזר מ-`kiteGlideFactor` הממוצע — קפיצת glide ארוכה במיוחד תבשיל "מוקדם" בכמה שניות | לא קריטי: ה-final ממילא נאכף גם ע"י seenNow + full-baseline. לנטר אם יתווספו לוגי Big Air |
| D4 | תיתכן פליטת FINAL **בלי** provisional קודם (פער טיקים גדול מדלג על שני הספים באותו טיק — שניהם נפלטים באותו סדר, אבל HUD חייב לתמוך ב-final ל-id חדש) | לוודא שה-HUD מטפל ב-final-first (כנראה כבר כן — אותו קוד עדכון לפי id) |
| D5 | זיהוי update-points משווה ערכי baro גולמיים — שני עדכונים אמיתיים עם לחץ **זהה בדיוק** נבלעים לנקודה אחת | inherent ל-forward-fill; יתוקן מאליו כשה-shell יספק דגל is-new-sample (מומלץ ב-`NEXT_LOG_RECORDING_SPEC`) |
| D6 | חיפוש מהירות ל-distance הוא O(n) על כל הדגימות פר קפיצה | זניח בחלון 75s; לתקן רק אם ה-whole-log tools יאיטו |
| D7 | ה-provisional נמדד עם baseline שה-future שלו חתוך בקצה הבאפר — בדיוק ה-"leading-edge truncated baseline" שהמסמך מזהיר מפניו | ממותן ע"י: (א) provisional מסומן כלא-קנוני, (ב) pending שה-baseline המלא דוחה לא מופלט כ-final, (ג) P2 לעיל. אופציה עתידית: ריצה כפולה עם `baselineFutureWinSec` קצר ל-provisional (§8.1) — לא הוספה כדי לא להכפיל עלות CPU בלי ולידציה |

---

## 4. מה הורץ ואומת (verify.ts — כל הבדיקות עוברות)

| בדיקה | תוצאה |
|---|---|
| two-pointer baseline ≡ legacy O(U²), bit-for-bit (כולל garbage clamp) | ✅ maxΔ = 0.0 |
| זיהוי 3/3 קפיצות סינתטיות @ 0.36Hz baro | ✅ |
| דיוק @ 1Hz baro: שגיאות 0.02–0.09m (מאשש את טענת המסמך שהקצב הוא החסם) | ✅ |
| תיקון sep-conflict: הקפיצה שהתקבלה שורדת מועמד-גבוה-שנכשל-בשער | ✅ (לפני התיקון: 0 קפיצות) |
| V9 replay: finals == whole-log; לכל id סדר provisional→final; ripeness ≥ settleSec | ✅ |
| אזהרות אינווריאנטים על קונפיג שבור | ✅ (2 אזהרות) |
| תקרת זיכרון + no-op על טיקים ריקים | ✅ |
| typecheck: `tsc --strict` | ✅ נקי |
| בנצ'מרק whole-log 3 שעות (540K דגימות, ~3.9K update points) | 457ms |

**⚠️ נדרש לפני merge:** `node --experimental-strip-types core/tools/validate_v9.ts`
על LOG2 (RMS ≤ 0.169), LOG3 (0 פנטום ≥ 5m), Hoolan (6 throws). התיקונים תוכננו
לזהות-goldens, אבל B1 עשוי *להוסיף* קפיצה אמיתית שנבלעה — אם ה-count משתנה,
לבדוק ידנית שהתוספת לגיטימית לפני עדכון ה-golden.

---

## 5. צעדים מומלצים הלאה (סדר עדיפות)

1. **להריץ את ה-goldens** ולעשות merge לתיקונים (סעיף 1).
2. **לסנכרן את `ALGORITHM_V9.md`** לקוד (D1) + להוסיף את הפרמטרים החדשים לטבלת §6.
3. **לשקף את התיקונים ל-Swift** (`KitesurfJumpEngineV8/9.swift`) — במיוחד B1–B4;
   המסמך מחייב line-for-line sync.
4. **ניסוי מבוקר:** `baselineMinPoints = 4` על ה-goldens → אם ה-provisional RMS
   משתפר, להפעיל. אחר כך `heightPreGateFrac = 0.85` על LOG3 (קפיצות קטנות).
5. **≥1Hz baro** נשאר ה-unlock האמיתי — הבדיקה הסינתטית כאן שחזרה זאת במדויק
   (0.36Hz: תת-קריאה של עד 1.3m; 1Hz: ±0.09m).
