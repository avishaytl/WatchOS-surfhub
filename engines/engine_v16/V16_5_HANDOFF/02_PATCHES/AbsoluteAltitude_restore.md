# Restore absolute-altitude recording

## The finding

Two of the seven reference logs contain **zero** `absAlt` records, and the logs
name the cause themselves in a startup event:

```
287 / smallLog / CLEAN / V142   "Absolute altitude acquisition:
                                 continuous single-consumer, no watchdog restarts"
GAVRI / YANIV                   "Absolute altitude acquisition:
                                 onDemand (stream off until a jump window opens)"
```

`onDemand` cannot work. `CMAltimeter` needs time to settle after `start...`, and
a kite jump is over in four seconds. The outcome is not a reduced sample count —
it is nothing at all.

## The change

In `Kiters Watch App/Services/MotionManager.swift`, return the acquisition mode to
**continuous**. The implementation is already there and is good:

- `startAbsoluteAltitudeLocked(reason:)` — stream generations, so a restart
  cannot double-deliver
- `noteAbsoluteAltitudeLocked` — treats `accuracy >= 100` as Core Motion's
  re-anchor sentinel and ignores it for health purposes
- the health monitor that detects a stalled value and restarts

Nothing in that code needs fixing. It needs to be reached.

## Keep logging accuracy and precision

Both fields are already written per sample and both are load-bearing:

- **`precision` is the health flag.** 0.5 means the channel is live; 5 means Core
  Motion has degraded it and the value will repeat for tens of seconds. This is
  not our bug — verified against `lowPower` (0 % in both states), `thermal` (0),
  and battery (constant), with only 1–3 transitions per session.
- **`accuracy`** is Apple's own uncertainty estimate, ~1 sigma in metres. On our
  live samples it reads **4.7–9.6 m**.

## What it is for, and what it is not

**Not a height source.** Live during only 7 of 37 goldens; on log 287 frozen
during 12 of 14 jumps specifically. Where live: 0.89–1.75 m MAE against the IMU's
0.14–0.42 m. A "prefer the barometer when it agrees within 20 %" rule fires on 2
of 37 jumps and makes the error worse on both.

**A diagnostic channel.** Recording it is free and lets the question be
re-measured on future hardware. Its absence is why the two newest sessions cannot
answer it at all.

## Verification

A new field log should show a non-empty `absAlt` stream carrying `t`, `alt`,
`accuracy` and `precision`, at roughly 1–3 Hz, and the startup event should read
`continuous`.
