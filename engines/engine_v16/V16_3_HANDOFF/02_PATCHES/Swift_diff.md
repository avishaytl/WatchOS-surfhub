# The diff, change by change

Five edits to `JumpEngineV16.swift`. Nothing else in the file moves.

---

## 1. `V16Config` — nine new fields

Placed after `minAirtimeSec`. Every one has a default, so an integrator who
changes nothing gets V16.3 behaviour.

```swift
// settle fallback
public var landSettleFallback = true
public var landSettleBandG    = 0.30
public var landSettleMinSec: TimeInterval = 0.4
public var landSettleFromSec: TimeInterval = 1.0
public var landSettleToSec:   TimeInterval = 9.0

// phantom filter
public var phantomFilter       = true
public var phantomShelfSec:     TimeInterval = 1.05
public var phantomShelfWideSec: TimeInterval = 1.20
public var phantomWideHeightM  = 2.0
```

Set `landSettleFallback = false` and `phantomFilter = false` to get exact V16.2
behaviour back. Useful for A/B on a device.

---

## 2. `landing()` — split in two, and it now returns provenance

The old body is renamed `arrestLanding()` unchanged. The new `landing()` wraps
it:

```swift
private func landing(_ bins: Bins, t0: TimeInterval, forced: Bool)
    -> (t: TimeInterval?, fromArrest: Bool) {
    if let arrest = arrestLanding(bins, t0: t0) { return (arrest, true) }
    guard forced, cfg.landSettleFallback else { return (nil, false) }
    guard let settle = settleLanding(t0: t0),
          settle - t0 >= cfg.minAirtimeSec else { return (nil, false) }
    return (settle, false)
}
```

**`forced` is load-bearing.** Without it the fallback fires mid-flight and
pre-empts the arrest rule; measured cost on log 287 is 0.30 → 0.76 m of height.

**`fromArrest` is what the phantom filter reads.** It is NOT "do we have a
landing" — the settle fallback usually supplies one for these very jumps and the
height still uses it.

---

## 3. `settleLanding()` — new

```swift
private func settleLanding(t0: TimeInterval) -> TimeInterval? {
    let need = cfg.landSettleMinSec
    let from = t0 + cfg.landSettleFromSec, to = t0 + cfg.landSettleToSec
    var run = 0.0
    var prevT = Double.nan
    var i = ringHead
    while i < ring.count {
        let s = ring[i]
        i += 1
        if s.t < from { continue }
        if s.t > to { break }
        let sf = Self.specificForce(s)
        let dt = prevT.isFinite ? s.t - prevT : 0
        prevT = s.t
        if sf.isFinite, abs(sf - 1) < cfg.landSettleBandG {
            run += dt
            if run >= need { return s.t - need }
        } else {
            run = 0
        }
    }
    return nil
}
```

Runs on **specific force**, not `|userAcceleration|`. `sf` is 1 at rest and 0 in
free fall regardless of attitude, so "back to 1 g" is a frame-independent
statement about being supported again. `|userAcceleration|` reads ~1.0 g in free
fall and would say the opposite.

Reports the START of the settled run, which is where support resumes. The end
would be an arbitrary `landSettleMinSec` later.

`prevT` advances on every sample including rejected ones, so a reset run
re-accumulates with the real sample spacing rather than assuming a fixed rate.
The watch runs at 50 Hz and the reference logs at 200 Hz; this is the only
reason the same constants hold on both.

---

## 4. `evaluate()` — the call site

```swift
let land0 = landing(bins, t0: t0, forced: forced)
let landingT = land0.t
```

Everything downstream still reads `landingT` and is unchanged.

---

## 5. `evaluate()` — the filter, immediately before the GPS lookups

Placed there because it needs both the shelf and the FINISHED height, and it must
run BEFORE the dedup hold so a rejected candidate never displaces a real jump
sitting in `pending`.

```swift
if cfg.phantomFilter && !land0.fromArrest {
    let short = plateau < cfg.phantomShelfSec
    let shortAndSmall = plateau < cfg.phantomShelfWideSec
        && heightM < cfg.phantomWideHeightM
    if short || shortAndSmall {
        onDebug(now, "REJECT t0=\(f2(t0)) reason=incompleteFlight shelf=\(f2(plateau))s h=\(f2(heightM))m noArrest")
        return true
    }
}
```

Returning `true` means "handled" — the candidate is consumed, not deferred.

---

## Behaviour to expect on a device

A rejected candidate can let a NEIGHBOURING candidate through. On log V142 the
1.57 m phantom at t=338.3 s is rejected and a second candidate 5.5 s later
(1.54 m, shelf 1.20 s — exactly on the boundary) emits in its place. Same
take-off, re-anchored. The count did not change there; the height did, slightly.
This is expected and not a bug: dedup holds candidates, and removing the holder
releases the next one.

---

## The suite, before and after

```
                V16.2                          V16.3
log     recall  emitted  phantoms  tallest     recall  emitted  phantoms  tallest
BENCH    3/4       3        0        —          3/4       3        0        —
SMALL   16/16     19        3      2.14 m      16/16     18        2      1.56 m
287     14/14     17        3      2.54 m      14/14     14        0        —
NEG      0/0       0        0        —          0/0       0        0        —
CLEAN    3/4       3        0        —          3/4       3        0        —
V142     2/5       3        1      1.57 m       2/5       3        1      1.54 m

pooled height MAE   0.292 m -> 0.292 m
recall              35/39   -> 35/39
tallest phantom     2.54 m  -> 1.56 m
```

The CLI guard-rail `tallestPhantomM` moved 2.6 → 1.7 to lock the gain in.
