# Watch V8 Replay — Comparison vs V7 (2026-06-21)

All eight logs from [watch-v7-replay-summary-2026-06-19.md](watch-v7-replay-summary-2026-06-19.md)
were replayed through the new **V8 (baro-centric)** engine and compared against the V7 results.

## How V8 was run

V8 was added to the JumpReplay tool (`--engine v8`). Unlike V7 (a streaming FSM), V8 is a
**whole-session batch** detector — it runs `KitesurfJumpEngineV8.detectJumps` over the entire log
at once (its validated mode). Settings:

```bash
# V8 as configured for production (throws ON, the chosen default)
Kiters/Tools/JumpReplay/.build/debug/JumpReplay --engine v8 <log>
# V8 kite-only (throws OFF) — the apples-to-apples vs V7's kite detection
Kiters/Tools/JumpReplay/.build/debug/JumpReplay --engine v8 --no-throws <log>
# Diagnostics (baro spread / GPS speed coverage)
Kiters/Tools/JumpReplay/.build/debug/JumpReplay --engine v8 --no-throws --verbose <log>
```

- Accept gate: `confidence ≥ 0.40` (same gate the watch `JumpDetectorV8` adapter uses).
- Default V8 params (`detectThrows = true`, `minJumpHeightM = 1.5`, `jumpRunUpSpeed = 5.0`).
- **Real log GPS speeds only** — no mock 8 m/s GPS (V7's summary used mock speed when a log had no
  GPS, which inflated its distances; V8 here uses only the data actually in the log).

## Headline finding

**V8 reproduces its documented validation, and nothing more — by design.**

V8 deliberately derives kite-jump height from the **barometer only** (never from wrist
acceleration). It therefore detects kite jumps **only on logs that actually contain a barometric
altitude signal**. Of the eight logs, only `log2.json` (the real Surfr kite session) has that
signal; the rest are flat-baro hand/bench test logs.

- **`log2.json` (kite session):** V8 finds **9 clean barometric jumps**, including the big air at
  **t=1285 s → 3.82 m / 4.65 s**, which matches the handover's Surfr reference (3.77 m / 4.33 s).
- **`log_..._00DC2259` (watch-throw test):** V8's ballistic throw path finds **6 throws at
  t≈10, 37, 59, 68, 80, 94 s** — exactly the validation in `HANDOVER_TO_SWIFT_TEAM.md`.
- **All other logs:** **0 kite jumps** (kite-only). With throws ON, V8's ballistic path fires on
  riding/hand chop and produces noise (see the per-log note).

## Count comparison

| Log | V7 jumps | V7 max h (m) | V8 kite-only | V8 (throws ON) | V8 max h (m) |
|---|---:|---:|---:|---:|---:|
| `log2.json` (kite, real GPS+baro) | 21 | 5.16 | **9** | 9 | 3.82 |
| `log_..._00DC2259` (throw test) | 6 | 8.51 | 0 | **6** ✓ | 4.52 |
| `log_..._61A41698` | 6 | 4.22 | 0 | 6 (noise) | 2.07 |
| `log_..._E4422EF7` | 7 | 9.80 | 0 | 12 (noise) | 7.19 |
| `log_..._37987CFB` | 2 | 1.59 | 0 | 1 (noise) | 1.95 |
| `log_..._CE0EFDD6` | 4 | 3.82 | 0 | 6 (noise) | 4.91 |
| `log_..._B8F3B8E7` | 3 | 3.18 | 0 | 1 (noise) | 1.59 |
| `log_..._78F4CE13` (cloud 10-min) | 6 | 6.57 | 0 | 7 (noise) | 2.91 |

✓ = matches the documented V8 validation.

## Why the zeros — sensor diagnostics

The kite path needs a real barometric rise (≥1.5 m apex) and run-up speed ≥5 m/s. The logs simply
don't have it (1 hPa ≈ 8.4 m, so 0.1 hPa spread ≈ 0.8 m over the **whole session** — noise floor):

| Log | Baro spread (hPa) | ≈ altitude span | Max GPS speed (m/s) | V8 kite verdict |
|---|---:|---:|---:|---|
| `log2.json` | **3.650** | **~30 m** | 11.26 | ✅ real kite signal → 9 jumps |
| `log_..._00DC2259` | 0.200 | ~1.7 m | 4.09 | flat baro (throws instead) |
| `log_..._61A41698` | 0.080 | ~0.7 m | 0.00 | flat baro, no GPS |
| `log_..._E4422EF7` | 0.160 | ~1.3 m | 0.00 | flat baro, no GPS |
| `log_..._37987CFB` | 0.070 | ~0.6 m | 1.22 | flat baro |
| `log_..._CE0EFDD6` | 0.150 | ~1.3 m | 3.57 | flat baro |
| `log_..._B8F3B8E7` | 0.140 | ~1.2 m | 0.92 | flat baro |
| `log_..._78F4CE13` | 0.110 | ~0.9 m | 0.00 | flat baro, no GPS |

V7 still reports jumps on these logs because it falls back to a **kinematic (accelerometer
time-of-flight)** height — which V8 intentionally rejects as physically unreliable for kite jumps.

## `log2.json` — V8 detail (the one valid kite comparison)

| # | t(s) | Height m | Airtime s | Conf | Source |
|---:|---:|---:|---:|---:|---|
| 0 | 682.56 | 1.77 | 3.16 | 78 | barometric |
| 1 | 759.47 | 1.70 | 3.10 | 50 | barometric |
| 2 | 913.34 | 2.54 | 3.78 | 94 | barometric |
| 3 | 1031.33 | 3.17 | 4.23 | 70 | barometric |
| 4 | **1285.14** | **3.82** | **4.65** | 90 | barometric |
| 5 | 1305.65 | 2.07 | 3.41 | 78 | barometric |
| 6 | 1374.89 | 2.21 | 3.53 | 75 | barometric |
| 7 | 1436.43 | 1.84 | 3.22 | 47 | barometric |
| 8 | 1451.82 | 1.77 | 3.16 | 43 | barometric |

vs V7 on the same log: 21 jumps, max 5.16 m. V8 is **more conservative** (9 vs 21) and reports
**lower, baro-grounded heights** (max 3.82 m vs 5.16 m). On the best-sampled big air the two agree
closely (V8 3.82 m @1285 s ≈ V7 4.60 m @1281.8 s), and V8 matches the Surfr ground truth (3.77 m).
The smaller jumps V8 under-reports because the session barometer is only ~0.36 Hz (sub-Nyquist for a
4 s arc), exactly as called out in the V8 handover.

## Conclusion

- On the **one real kite log with a working barometer** (`log2.json`), V8 produces clean,
  conservative, baro-grounded jumps and nails the Surfr-validated big air — its intended behavior.
- On **hand/bench test logs with a flat barometer**, V8 finds no kite jumps (correctly, per its
  design) and its throw path fires — accurately on the real throw test (`00DC2259`), as noise on the
  others. This confirms the trade-off discussed when enabling throws.
- A like-for-like count comparison vs V7 across all logs isn't meaningful, because most of these
  logs lack the barometric (and GPS) signal V8 requires. **To properly evaluate V8 against V7 we
  need new on-water logs recorded with ≥1 Hz barometer + GPS** (per `NEXT_LOG_RECORDING_SPEC.md`).
