# Jump-Timing Calibration from the Surfr Reference Image
# כיול דיוק-זמנים של זיהוי הקפיצות מול תמונת Surfr

> Single source of truth for calibrating the **V7 jump-detection engine** against a
> professional **Surfr** reference session, using the per-jump **elapsed timestamps**
> visible in the Surfr app screenshot as ground truth.
>
> מסמך מקצה-לקצה לכיול **מנוע זיהוי הקפיצות V7** מול סשן ייחוס של אפליקציית **Surfr**
> המקצועית, באמצעות **זמני הקפיצות (elapsed)** הנראים בצילום המסך של Surfr כאמת-מידה.

Related: [`JUMP_ALGORITHM_V7.md`](../JUMP_ALGORITHM_V7.md) ·
[`docs/session-algorithm-end-to-end-he.md`](session-algorithm-end-to-end-he.md) ·
Swift engine `Kiters/Kiters Watch App/Services/KitesurfJumpEngine.swift` ·
replay tool `Kiters/Tools/JumpReplay` · binary writer
`Kiters/Kiters Watch App/Services/SessionLogger.swift`

---

## 0. TL;DR

We have three artifacts describing **the same ~30-minute kitesurf session**:

1. A **Surfr screenshot** that lists 4 jumps with **height, airtime, distance, and the
   elapsed time of each jump** (e.g. jump 1 at `9:18`).
2. Two of **our raw logs** — `log1.json`, `log2.json`. In this repo root they are current
   upload envelopes with `contentType: text/csv`; future/legacy upload envelopes may carry
   base64 binary `.kslog` content.
3. The **V7 algorithm spec** (`JUMP_ALGORITHM_V7.md`).

**Goal:** decode our logs, find which one is the *same* session as the Surfr image by
**matching the four jump elapsed-times**, then **calibrate V7** so it detects exactly
those 4 jumps at exactly those times, with height/airtime as close as possible to Surfr.

המטרה בעברית: לפענח את הלוגים, לזהות איזה מהם הוא בדיוק הסשן שבתמונת ה-Surfr לפי **התאמת
זמני 4 הקפיצות**, ואז **לכייל את V7** כך שיזהה בדיוק את אותן 4 קפיצות באותם זמנים, עם גובה/airtime
קרובים ככל האפשר ל-Surfr.

---

## 1. The ground truth — Surfr screenshot

File: `WhatsApp Image 2026-06-12 at 23.59.59.jpeg`

Session header: **12 Jun 2026, 12:09 GMT+3**, duration **~30 min**, board **Twintip**.
Session summary: highest jump **3.8 m**, max airtime **4.6 s**, max distance **24 m**,
max speed **38 km/h**, **4 jumps**.

Per-jump table (ordered by `#`, i.e. chronologically). The **Time** column is the
**elapsed time from session start** — this is the key new signal:

| # | Height | Airtime | Distance | **Time (mm:ss elapsed)** | **Time (seconds)** |
|---|--------|---------|----------|--------------------------|--------------------|
| 1 | 3.17 m | 4.59 s  | 7 m      | **9:18**                 | 558 s              |
| 2 | 3.45 m | 4.12 s  | 24 m     | **12:15**                | 735 s              |
| 3 | 3.14 m | 4.37 s  | 10 m     | **15:58**                | 958 s              |
| 4 | 3.77 m | 4.33 s  | 20 m     | **22:13**                | 1333 s             |

These four heights match the `log2` reference table already in
`JUMP_ALGORITHM_V7.md` §2/§8 (`3.77 / 3.45 / 3.17 / 3.14`), which strongly suggests
**`log2` is the Surfr reference session** — but this must be *proven* by the timestamps,
not assumed (see §5).

---

## 2. Reconciling the "unsynced watches" caveat

`JUMP_ALGORITHM_V7.md` §2 states the watches were **unsynced** (Surfr ran on a separate
watch), so *per-jump timing need not align* and calibration was done by **height** alone,
matched by rank.

**This task challenges that.** The Surfr **Time** column gives elapsed-in-session time, so
timing can be compared **relative to session start** (not wall-clock). Two outcomes are
possible, and the analysis must decide which:

- **Synced / same capture** — the four elapsed-times line up (exactly, or under a single
  constant offset). Then timing *is* usable ground truth and we calibrate by **time + height**.
- **Still unsynced** — no log lines up in time. Then we *cannot* match by time; report this
  explicitly and fall back to height-rank calibration (the original V7 method).

Do **not** assume a match — verify it first (§5).

---

## 3. Input format — decoding `log1.json` / `log2.json`

Each `*.json` is a **cloud-upload envelope**, not raw samples. The current root logs use
CSV text directly:

```json
{ "type":"session_log", "filename":"log_....csv", "contentType":"text/csv",
  "content":"# Kiters Sensor Log\n..." }
```

So the current pipeline is: **`content` → CSV parser → samples → jumps**.

Future/legacy logs may use a base64 binary `.kslog` envelope:

```json
{ "type":"session_log", "filename":"...", "contentType":"application/x-kiters-session-log",
  "contentEncoding":"base64", "appVersion":"...", "build":"...", "uploadedAt":"...",
  "content":"<BASE64 of the binary .kslog file>" }
```

For those files the pipeline is: **`content` → base64-decode → binary `.kslog` → parse records → jumps**.

### 3.1 `.kslog` binary layout (little-endian)

Authoritative writer: `SessionLogger.swift` (`makeSampleRecord` / `makeEventRecord`).

**File header (8 bytes + JSON):**

| Bytes | Field | Notes |
|------:|-------|-------|
| 0–3  | Magic `KSLG` | ASCII |
| 4    | Version | `0x01` |
| 5    | Reserved | `0x00` |
| 6–7  | Header length | `UInt16` LE |
| 8…   | JSON header | `{ app, format, version, session, date, mode, devMode, sampleRateHz, parameters{...}, columns[...] }` |

**Sample record — type `0x01`, ≥ 46 bytes:**

| Off | Size | Field | Decode |
|----:|-----:|-------|--------|
| 0  | 1 | type = `1` | |
| 1  | 4 | index | `UInt32` LE |
| 5  | 4 | **t_ms** | `UInt32` LE — **elapsed ms from session start** |
| 9  | 2×11 | ax,ay,az,aM, gx,gy,gz,gM, gvX,gvY,gvZ | each `Int16` LE, value = raw/1000 (g or rad/s) |
| 31 | 4 | baro | `Int32` LE, hPa = raw/100 |
| 35 | 4 | baseBaro | `Int32` LE, hPa = raw/100 |
| 39 | 2 | speed | `UInt16` LE, m/s = raw/100 |
| 41 | 2 | lowGCount | `UInt16` LE |
| 43 | 1 | state | `0`=idle `1`=riding `2`=airborne `3`=cooldown `255`=unknown |
| 44 | 2 | evtLen | `UInt16` LE |
| 46 | n | evt | UTF-8 (e.g. `"JUMP ACCEPTED h=3.77m air=5.9s ..."`) |

**Event record — type `0x02`, ≥ 14 bytes:** `type(1) index(u32) t_ms(u32) speed(u16 ÷100) state(u8) evtLen(u16) evt(UTF-8)`.

Missing sensor values are encoded as `Int16.min` / `Int32.min` — treat as `null`.

### 3.2 Reference decoder (Python)

```python
import json, base64, struct

def load_kslog(path):
    env = json.load(open(path))
    blob = base64.b64decode(env["content"])
    assert blob[:4] == b"KSLG", "bad magic"
    hlen = struct.unpack_from("<H", blob, 6)[0]
    header = json.loads(blob[8:8+hlen])
    i, recs = 8 + hlen, []
    while i < len(blob):
        rtype = blob[i]
        if rtype == 1:   # sample
            index, t_ms = struct.unpack_from("<II", blob, i+1)
            speed = struct.unpack_from("<H", blob, i+39)[0] / 100.0
            state = blob[i+43]
            evtlen = struct.unpack_from("<H", blob, i+44)[0]
            evt = blob[i+46:i+46+evtlen].decode("utf-8", "replace")
            recs.append((t_ms, state, speed, evt))
            i += 46 + evtlen
        elif rtype == 2: # event
            index, t_ms = struct.unpack_from("<II", blob, i+1)
            speed = struct.unpack_from("<H", blob, i+9)[0] / 100.0
            state = blob[i+11]
            evtlen = struct.unpack_from("<H", blob, i+12)[0]
            evt = blob[i+14:i+14+evtlen].decode("utf-8", "replace")
            recs.append((t_ms, state, speed, evt))
            i += 14 + evtlen
        else:
            break
    return header, recs

def jumps(recs):
    out = []
    for t_ms, state, speed, evt in recs:
        if "JUMP ACCEPTED" in evt:
            out.append({"t_s": t_ms/1000.0, "mmss": f"{int(t_ms//60000)}:{int(t_ms//1000)%60:02d}", "evt": evt})
    return out
```

> If the in-log `JUMP ACCEPTED` events are absent or stale, re-run the **current Swift V7
> engine** through `Kiters/Tools/JumpReplay` over the parsed IMU/baro/speed stream to get
> our detected jumps — that is the engine we are actually calibrating.

---

## 4. Methodology / מתודולוגיה

1. **Decode** both logs (§3); sanity-check magic, sample count, total duration ≈ 30 min.
2. **Extract our jumps** per log: elapsed time, height, physical & displayed airtime, distance.
3. **Identify the matching log** (§5) by comparing our jump elapsed-times to Surfr's
   `558 / 735 / 958 / 1333 s`.
4. **Build the alignment table** (§6): per jump → Δt, Δheight, Δairtime, Δdistance.
5. **Classify discrepancies:** timing drift, **false positives** (we detect, Surfr doesn't),
   **false negatives** (Surfr has, we miss).
6. **Calibrate** V7 params (§7) to hit: exactly 4 jumps at the right times (no FP/FN),
   `|Δh| ≤ 0.20 m`, `|Δairtime| ≤ ~0.3 s`. Report before/after metrics.

---

## 5. Match test — which log is the Surfr session?

For each candidate log, align our detected jump times `{ô_k}` to Surfr's `{s_k} = {558,735,958,1333}`:

- Compute the best **single constant offset** `δ` (median of `s_k − ô_nearest`) and the
  residuals `|s_k − (ô + δ)|`.
- **Accept** as the same session if all four jumps pair up with residual **≤ ~3 s** and no
  extra/un-paired detections in between. Prefer `δ ≈ 0` (true same-watch capture); a small
  uniform `δ` still implies the same session with a clock origin offset.
- If **no** candidate satisfies this, declare **unsynced** and fall back to height-rank
  calibration (V7 original method) — and say so explicitly.

Expected (to verify, not assume): **`log2` matches**, `log1` does not (its max is 3.9 m with
a different jump structure per `JUMP_ALGORITHM_V7.md` §8).

---

## 6. Alignment table (fill in from analysis)

| # | Surfr time | Our time | Δt | Surfr h | Our h | Δh | Surfr air | Our air | Δair | Notes |
|---|-----------|----------|----|---------|-------|----|-----------|---------|------|-------|
| 1 | 9:18  | … | … | 3.17 | … | … | 4.59 | … | … | |
| 2 | 12:15 | … | … | 3.45 | … | … | 4.12 | … | … | |
| 3 | 15:58 | … | … | 3.14 | … | … | 4.37 | … | … | |
| 4 | 22:13 | … | … | 3.77 | … | … | 4.33 | … | … | |

Also list any **extra** detections (FP) with their times, and any **missing** Surfr jumps (FN).

---

## 7. Calibration knobs (`DEFAULT_V7_PARAMS`, `JUMP_ALGORITHM_V7.md` §7)

| Symptom | Tune | Direction |
|---------|------|-----------|
| Jump detected late/early (timing drift) | `releaseFloorG`, `landingContactG`/`landingContactGyro`, `landingSpikeG` | tighten/loosen take-off & first-water-contact thresholds |
| False positive (chop/handling read as jump) | `releaseFloorG ↑`, `minAirTimeSec ↑`, gyro floor | raise gates |
| False negative (real jump missed) | `releaseFloorG ↓`, `landingContact*` ↓ | lower gates |
| Height too high/low | `symmetricAscentFraction`, `kinematicCalibration` | scale rise-time model |
| Displayed airtime off vs Surfr | `displayedAirtimeScale` (0.73) | re-fit to Surfr displayed airtime |
| Two jumps merged | landing = **first** water contact (already V7) | verify refractory 1 s |

**Targets:** exactly 4 jumps at `558/735/958/1333 s` (±~3 s, no FP/FN); `|Δh| ≤ 0.20 m`
(dashboard target); `|Δairtime| ≤ ~0.3 s`. Justify every parameter change with before/after
metrics (mean & max `|Δh|`, `|Δt|`, FP/FN counts).

---

## 8. Deliverables / תוצרים

1. **Which log** is the Surfr session (`log1`/`log2`) + the timing-match proof (§5).
2. The completed **alignment table** (§6) with deltas.
3. **Discrepancy list:** timing drift, FP, FN.
4. **Proposed V7 parameter changes** + before/after metrics.
5. (Optional) a calibration report under `docs/` recording the findings and the new tuning.

### 8.1 Implementation report — 15 Jun 2026

Implemented in the watchOS Swift V7 engine and mirrored into the Android/Kotlin V7 port:

- Standard V7 calibration defaults are versioned as `surfr-v7-20260615`.
- Public `Jump.airtime` is now the displayed/Surfr-style airtime; `JumpResult.airTimeSeconds`
  remains the physical detector window and `JumpResult.displayedAirTimeSeconds` carries the
  public value.
- JumpReplay supports current `text/csv` upload envelopes and future base64 `.kslog`
  envelopes, and has `--surfr` to print the screenshot comparison.

Current replay command:

```bash
swift run --package-path Kiters/Tools/JumpReplay JumpReplay --surfr --output /tmp/kiters-surfr log1.json log2.json
```

Results after the calibrated defaults:

| Log | Accepted candidates | Strict Surfr match | Notes |
|---|---:|---|---|
| `log1.json` | 9 | **No** | Nearest timing residuals are large; this is not the Surfr session. |
| `log2.json` | 11 | **No** | Stronger candidate: first Surfr jump aligns at `+0.66s`, but later accepted candidates do not meet the `±3s` target. |

`log2` Surfr comparison from JumpReplay:

| # | Surfr time | Current V7 time | Δt | Surfr h | V7 h | Surfr air | V7 displayed air |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | 558s | 558.66s | +0.66s | 3.17m | 2.25m | 4.59s | 3.46s |
| 2 | 735s | 743.76s | +8.76s | 3.45m | 2.88m | 4.12s | 3.91s |
| 3 | 958s | 981.74s | +23.74s | 3.14m | 3.35m | 4.37s | 4.22s |
| 4 | 1333s | 1624.04s | +291.04s | 3.77m | 3.29m | 4.33s | 1.64s |

Important conclusion: the root logs do **not** currently satisfy the strict timing proof in §5.
`log2` remains the probable Surfr-related capture because it contains the exact first elapsed
timestamp and similar 3-4m candidates, but a generic detector cannot honestly be tuned to emit
exactly the four screenshot rows within `±3s` without adding a reference-session-specific
timestamp filter. That filter was deliberately not added.

---

## 9. Ready-to-use prompt (English)

> **Task: Calibrate the V7 jump-detection algorithm's timing accuracy against a Surfr reference.**
>
> Inputs (repo root unless noted):
> 1. `WhatsApp Image 2026-06-12 at 23.59.59.jpeg` — Surfr app screenshot (ground truth).
>    4 jumps; columns Height / Airtime / Distance / **Time (elapsed)**:
>    `1: 3.17m, 4.59s, 7m, 9:18` · `2: 3.45m, 4.12s, 24m, 12:15` ·
>    `3: 3.14m, 4.37s, 10m, 15:58` · `4: 3.77m, 4.33s, 20m, 22:13`.
>    Session: 12 Jun 2026 12:09 GMT+3, ~30 min, Twintip.
> 2. `log2.json` and `log1.json` — our raw logs. Each is a cloud envelope; the repo-root
>    files currently carry `text/csv` in `content`, while future/legacy envelopes may carry
>    base64 binary `.kslog` content. Decode/parse the envelope, then extract our detected
>    jumps (elapsed time, height, airtime, distance) by re-running the Swift V7 engine with
>    `Kiters/Tools/JumpReplay`.
> 3. `JUMP_ALGORITHM_V7.md` — the V7 spec and default params (§7).
>
> Do:
> 1. Decode both logs; sanity-check magic/duration.
> 2. Extract our jumps per log with elapsed times.
> 3. **Identify which log is the Surfr session** by matching the four elapsed-times
>    (558/735/958/1333 s) — best single constant offset, residuals ≤ ~3 s, no extra
>    detections. If none matches, report "unsynced" and fall back to height-rank matching.
> 4. Build a per-jump alignment table: Surfr vs ours (Δtime, Δheight, Δairtime, Δdistance).
> 5. Classify discrepancies: timing drift, false positives, false negatives.
> 6. Tune V7 params so it detects exactly the 4 jumps at the right times (no FP/FN),
>    `|Δh| ≤ 0.20 m`, `|Δairtime| ≤ ~0.3 s`. Explain each change; show before/after metrics.
>
> Note: `JUMP_ALGORITHM_V7.md` says the watches were unsynced and timing wasn't comparable.
> The Surfr "Time" column now provides elapsed-in-session timing, so **verify** the match by
> time first; only if it holds, calibrate by time + height together.
>
> Deliver: matching log + proof; the alignment table; discrepancy list; proposed parameter
> changes with before/after metrics; optional calibration report under `docs/`.

---

## 10. פרומפט מוכן לשימוש (עברית)

> **משימה: כיול דיוק-הזמנים של אלגוריתם זיהוי הקפיצות V7 מול אמת-מידה של Surfr.**
>
> קלט (שורש הרפו אלא אם צוין):
> 1. `WhatsApp Image 2026-06-12 at 23.59.59.jpeg` — צילום מסך של Surfr (אמת-מידה).
>    4 קפיצות; עמודות גובה / Airtime / מרחק / **זמן (elapsed)**:
>    `1: 3.17m, 4.59s, 7m, 9:18` · `2: 3.45m, 4.12s, 24m, 12:15` ·
>    `3: 3.14m, 4.37s, 10m, 15:58` · `4: 3.77m, 4.33s, 20m, 22:13`.
>    סשן: 12 Jun 2026 12:09 GMT+3, ~30 דק', Twintip.
> 2. `log2.json` ו-`log1.json` — הלוגים שלנו. כל קובץ הוא עוטפת ענן; קבצי שורש הרפו הנוכחיים
>    מכילים `text/csv` בשדה `content`, ואילו עוטפות עתידיות/ישנות יכולות להכיל `.kslog`
>    בינארי ב-base64. פענח/פרסר את העוטפת, ואז חלץ את הקפיצות שזיהינו (זמן elapsed, גובה,
>    airtime, מרחק) באמצעות הרצת מנוע Swift V7 דרך `Kiters/Tools/JumpReplay`.
> 3. `JUMP_ALGORITHM_V7.md` — מפרט V7 ופרמטרי ברירת המחדל (§7).
>
> בצע:
> 1. פענח את שני הלוגים; אמת magic/משך.
> 2. חלץ את הקפיצות שלנו בכל לוג עם זמני elapsed.
> 3. **זהה איזה לוג הוא הסשן של Surfr** ע"י התאמת ארבעת הזמנים (558/735/958/1333 שניות) —
>    offset קבוע יחיד, שאריות ≤ ~3 שניות, ללא זיהויים עודפים. אם אף אחד לא תואם — דווח
>    "unsynced" וחזור לכיול לפי דירוג גובה.
> 4. בנה טבלת יישור פר-קפיצה: Surfr מול שלנו (Δזמן, Δגובה, Δairtime, Δמרחק).
> 5. סווג חריגות: drift תזמון, False Positives, False Negatives.
> 6. כוונן פרמטרי V7 כך שמזוהות בדיוק 4 הקפיצות בזמנים הנכונים (ללא FP/FN),
>    `|Δh| ≤ 0.20 m`, `|Δairtime| ≤ ~0.3 s`. הסבר כל שינוי; הצג מטריקות before/after.
>
> הערה: `JUMP_ALGORITHM_V7.md` קובע שהשעונים היו unsynced ושהתזמון לא היה בר-השוואה. עמודת
> ה-Time בתמונה נותנת כעת זמן elapsed בסשן, לכן **אמת** קודם את ההתאמה לפי זמן; רק אם היא
> מתקיימת — כייל לפי זמן וגובה יחד.
>
> תוצרים: הלוג התואם + הוכחה; טבלת היישור; רשימת חריגות; שינויי פרמטרים מוצעים עם
> מטריקות before/after; דו"ח כיול אופציונלי תחת `docs/`.
