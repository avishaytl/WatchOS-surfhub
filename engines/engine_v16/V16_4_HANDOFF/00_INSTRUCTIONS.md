# V16.4 — handoff to the watch team

Four changes on top of V16.3, all in `JumpEngineV16.swift`. No new sensors, no
new state, no API change. The version string moves `16.3` → `16.4`.

**This supersedes `V16_3_HANDOFF`.** If that package was never integrated, take
this one instead — it contains everything V16.3 had.

| | change | what it buys |
|---|---|---|
| **1** | **flight corroboration** for a short shelf | CLEAN 3/4 → **4/4**, V142 2/5 → **4/5**, Yaniv 20/24 → **23/24** |
| **2** | lift-shelf gate 0.70 → **0.60 s** | Yaniv 19/24 → 20/24 |
| **3** | no flight window → **no distance** | smallLog distance 4.96 → **4.50 m**, correlation 0.456 → **0.585** |
| **4** | `confidence` pinned to an absolute shelf | consistency fix, no behaviour change at the old gate |

```
                V16.3                              V16.4
  guarded recall        35/39                      38/39
  pooled height MAE     0.292 m                    0.282 m
  tallest phantom       1.56 m                     1.56 m   (unchanged)
  negative control      0                          0        (unchanged)
  287 / smallLog        —                          unchanged in every column
```

**No real jump is lost anywhere.** The reference suite also gained a seventh log
(Yaniv, 24 Surfr goldens), so the numbers above are measured over more data than
V16.3 ever was.

---

## Take this first

Copy `01_ENGINE/JumpEngineV16.swift` over the existing file. That is the whole
delivery. `01_ENGINE/jumpEngineV16.ts` is the TypeScript twin, behaviourally
identical; if you change one, change the other. The replay CLI scores the TS side
and produced every number here.

---

## Change 1 — flight corroboration (the important one)

### What was wrong

A short lift shelf is admitted only with corroboration, and the corroborating
statistic was `apex`: the matched filter over a **FIXED** `[t0 − 2.5 s, t0 + 2.0 s]`
window, 4.5 s wide. That gate ran **before** the landing was resolved.

A long flight overflows a 4.5 s window. On the Yaniv session the four jumps Surfr
caught and we did not have reference airtimes of **4.3–4.8 s**, and their apex
over the fixed window read **0.00–0.19** — while the same integral over the
**flight** window returned metres.

This was a leftover. Since V16.2 the flight window IS the height measurement; the
gate was still judging candidates with the old matched filter.

### The rule now

```swift
public var flightCorroboration = true
public var shortShelfFlightM   = 1.2     // == minReportM
```

When the shelf is short **and** the fixed window finds no apex, the candidate is
no longer discarded there. The decision is **deferred** until the landing is
resolved, and then the flight height must clear `shortShelfFlightM` on its own.

`shortShelfFlightM` is set to `minReportM`: anything that clears the reporting
floor on the flight window has produced a real vertical excursion. Swept 1.2–3.0 m
over all seven logs — the negative control stays silent and the tallest phantom
stays 1.56 m at **every** value, while recall keeps climbing as it drops.

### Why we believe those four jumps are real

Scanning every window inside each missed minute, with the duration held to the
reference's own airtime ±1 s:

| Surfr row | they report | best our signal yields |
|---|---|---|
| #15 | 2.76 m | 2.79 m |
| #22 | 4.25 m | 4.63 m |
| #26 | 4.29 m | 4.55 m |
| #31 | 3.41 m | 3.56 m |
| **negative control, same scan** | — | **1.25 m** |

A session containing no jumps at all cannot produce more than 1.25 m by this
method. **Caveat we checked and you should know:** with the duration left free the
same scan reaches 5.9 m on Yaniv **and 2.57 m on the control** — i.e. it buys
height with window length. The table above is the bounded scan.

---

## Change 2 — lift-shelf gate 0.70 → 0.60 s

Identical, to the digit, on six of the seven logs. Recovers one real jump on
Yaniv.

**Do not lower it further.** Swept to 0.30: recall is **flat** across the whole
range — no log gains anything — while 287 picks up a 1.41 m phantom at 0.50 and
keeps it. The gate is not what blocks the remaining jumps; that was change 1.

---

## Change 3 — no flight window, no distance

An unresolved landing left `tEnd` at `apexPostSec`, so the reported distance
covered **2 s of a 4–5 s flight**. On smallLog the single such jump reported
19.5 m against a 30.4 m golden and carried the session's second-largest error.

`if landingT == nil { distanceM = nil }`. "Not measured" beats "measured wrong".

---

## Change 4 — `confidence` pinned

```swift
public var strongShelfSec: TimeInterval = 1.05
// was: confidence = shelf >= cfg.minLiftPlateauSec * 1.5
//  now: confidence = shelf >= cfg.strongShelfSec
```

The two were the same number while the gate sat at 0.70 s, but they answer
different questions — the gate asks "is this a jump", confidence asks "is the
evidence strong". Deriving one from the other meant that lowering the gate to
0.60 would also relabel 0.90–1.05 s shelves as *high confidence*, which is the
exact band the phantom filter treats as suspect. 1.05 s is where that filter draws
its line, so the two now agree by construction.

---

## What to verify after integrating

1. The version banner reads `16.4`.
2. A bench throw still reports a height — the throws are untouched (3/4, and the
   phantom filter never reaches them because a catch always resolves the arrest
   landing).
3. `landing()` returns a tuple (from V16.3). No call site left on the old
   single-value signature.
4. A jump with no resolved landing now reports **no distance**. The app must show
   nothing there, not zero.

---

## Rejected after measurement — do not re-attempt

| idea | why it failed |
|---|---|
| interpolating the GPS distance endpoints | physically right (fixes at 1.00 Hz, ±4 m of pure timing error per end) but it SPLITS: 287 improves 3.77 → 3.64 m (r 0.885 → 0.918), smallLog worsens 4.96 → 5.12 m (r 0.456 → 0.380). Pooled, a wash |
| path length instead of the chord | the chord wins on all three logs; they measure a chord too |
| a global airtime offset | every value from +0.1 to +0.5 s makes the pooled MAE worse |
| deep unloading as a second detection path | the negative control reaches the same values — no separation |
| reduced lift smoothing | recovers more on Yaniv but breaks 287 (14/14 → 13/14) and smallLog (16/16 → 13/16) |
| shelf gate below 0.60 | recall flat to 0.30; only cost, no gain |

---

## Two ceilings, so nobody spends a week on them

**Airtime cannot be converged.** The two references disagree about the definition
by nearly a second: HOOLAN averages 3.56 s on smallLog against Surfr's 4.49 s on
Yaniv over overlapping height ranges. Our own biases have opposite signs
(+0.18 / +0.69 / −0.22), so no constant fixes all three.

**Distance is airtime in disguise.** Across 11 of smallLog's 14 jumps, changing
the GPS endpoint handling moves the error by 0.01 m; the whole error sits in three
outliers and all three are landing failures. Distance has the same ceiling.

Breaking either needs video ground truth, not a new algorithm.

---

## Still outstanding, unchanged from V16.2

**`watch-ingest`'s normaliser fills missing `JumpEvent` fields with `0`.** Correct
for the original seven, but it would turn an ABSENT diagnostic into a MEASURED
ZERO — `sr: 0` reads as "stopped dead", `eg: 0` as "no edge at all". It must pass
the ten optional keys through only when present. **Do not enable the new payload
fields until that is done.** The spec is in `02_PATCHES/JumpEvent_extension.md`.

**Please add the `engine=v...` banner to the field log.** Absent from both the
Gavri and Yaniv captures; the version had to be inferred from behaviour.

---

## Contents

```
00_INSTRUCTIONS.md              this file
01_ENGINE/                      JumpEngineV16.swift + the TypeScript twin
02_PATCHES/                     the per-jump payload spec (unchanged from V16.2)
03_DOCS/                        what was measured and rejected
04_REFERENCE/                   the replay CLI, its output at V16.4, and the
                                Yaniv jump-by-jump comparison
```
