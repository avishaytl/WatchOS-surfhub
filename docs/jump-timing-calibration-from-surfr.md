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
Swift engine `SPOTEQ/SPOTEQ Watch App/Services/KitesurfJumpEngine.swift` ·
replay tool `SPOTEQ/Tools/JumpReplay` · binary writer
`SPOTEQ/SPOTEQ Watch App/Services/SessionLogger.swift`

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
  "content":"# SPOTEQ Sensor Log\n..." }
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
> engine** through `SPOTEQ/Tools/JumpReplay` over the parsed IMU/baro/speed stream to get
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
swift run --package-path SPOTEQ/Tools/JumpReplay JumpReplay --surfr --output /tmp/spoteq-surfr log1.json log2.json
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

### 8.2 2026-06-19 strict GPS-free replay

Command:

```bash
cd "SPOTEQ/Tools/JumpReplay"
swift build
.build/debug/JumpReplay --surfr -v ../../../docs/log2.json
```

Sanity:

- `log2.json` is the upload envelope `log_20260612_121459_4173200D.csv`.
- Header reports session `4173200D-12D1-4FAE-9495-EAE3484A48F4`, build `46`,
  CSV `contentType: text/csv`, and `sampleRate: 50 Hz`.
- Parsed rows: `84,261`; measured duration `1684.6s` (`~28.1 min`) at `~49.9 Hz`.
- The replay uses the real CSV `spd` column when present. The log speed is non-zero for
  nearly all rows; max speed is `11.26 m/s` (`40.5 km/h`), close to the Surfr summary
  max speed of `38 km/h`.

Parameter change applied for this pass:

- Removed the relaxed toss/dev branch from the production path.
- Kept detection GPS-independent: GPS speed never arms/disarms the jump engine and never
  rejects a candidate.
- Restored strict V7 gates in Swift and Android parity:
  `releaseFloorG=1.70`, `releaseSigmaK=1.50`, `releaseGyroMinRad=2.00`,
  `minAirTimeSec=2.00`, `hardLandingMinAirTimeSec=2.00`, `minJumpHeightMeters=1.00`,
  `landingContactGyro=2.00`, `landingSpikeGyro=1.00`,
  `symmetricAscentFraction=0.143`, `displayedAirtimeScale=0.73`.

Before/after on `log2`:

| Replay profile | Accepted candidates | Strict Surfr match | Notes |
|---|---:|---|---|
| Relaxed sensor-only/toss branch | 105 | **No** | Very high recall, but obvious FP explosion. |
| Strict GPS-free V7 | 12 | **No** | Much safer, but still not the exact Surfr table. |
| Moderate gyro relaxation (`releaseGyro=1.6`, `landingContactGyro=1.5`) | 13 | **No** | Adds an extra FP and does not recover rows 2-4 within `±3s`. Rejected. |

Strict GPS-free alignment against the Surfr screenshot:

| # | Surfr t | V7 t | Δt | Surfr h | V7 h | Δh | Surfr air | V7 displayed air | Δair | Surfr dist | V7 dist | Δdist | Notes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 558s | 558.66s | +0.66s | 3.17 | 2.25 | -0.92 | 4.59 | 3.46 | -1.13 | 7 | 41.0 | +34.0 | nearest accepted |
| 2 | 735s | 743.76s | +8.76s | 3.45 | 2.88 | -0.57 | 4.12 | 3.91 | -0.21 | 24 | 46.0 | +22.0 | nearest accepted |
| 3 | 958s | 981.74s | +23.74s | 3.14 | 3.35 | +0.21 | 4.37 | 4.22 | -0.15 | 10 | 44.0 | +34.0 | nearest accepted |
| 4 | 1333s | 1624.04s | +291.04s | 3.77 | 3.29 | -0.48 | 4.33 | 1.64 | -2.69 | 20 | 0.0 | -20.0 | nearest accepted |

Extra accepted candidates after matching the nearest four rows:

`43.37s`, `132.10s`, `148.55s`, `437.84s`, `484.50s`, `646.24s`, `681.00s`, `912.72s`.

Embedded on-watch events inside `log2`:

The CSV itself contains event strings from the build-46 detector. Those embedded events
also do **not** match the Surfr screenshot:

| Embedded event time | Event |
|---:|---|
| `56.621s` | `JUMP ACCEPTED h=1.17m air=0.92s ...` |
| `217.720s` | `JUMP ACCEPTED h=1.07m air=0.88s ...` |
| `915.126s` | `JUMP ACCEPTED h=1.22m air=0.94s ...` |
| `917.511s` | `JUMP ACCEPTED h=1.22m air=0.94s ...` |
| `1295.565s` | `JUMP ACCEPTED h=3.79m air=1.66s ...` |

So the watch log is useful as raw sensor input, but its embedded accepted-jump events are
not a clean four-jump ground truth matching the image.

Session-time caveat:

`log2` filename/header starts at `20260612_121459`, while the Surfr screenshot title says
`12 Jun 2026, 12:09 GMT+3`. If that title is the true Surfr session start, the screenshot
times map roughly to `199/376/599/974s` in the log rather than `558/735/958/1333s`.
That shifted comparison is also not a clean `±3s` match for all four rows, though it does
place the fourth Surfr row close to V7's `981.74s` accepted candidate. This means the current
artifact set still has unresolved start-time alignment, not just detector-parameter drift.

Missed/late Surfr rows:

- Row 2 is late by `+8.76s`.
- Row 3 is late by `+23.74s`.
- Row 4 is not recovered near `1333s`; strict replay sees multiple timeout/rejection
  candidates later in the `1293-1410s` region, but no accepted candidate within `±3s`.

Conclusion:

`log2` still looks like the closest/most relevant capture because the first Surfr time
lands exactly and the speed/session metadata are plausible. However, the current evidence
does **not** satisfy the §5 proof for a single-offset timing match. A parameter-only change
cannot honestly make this replay emit exactly `558/735/958/1333` with `0 FP / 0 FN` without
adding a reference-session-specific timestamp filter or a new detector feature that has
not yet been validated on independent no-jump logs. That timestamp filter was deliberately
not added.

Regression:

- `./verify.sh` passes `7/7` after blessing the strict GPS-free baselines.
- `log_ondevice_synthetic.csv` now expects `0` jumps because its synthetic gyro is near
  zero and strict V7 requires wrist-rotation confirmation.

### 8.3 Surfr window calibration gate

`JumpReplay --surfr` now also reads the on-device `evt` column from `log2` and reports a
separate **Surfr windows** table. This does not pretend that V7 final acceptance is already
perfect; it verifies the lower-level fact we need for the next tuning pass: all four Surfr
time windows contain a real jump-like signal in the watch log.

Current local check:

```bash
cd "SPOTEQ/Tools/JumpReplay"
.build/debug/JumpReplay --require-surfr-windows ../../../docs/log2.json
./verify.sh
```

Window gate:

- nearest `AIRBORNE`/`JUMP ACCEPTED` event within `±10s` of the Surfr row,
- raw max acceleration in the row window `>= 1.5g`,
- raw max gyro in the row window `>= 2.0 rad/s`.

GPS/speed is reported for diagnostics only; it is not part of the Surfr window gate.

Current result:

| # | Surfr ref | nearest event | V7 accepted near ref | Window signal |
|---|---:|---:|---:|---|
| 1 | `558s` | `558.66s` | `558.66s` | pass |
| 2 | `735s` | `733.24s` | `743.76s` | pass |
| 3 | `958s` | `964.46s` | `981.74s` | pass |
| 4 | `1333s` | `1340.29s` | `1624.04s` | pass |

`./verify.sh` now includes this check when `docs/log2.json` is present.

Important: this is an intermediate calibration gate. It proves the four main Surfr jumps are
present in the watch log and lets us ignore sub-metre/noise candidates during local tuning.
The log can still contain additional valid smaller jumps; the next step is to use the
window/cluster insight for ranking and diagnostics, not to force the production engine to
hide every non-Surfr-row jump.

### 8.4 2026-06-19 no-GPS production replay

Implemented after comparing the current V7 path with the older engine:

- Reintroduced soft landing candidates (`baroRecovery` / `settle`) as pending fallbacks,
  while still allowing a later stronger `contact` / `hardImpact` landing to win.
- Kept the production path GPS-independent: GPS does not arm/disarm the detector, does not
  reject jumps, and no longer adds a confidence bonus. The same sensor-only confidence credit
  is applied without checking `maxSessionSpeedMS`.
- Added `JumpReplay --no-gps`, which withholds GPS speed/location from the detector.
- Added narrow inertial timeout recovery: a timeout can be accepted without baro only when
  the candidate has enough kinematic height, high takeoff accel, high gyro, and a sustained
  takeoff+gyro burst (`timeoutRecoveryMinBurstSamples=14`).
- Lowered the production display gate from `1.5m` to `1.0m`: sub-metre chop is still
  ignored, but small real jumps are retained.
- The streaming FSM now passes its landing hint into the offline V7 analyzer. This prevents
  a jump from being triggered by a valid live contact and then rejected by a second,
  disagreeing offline landing scan.
- Mirrored the V7 behavior into the Android parity engine.

Current replay result on `docs/log2.json`:

| Mode | Accepted jumps | Surfr window gate | Notes |
|---|---:|---|---|
| normal replay | 24 | 4/4 pass | Uses the CSV speed column for diagnostics/distance only. |
| `--no-gps` replay | 24 | 4/4 pass | Same accepted jump count and timing without feeding GPS. |

Current nearest accepted jumps to the Surfr screenshot rows:

| # | Surfr t | V7 t | Δt | Surfr h | V7 h | Surfr air | V7 displayed air |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | 558s | 558.66s | +0.66s | 3.17 | 2.25 | 4.59 | 3.46 |
| 2 | 735s | 743.76s | +8.76s | 3.45 | 2.88 | 4.12 | 3.91 |
| 3 | 958s | 981.74s | +23.74s | 3.14 | 3.35 | 4.37 | 4.22 |
| 4 | 1333s | 1350.53s | +17.53s | 3.77 | 1.62 | 4.33 | 2.93 |

Recovered high-energy timeout:

- Around `1293s`, the raw sensor window contains a strong candidate (`max accel ~2.98g`,
  `max gyro ~9.23 rad/s`) and the embedded build-46 event reported `h=3.79m`.
- After the inertial timeout recovery, V7 accepts `1293.25s` as
  `h=4.24m`, `displayed air=4.74s`, `physical air=6.47s`, `conf=64`, `land=timeout`.
- This recovery is deliberately not based on GPS and not based on baro. Filtered real baro
  around this candidate is effectively flat, so the evidence is inertial/kinematic.
- The screenshot row at `1333s` is still not a strict `±3s` timing match to the accepted
  jump list, which keeps the start-time/alignment caveat open.

Regression after this pass:

```bash
cd "SPOTEQ/Tools/JumpReplay" && ./verify.sh
cd "SPOTEQ" && swift run WatchLiveSessionCoreChecks
```

Both pass. `verify.sh` currently reports `9 passed, 0 failed, 0 skipped`: the standard
replay baselines, the Surfr window gate, and the same Surfr window gate with `--no-gps`.

### 8.5 2026-06-19 watch log `61A41698`

Input: `log_20260619_123224_61A41698.kslog`.

Sanity:

- Raw binary `.kslog`, session `61A41698-B42D-42A7-9470-E63D34C975EB`.
- Header reports `sensorOnly=true`, `sampleRateHz=50`, `minAirtime=2`,
  `maxAirtime=6.5`, `takeoffG=1.7`.
- Parsed replay rate: `50.5Hz`, `4700` samples, `93.1s`.
- Normal replay and `--no-gps` replay produce the same accepted jumps.

Before this pass, replay accepted only two jumps:

| t | h | displayed air | Notes |
|---:|---:|---:|---|
| `25.26s` | `3.44m` | `4.28s` | accepted |
| `61.81s` | `1.85m` | `3.14s` | accepted |

Root causes for the missed user jumps:

- `minJumpHeightMeters=1.5` rejected valid small jumps at roughly `1.1-1.4m`.
- The live streaming FSM saw a valid landing at `48.72s`, but the offline analyzer did not
  receive that landing index and reclassified the same candidate as a timeout.

After lowering the height gate to `1.0m` and passing the landing hint into V7:

| # | t | h | displayed air | physical air | confidence | landing |
|---|---:|---:|---:|---:|---:|---|
| 1 | `25.26s` | `3.37m` | `4.23s` | `5.81s` | `53` | `hardImpact` |
| 2 | `48.72s` | `1.40m` | `2.73s` | `3.74s` | `67` | `contact` |
| 3 | `61.81s` | `1.77m` | `3.07s` | `4.20s` | `53` | `contact` |
| 4 | `67.55s` | `1.11m` | `2.42s` | `3.31s` | `76` | `contact` |
| 5 | `72.02s` | `1.42m` | `2.74s` | `3.80s` | `68` | `contact` |

Rejected nearby candidates:

- `3.90s`: computed height `0.91m`, below the `1.0m` gate.
- `8.38s` and `32.38s`: high-gyro/high-accel handling bursts, but no valid landing and no
  sustained timeout recovery; still rejected.

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
>    `SPOTEQ/Tools/JumpReplay`.
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
>    airtime, מרחק) באמצעות הרצת מנוע Swift V7 דרך `SPOTEQ/Tools/JumpReplay`.
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
