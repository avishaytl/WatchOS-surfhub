# V16.5 — handoff to the watch team

One change in the engine, one request for the recording app.

**Supersedes `V16_4_HANDOFF` and `V16_3_HANDOFF`** — this package contains
everything they had.

```
                       V16.4          V16.5
  guarded recall       38/39          38/39
  pooled height MAE    0.282 m        0.199 m      -29 %
  tallest phantom      1.56 m         1.57 m
  negative control     0              0
```

| log | V16.4 | **V16.5** |
|---|---|---|
| 287 (big air) | 0.416 m | **0.226 m** |
| V142 | 0.240 m | **0.158 m** |
| CLEAN | 0.140 m | **0.112 m** |
| YANIV | 0.768 m | **0.556 m** |
| smallLog | 0.211 m | 0.206 m |
| BENCH (throws) | 0.017 m | 0.017 m |

**No real jump lost, and the phantom count is unchanged on every single log.**

---

## The change: a 0.3 s take-off pre-roll on the height window

`t0` is the POP — the strongest sample of the take-off burst — and the rider is
already rising by the time it arrives. Starting the integral there truncates the
first part of the ascent, and the signature is a NEGATIVE height bias that **both
references show independently**: −0.118 m against Surfr, −0.210 m against HOOLAN.

```swift
public var heightPreRollSec: TimeInterval = 0.3
...
if !ballistic, winB != nil { winA = t0 - cfg.heightPreRollSec }
```

### Why 0.3 and not the suite optimum

Sweeping the window start from 0 to −0.9 s traces a clean U on each reference
**separately**:

| shift | GAVRI (Surfr) | HOOLAN | pooled |
|---|---|---|---|
| 0.0 | 0.216 (−0.118) | 0.330 (−0.210) | 0.291 |
| −0.2 | 0.192 | 0.251 | 0.231 |
| **−0.3** | **0.204** | **0.218** | **0.213** |
| −0.5 | **0.250** | 0.205 (−0.010) | 0.220 |
| −0.9 | 0.325 | 0.227 | 0.261 |

The full guarded suite bottoms out at −0.5 s (0.188 m) — but that suite is
**entirely HOOLAN-lineage**, and Surfr is the only independent reference we have.
At −0.5 s Surfr **degrades below baseline** (0.216 → 0.250). 0.3 s is the only
value that improves both families, so that is what ships. Shifting the LANDING
does almost nothing by comparison (0.213–0.219 across ±0.4 s): the whole error
lives at the take-off end.

### Scope

**Height window only.** Detection, airtime and distance still use `t0` unchanged —
the same decoupled-anchor pattern as `apexAnchorSec`. **Free fall is exempt**: it
bounds a thrown watch exactly, and BENCH stays at 0.017 m.

### Two things measured and recorded so they are not retried

Feeding the RAW (un-pre-rolled) height to the short-shelf corroboration gate is
**worse** — it costs V142 a real jump (4/5 → 3/5). The gate wants the same number
the rider is shown.

**Known cost, one jump:** on smallLog two candidates 2.4 s apart sit inside
`dedupSec`, and the pre-roll flips which is "stronger" by 2 cm (1.61 vs 1.59 m).
The wrong one wins and its distance goes 19 → 36 m against an 18.2 m golden,
moving that log's distance MAE 4.50 → 5.82 m. A dedup coin-flip amplified by one
outlier — log 287's distance is unchanged at 3.77 m.

---

## The request: put absolute altitude back into the recording

**This one is on us, and the logs say so in their own words.**

| log | absAlt records | the log's own event line |
|---|---|---|
| 287 | 7612 | `Absolute altitude acquisition: continuous single-consumer, no watchdog restarts` |
| smallLog | 3091 | same |
| CLEAN | 4530 | same |
| V142 | 343 | same |
| **GAVRI** | **0** | `Absolute altitude acquisition: onDemand (stream off until a jump window opens)` |
| **YANIV** | **0** | same |

`onDemand` cannot work: `CMAltimeter` needs time to settle after being started,
and by the time it wakes the jump is over. The result is not *few* samples, it is
**zero**. Please return the acquisition mode to `continuous`.

`Kiters Watch App/Services/MotionManager.swift` already contains the full, correct
implementation — `startAbsoluteAltitudeLocked`, stream generations, the
`accuracy >= 100` re-anchor sentinel, health monitoring and restart. It simply is
not being run.

### What this is NOT for

**Not as a height source.** Measured on the four logs that still have the channel:
it is live (precision ≤ 1) during only **7 of 37 goldens**, and on log 287 it is
frozen during 12 of 14 jumps specifically. Where it IS live it gives 0.89–1.75 m
MAE against the IMU's 0.14–0.42 m. Apple's own `accuracy` field reads **4.7–9.6 m**
on those same live samples — the sensor states that its uncertainty exceeds the
jump we are measuring.

A "use the barometer when it agrees within 20 %" rule was tested: it fires on **2
of 37** goldens, and on both of them switching makes the error **worse**
(−0.47 → +0.68 m, and −0.01 → +0.41 m). That is structural, not bad luck — when
the two agree there is nothing to gain, and when they disagree we would not switch.

### What it IS for

An independently recorded diagnostic channel, so the question can be re-measured
if the hardware improves. Collecting it costs nothing and its absence cost us the
ability to answer this at all on the two newest sessions.

### One thing that is NOT our fault

The **freeze** (`precision` flipping from 0.5 to 5 and the value repeating for
tens of seconds) is Core Motion's own behaviour. Checked against every device
state we log: `lowPower` 0 % in both the live and frozen stretches, `thermal` 0,
battery constant, and only 1–3 transitions per session. CLEAN ran 100 % live for
25 minutes. Apple signals the degradation honestly through `precision`; treat that
field as the health flag.

---

## What to verify after integrating

1. The version banner reads `16.5`.
2. A bench throw still reports its height (free fall is exempt — 0.017 m).
3. A jump with no resolved landing still reports **no distance** (from V16.4).
4. `landing()` returns a tuple (from V16.3) — no call site left on the old
   signature.
5. New field logs contain a non-empty `absAlt` stream with `accuracy` and
   `precision`.

---

## Still outstanding

**`watch-ingest`'s normaliser fills missing `JumpEvent` fields with `0`.** It must
pass the ten optional keys through only when present — `sr: 0` reads as "stopped
dead", `eg: 0` as "no edge at all". **Do not enable the new payload fields until
that is done.** Spec in `02_PATCHES/JumpEvent_extension.md`.

**The `engine=v...` banner is still missing from the field log.** Absent from both
the Gavri and Yaniv captures; the version had to be inferred from behaviour.

---

## Contents

```
00_INSTRUCTIONS.md   this file
01_ENGINE/           JumpEngineV16.swift + the TypeScript twin (both at 16.5)
02_PATCHES/          the per-jump payload spec (unchanged since V16.2)
03_DOCS/             everything measured and rejected, across all versions
04_REFERENCE/        the replay CLI, its output at 16.5, and the full
                     jump-by-jump comparison for all seven logs
```
