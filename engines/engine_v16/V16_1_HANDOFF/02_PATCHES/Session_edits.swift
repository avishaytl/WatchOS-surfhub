// V16.1 — שתי העריכות ב-Models/Session.swift
// העתיקו את השורות "אחרי" במקום שורות "לפני".

// ── עריכה א' — תווית התצוגה ──────────────────────────────────────────────
// לפני:
//        case .v16BigAir: return "V16 Big Air (Default)"
// אחרי:
        case .v16BigAir: return "V16.1 Big Air (Default)"

// ── עריכה ב' — התיאור ────────────────────────────────────────────────────
// לפני: מחרוזת שהמליצה על V15 לקפיצות קטנות. נבדק ונמצא שגוי —
//        החלפה ל-V15 בטווח הנמוך מחמירה את ה-MAE מ-0.36 ל-0.47 מ'.
// אחרי:
        case .v16BigAir: return "Big-air first, IMU only — the barometer is not used at all. A pop opens a candidate; a sustained LIFT PLATEAU in world-vertical acceleration confirms it, which admits 0 of 19 pops on a waves-only control session. Height is a fixed-window bounded double integration: 19/23 recall at 0.43 m MAE across three sessions, 2.1-8.5 m. Airtime is measured from where the water arrests the descent — 14/14 at 0.34 s. Jumps at or above 2.5 m are delivered ~0.9-3.9 s after landing; smaller ones wait out the dedup hold. Below ~2.5 m the height is a population estimate, not a measurement — the signal carries no height information there, and substituting V15 there makes it worse, not better (0.36 -> 0.47 m), because V15's low-band output is a near-constant by construction."
