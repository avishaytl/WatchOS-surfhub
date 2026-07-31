# Early-Finalize Gate — FINAL מדויק ב-≤5s לקפיצות מוכחות-נקיות

**סטטוס:** ממומש ב-`jumpEngine.ts` + `jumpScanV9.ts`, כבוי בברירת מחדל (legacy זהה).
**הפעלה:** `earlyFinalizeSec: 4` בקונפיג ה-scanner — **רק אחרי ריצה על ה-goldens.**

---

## 1. העיקרון האינפורמטיבי

ה-settle של 16s קונה דבר אחד ויחיד: **את ה-drift נטו על פני הקשת** (baseline סימטרי
מבטל drift לינארי; חלון חתוך סופג אותו). מכאן: קפיצה שאפשר *להוכיח* שאין בה drift
לא צריכה עתיד — המדידה הנוכחית שלה כבר יציבה, וה-FINAL יכול להיסגר ב-≤5s.

הוכחת-ההיעדר היא AND של **ארבעה תנאים בלתי-תלויים**, כולם זמינים ≤5s אחרי נחיתה,
וכולם מחושבים במנוע על כל קפיצה (diagnostics זולים):

| # | תנאי | שדה | מה מוכיח |
|---|---|---|---|
| 1 | \|return-to-zero\| ≤ `rtzToleranceHpa` (0.06) | `returnToZeroHpa` | ה-drift נטו **נמדד** ≈ 0: נקודות ה-on-water שאחרי הנחיתה חוזרות ל-baseline של לפני ההמראה |
| 2 | \|Theil-Sen slope\| ≤ `driftSlopeMaxHpaPerSec` (0.01) | `pastDriftSlopeHpaS` | אין drift פעיל בכניסה (LOG2 #8: ‎0.043 — פי 4 מעל הקו) |
| 3 | `specForceQuieting` < `quietingCleanMax` (0.9) | קיים | הייתה ריחוף נתמך אמיתי (נקיות 0.55–0.76 מול drift ‏1.1–1.8) |
| 4 | `landingTimedOut === false` | חדש | הברומטר חזר ל-0 — שלילת הסימפטום המתועד של drift |

**בטיחות פילוסופית:** כשל בהוכחה רק **דוחה** את ה-FINAL ל-settleSec — לעולם לא
מפיל קפיצה. זה ההבדל המהותי מ-`requireCrossValidation` (המלכודת המתועדת): שם
סיגנל חסר דחה קפיצות; כאן הוא עולה 11 שניות.

## 2. תוצאות הולידציה הסינתטית (verify.ts — 19/19 ✅)

שוחזר תרחיש LOG2 #8 (drift‏ 0.5 hPa / 12s מתחת לקפיצה) + קפיצה נקייה באותו session:

- **קפיצת ה-drift:** מזוהה (לא נזרקת), `rtz = −0.486` **נמדד**, נכשלת ב-gate,
  מקבלת FINAL בנתיב הבטוח — latency ‏16.2s.
- **הקפיצה הנקייה:** `rtz = +0.005`, עוברת את כל הארבעה, FINAL ב-**5.5s** עם גובה
  **זהה ספרה-לספרה ל-whole-log** (2.94 = 2.94).
- **ברירת מחדל (דגל כבוי):** אפס פליטות early — התנהגות legacy זהה לחלוטין.

צפי מוצרי (לפי התפלגות LOG2, ‏10/11 נקיות): **~90% מהקפיצות ב-≤5–6s ברמת הדיוק
של ה-FINAL; ~10% ב-16s עם `driftSuspect`.**

## 3. תיקון ½ΔB האנדפוינטי — ממצא כן

מומש (`endpointDriftMaxHpa`, כבוי; deadband ‏0.03 hPa + clamp) אך הבדיקות חשפו
שני גבולות אמיתיים: (א) ב-drift מהיר המים לא מזוהים (`landingTimedOut`) ⇒ אין rtz
⇒ אין תיקון — אבל אז ה-gate ממילא מנתב ל-settle; (ב) ב-0.36Hz תת-הדגימה מתקזזת
אקראית עם ניפוח ה-drift, ותיקון "נכון" יכול להרע — **בדיוק ה-entanglement שתועד
ב-DRIFT_CORRECTION_RESEARCH.** ב-1Hz הוא ולידי ואינרטי-בבטחה (corr=0 כשלא צריך).
**כלל מוצר: להשאיר כבוי ב-0.34Hz; לשקול הפעלה רק עם ברומטר ≥1Hz.**
ה-**gate** הוא ה-deliverable המרכזי — לא המתקן.

## 4. אינטגרציה

```ts
// scanner (עם ולידציית goldens מאחוריך):
const scanner = new JumpScannerV9(DEFAULT_JUMP_PARAMS, {
  ...DEFAULT_SCAN_CONFIG,
  earlyFinalizeSec: 4,   // FINAL מוקדם לקפיצות cleanNoDrift
});
// HUD: emission.early === true ⇒ FINAL מוקדם (אותו id, אותו חוזה תצוגה).
```

שדות חדשים ב-`JumpResult` (מחושבים תמיד): `returnToZeroHpa`, `pastDriftSlopeHpaS`,
`landingTimedOut`, `cleanNoDrift`, `endpointDriftCorrM`.

## 5. צעדי ולידציה לפני הפעלה בשטח

1. `validate_v9` על LOG2/LOG3/Hoolan עם ברירת המחדל — חייב להישאר זהה (הדגל כבוי;
   רק שדות diagnostics נוספו).
2. ריצה עם `earlyFinalizeSec: 4` על LOG2: לוודא ש-#8 **לא** early ושה-early-heights
   של הנקיות ≈ ה-finals (צפי: ‎RMS ≈ ה-provisional ‏0.211 או טוב ממנו, כי early
   דורש cleanNoDrift בעוד provisional נפלט לכולן).
3. כיול ספים על הדאטה האמיתי אם צריך: `rtzToleranceHpa` (רעש ה-rtz בנקיות),
   `quietingCleanMax` (המרווח 0.76→1.1 רחב — 0.9 באמצע).
4. פורט ל-Swift line-for-line (הבלוקים: rtz, Theil-Sen, cleanNoDrift, early branch).
