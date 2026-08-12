# The V16.4 diff, change by change

Five edits to `JumpEngineV16.swift` beyond V16.3. Nothing else moves.

---

## 1. `V16Config` — three new fields, one changed default

```swift
// changed
public var minLiftPlateauSec: TimeInterval = 0.6      // was 0.7

// new
public var strongShelfSec: TimeInterval = 1.05
public var flightCorroboration = true
public var shortShelfFlightM = 1.2
```

Set `flightCorroboration = false` and `minLiftPlateauSec = 0.7` to get V16.3
behaviour back for an A/B on a device.

---

## 2. The short-shelf gate — deferred instead of decided

Was:

```swift
if shelf < cfg.shelfFullSec && apex < cfg.shortShelfApexM {
    if !forced { return false }
    onDebug(now, "REJECT ... reason=shortShelfNoApex ...")
    return true
}
```

Now:

```swift
let needsCorroboration = shelf < cfg.shelfFullSec && apex < cfg.shortShelfApexM
if needsCorroboration {
    if !forced { return false }          // the shelf may still grow
    if !cfg.flightCorroboration {
        onDebug(now, "REJECT ... reason=shortShelfNoApex ...")
        return true
    }
    // otherwise fall through — the flight window gets a say below
}
```

`apex` here is the matched filter over the FIXED `[-apexPreSec, +apexPostSec]`
window, 4.5 s wide, and this gate runs BEFORE the landing is resolved. A 4.3–4.8 s
flight overflows that window and reads apex 0.00–0.19.

---

## 3. The deferred decision, immediately after `flightH`

```swift
if needsCorroboration {
    if flightH == nil || flightH! < cfg.shortShelfFlightM {
        onDebug(now, "REJECT t0=... reason=shortShelfNoApex shelf=... apex=... flight=...")
        return true
    }
}
```

Placed right after the flight height is computed and before the throw-scale
adjustment, so a candidate that the fixed window could not see is judged on the
measurement that V16.2 made primary.

The debug line now carries `flight=`, so a replay shows which of the two windows
rejected a candidate.

---

## 4. Distance suppressed without a landing

```swift
} else if let launch, let landingT {
    distanceM = launch.spd * (landingT - t0)
}
if landingT == nil { distanceM = nil }        // new
```

---

## 5. `confidence` reads an absolute shelf

```swift
confidence: shelf >= cfg.strongShelfSec ? 0.75 : 0.55   // was minLiftPlateauSec * 1.5
```

---

## The suite, before and after

```
                 V16.3                                V16.4
log     recall  emitted  phant  tallest      recall  emitted  phant  tallest
BENCH    3/4       3       0       —          3/4       3       0       —
SMALL   16/16     18       2     1.56 m      16/16     18       2     1.56 m
287     14/14     14       0       —         14/14     14       0       —
YANIV   20/24     25       5     3.72 m      23/24     29       6     3.72 m
NEG      0/0       0       0       —          0/0       0       0       —
CLEAN    3/4       3       0       —          4/4       4       0       —
V142     2/5       3       1     1.54 m       4/5       5       1     1.54 m

guarded recall     35/39   ->   38/39
pooled height MAE  0.292 m ->   0.282 m
tallest phantom    1.56 m  ->   1.56 m
```

`minRecall` moved 34 → 37 and `tallestPhantomM` stays at 1.7 to lock both in.

---

## Behaviour to expect on a device

**More emissions in the same session.** Yaniv goes from 25 to 29. Three of the
four extra ones pair with a Surfr jump; the fourth does not, and on a
minute-quantised reference that is not proof of a false positive.

**A jump can now be reported with no distance.** That is deliberate — see change 4.
The UI must render nothing there, not `0 m`.

**YANIV's height MAE rises 0.55 → 0.64 m in its own document, and that is not a
regression.** The four jumps added are precisely the hard ones — impulsive lift,
short shelf — so they measure worse than the session average. Comparing 23 jumps
against 19 is not comparing the same thing. Over the guarded suite, where pairing
is certain, pooled height *improved* to 0.282 m.
