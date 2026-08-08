# V16.3 — handoff to the watch team

Two changes on top of V16.2, both in `JumpEngineV16.swift`. No new sensors, no
new state, no API change. The engine version string moves `16.2` → `16.3`.

| | what it does | what it buys |
|---|---|---|
| **1. settle fallback** | a second-chance landing when the descent-arrest rule never resolves | pooled height MAE **0.300 → 0.292 m**; GAVRI 0.468 → 0.401 m |
| **2. phantom filter** | rejects a jump whose flight signature is incomplete | suite's tallest phantom **2.54 → 1.56 m**; 287 and its 3 phantoms → **0** |

**Neither costs a single real jump.** Recall is 35/39 before and after, across
six logs holding 78 confirmed jumps.

---

## Take this first

Copy `01_ENGINE/JumpEngineV16.swift` over the existing file. That is the whole
delivery — everything below explains what changed and why, so a reviewer can
check the reasoning rather than take it on trust.

`01_ENGINE/jumpEngineV16.ts` is the TypeScript twin, kept byte-for-byte
behaviourally identical. If you change one, change the other; the replay CLI
scores the TS side and is what produced every number in this document.

---

## Change 1 — the settle fallback

### The rule

When `arrestLanding()` returns nil at the deadline, look for the specific force
returning to ~1 g and STAYING there for 0.4 s. That instant is the landing.

```swift
public var landSettleFallback = true
public var landSettleBandG    = 0.30      // distance from 1 g that counts as settled
public var landSettleMinSec   = 0.4       // how long it must hold
public var landSettleFromSec  = 1.0       // searched over [t0 + 1.0, t0 + 9.0]
public var landSettleToSec    = 9.0
```

### Why it is worth having

An unresolved landing costs more than a missing airtime. It also denies the
HEIGHT its flight window, dropping it to the matched-filter fallback. On the five
GAVRI jumps that never resolved, height error was 0.77 m and becomes 0.20 m once
a window exists.

### Two things that will look wrong if you do not know them

**It must only run when `forced` is true.** `landing()` is called on every sample
while the flight is still in the air. Early on, the arrest rule has not seen its
descent yet — a settle window offered then pre-empts the better answer and
finalises the jump on a partial flight. Measured on log 287 that mistake cost
**0.30 → 0.76 m** of height. The `forced` gate is what makes this change an
improvement instead of a regression.

**It may only ADD a window, never remove a jump.** A settle landing shorter than
`minAirtimeSec` is discarded rather than used, because a resolved-but-short
flight is REJECTED downstream, and these jumps are currently kept with airtime
reported as "not measured". Turning that into a rejection would trade height
accuracy for recall — the wrong way round.

### Why not one of the obvious alternatives

Every impact-based landing rule was measured against both references and all are
far worse, because **a kite landing is soft and has no touchdown spike**:

| rule | GAVRI airtime MAE | 287 airtime MAE |
|---|---|---|
| descent arrest (shipped) | **0.93 s** | **0.46 s** |
| settle, as the primary rule | 1.14 s | 1.08 s |
| peak \|sf\| impact | 1.76 s | 1.64 s |
| first \|sf\| > 2.0 g | 2.14 s | 2.07 s |
| impact then settle | 2.14 s | 2.07 s |
| gyro settles < 3 rad/s | 2.92 s | 3.63 s |

The impact rules all fire **1.4–3.6 s EARLY**. Settle is second-best and nearly
unbiased, which is exactly why it belongs as the fallback and nowhere else.

---

## Change 2 — the phantom filter

### The rule

```swift
public var phantomFilter        = true
public var phantomShelfSec      = 1.05    // short shelf rejects on its own
public var phantomShelfWideSec  = 1.20    // a longer shelf rejects only if small
public var phantomWideHeightM   = 2.0
```

Reject when the descent-arrest landing never resolved **AND**
( shelf < 1.05 s **OR** ( shelf < 1.20 s **AND** height < 2.0 m ) ).

Two independent weak signs of the same thing. Either alone is common in real
jumps; together they say the take-off was never followed by a kite flight.

### It reads the ARREST rule, not "do we have a landing"

This is the part worth understanding. The settle fallback usually supplies a
measurement window for these very jumps, and **that window is still used for the
height**. "Can we measure it" and "was it a jump" are separate questions, and
V16.3 keeps them separate. Across all six logs:

| | count |
|---|---|
| emissions with the arrest rule unresolved | 17 |
| of those, the settle fallback supplied a window | 10 |
| of those, the phantom filter rejects | 7 |

On 287 and smallLog the settle found no window for any of the five flagged
events, and the filter removed four of them — corroborating: those events never
settle back to 1 g in an orderly way either, because they are not flights.

### The throws are safe

All three detected bench throws have a RESOLVED arrest landing, so the filter
never reaches them at any threshold. Physically it could not be otherwise: a
thrown watch is CAUGHT, a 15–23 g deceleration that the arrest rule resolves
trivially. The filter targets soft or absent landings; a catch is the opposite.

### Why the second clause exists

It spares exactly ONE real jump: a 2.50 m smallLog golden sitting at exactly the
same 1.10 s shelf as two phantoms of 1.57 m and 1.59 m. Height separates them by
0.9 m. A single shelf threshold cannot express that and has to sell the golden to
buy the phantoms.

**Be honest about what that means: the height bound is fitted to one point.**
Two things make it defensible — the zero-cost region is broad (shelf 1.15–1.25 ×
height 1.6–2.4 all score 8 removed / 0 lost, so these are not knife-edge
constants), and the separating margin is 0.9 m rather than centimetres. It should
still be re-checked whenever a new reference session lands.

### The alternatives, priced

Every rule was charged in full against all six logs. A rule that trims GAVRI's
extras by deleting log 287's goldens is not a filter, it is a leak.

| rule | removed | real jumps lost |
|---|---|---|
| unresolved AND shelf < 1.05 | 6 | 0 |
| **shipped (two-clause)** | **8** | **0** |
| unresolved AND shelf < 1.25 | 8 | 1 (smallLog golden) |
| unresolved, alone | 10 | 6 |
| height < 2.5 AND shelf < 1.1 | 11 | 6 |
| shelf < 1.0 alone | 11 | 7 |

---

## What to verify after integrating

1. The version banner reads `16.3`.
2. On a bench throw the engine still reports a height (the filter must not touch
   it — the arrest rule resolves a catch).
3. `landing()` now returns a tuple. Make sure no other call site was left on the
   old single-value signature.

## Still outstanding from V16.2, unchanged

**`watch-ingest`'s normaliser fills missing `JumpEvent` fields with `0`.** That is
correct for the original seven but would turn an ABSENT diagnostic into a
MEASURED ZERO — `sr: 0` reads as "stopped dead", `eg: 0` as "no edge at all". The
normaliser must pass the ten optional keys through only when present. **Do not
enable the new payload fields on the watch until that is done.**

**Please add the `engine=v...` banner to the field log.** It was absent from the
Gavri capture, and version had to be inferred from behaviour.

---

## Contents

```
00_INSTRUCTIONS.md     this file
01_ENGINE/             JumpEngineV16.swift + the TypeScript twin
02_PATCHES/            the diff, described change by change
03_DOCS/               what was measured and rejected, and the accuracy ceiling
04_REFERENCE/          the replay suite output at V16.3
```
