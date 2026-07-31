# Jump Engine V8 — Plan, Research & Architecture

A ground-up redesign of kitesurf jump-height detection, derived from first
principles and validated against a real Surfr kite session
(`2026-06-12…4173200D`). Goal: **height accurate to ±20 cm**, plus airtime and
distance (accuracy not critical). Online API; analysis may finish a few seconds
(5–7 s) after landing.

> **Tests, actual results per log, every parameter (value + how it was set), and
> the detailed "what the AI must check and how" checklist live in
> [`TESTING_AND_VALIDATION.md`](./TESTING_AND_VALIDATION.md).** The full handover
> doc list for the Swift team is in [`HANDOVER_TO_SWIFT_TEAM.md`](./HANDOVER_TO_SWIFT_TEAM.md).

---

## 1. The physics of a kitesurf jump (what the algorithm must model)

A kite jump is **not** a ballistic throw. The rider:

1. **Rides fast** over choppy water — the wrist sees large, continuous *horizontal*
   chop accelerations the whole time (noise floor).
2. **Pulls the bar + pops** the board against the water — a sharp **upward**
   acceleration impulse (the take-off signature).
3. The **kite lifts** them off the water; they **rise** while also moving
   **downwind** (horizontal travel continues — GPS speed does *not* drop).
4. The kite **eases the descent** — a light glide, so the **fall is longer than
   the rise** (asymmetric arc; apex is *not* at the time midpoint).
5. **Soft landing**, keeps riding (no hard impact spike).

**Algorithmic consequences**
- Height must come from the **rise** (take-off → apex), since the glide only
  stretches the descent. `h = ½·g·t_rise²` *if* `t_rise` is clean — but it isn't.
- The apex is where **vertical velocity = 0**. Finding it is the core problem.
- Horizontal chop (σ ≈ 0.21 g) pollutes the IMU; the soft landing has no spike;
  GPS speed is useless as a jump gate.

---

## 2. Sensor reality (measured from the log, not assumed)

| sensor | finding | implication |
|---|---|---|
| gravity vector (fused attitude) | `|g|` = 1.000 always; rotates up to **970 °/s** during a pop | attitude is excellent → world-vertical projection is valid |
| vertical userAccel | net upward impulse to the apex = **0.02 m/s**; chop RMS **3.2 m/s²** | **the kite rise is NOT in the wrist accel** — see below |
| barometer | **0.36 Hz**, 0.08 m quantum; rise rate at the pop = **8.87 m/s** | the baro DOES carry the jump (matches physics); under-samples the apex |
| GPS speed | ~constant through a jump; **no lat/lng in the log** | not a jump gate; distance only via speed×airtime |

### The decisive finding (module 11)
For the biggest jump (baro 3.37 m) the physics needs a take-off vertical velocity
`v0 = √(2gh) = 8.13 m/s`. The **wrist accelerometer's** net upward impulse to the
apex integrates to **0.02 m/s** — essentially zero — while the chop noise walk
(0.78 m/s over the window) dwarfs it. The **barometer's** own rise rate is
**8.87 m/s** — exactly the physics. A kite lifts the rider in a smooth,
canopy-borne, elevator-like rise; the wrist feels almost no vertical acceleration.

→ **Double-integrating wrist accel can NEVER size a kite jump.** Height MUST come
from the **barometer**. The IMU only detects the jump (pop) and brackets it.
(Complementary-filter and RTS-smoother attempts confirmed this: any apparent
accuracy came from the baro term; the IMU term only added drift/noise.)

---

## 3. Architecture — offline analysis of a captured jump buffer

### 3.1 Online front-end (streaming, cheap)
A light **state machine** runs on the live stream and only decides *when a jump
is happening*, then hands a **buffer** to the offline analyser:

```
RIDING ──(pop: vertical-accel up-impulse ≥ THR while spd>min)──▶ AIRBORNE
AIRBORNE ──(back on water: low vertical accel sustained, alt≈0)──▶ analyse → RIDING
```

The buffer spans **pre-pop (~1 s) … landing + tail (~2 s)** so the offline pass
has the full arc plus baselines. Analysis may run a few seconds after landing.

### 3.2 Offline analyser (the math) — BARO-CENTRIC
Given §2, height is barometric. The pipeline (`jumpEngineV8.ts`):

1. **Robust baseline.** The rider is on the water ~90 % of the time, so a
   **high-pressure percentile** of `baro` over ±15 s is the true ambient "sea
   level" — immune to the brief jumps (a rolling *mean/median* gets pulled up by
   the jump and under-reads it). `alt(t) = (baseline − baro)·8.43`.
2. **Apex per jump** = local-max altitude, refined by **parabolic interpolation**
   through the 3 baro points around it (the true apex falls *between* the sparse
   0.36 Hz samples; the parabola recovers the lost peak).
3. **Airtime is DERIVED from height, not measured.** At 0.36 Hz the baro can't
   time a ~4 s arc, and the soft kite landing has no accel spike — a measured
   airtime is wildly unstable (5–13 s). Physics: a kite extends the descent
   (glide), so the airtime is a fixed multiple of the symmetric ballistic flight
   `2·√(2h/g)`. Fitted to Surfr: `airtime = kiteGlideFactor·2·√(2h/g)` with
   `kiteGlideFactor ≈ 2.63` → **airtime RMS 0.37 s** (vs 5–13 s from the bracket).
4. **Take-off pop** (world-vertical UP accel, one dot product against gravity) is
   used only to TIME the jump and as a confidence/diagnostic — never for height.
5. **Distance** = GPS speed × airtime (no lat/lng in the log; add it — §5).
6. **Gates:** height ≥ 1.5 m, airtime ≥ 2 s. **Caps must NOT clip real jumps:**
   the kite world record is ~**45 m / 20+ s airtime**, so `maxPlausibleHeightM =
   50 m` (NOT 30) and `maxAirTimeSec = 25 s` (bracket span). The separate
   hand-throw cap (`throwMaxHeightM ≈ 8 m`) is a different regime — don't confuse
   them. The `kiteGlideFactor` airtime model is fitted to small jumps and
   **under-reads Big Air** (45 m → 15.9 s vs the real 20+ s); for Big Air the
   baro measures airtime directly (a 45 m jump = 5.3 hPa over 16–20 s, well
   sampled even at 0.36 Hz) → take the airtime from the baro arc there.
7. **KITE-AWARE NOISE FILTER** (choppy-sea / standing artefacts). The baro at
   0.36 Hz can throw a stray 2–4 m "apex" when the rider is **standing / drifting
   / back at the beach** (a pressure wiggle with no riding), or on a one-sample
   sensor spike, or when the watch is **tumbled** (gyro saturates). A real kite
   jump launches **while planing**, so we require:
   - **run-up speed** ≥ 5 m/s in the 5 s before the apex (the decisive filter —
     it removed every spd≈0 false apex, which on the test log had out-read the
     real jumps);
   - **no sustained gyro saturation** (>0.4 s above 20 rad/s ⇒ a toss, not a glide);
   - baro neighbours corroborate the arc (soft — feeds confidence, doesn't gate,
     so a genuinely short jump with one baro point survives).
   On the test log this cut 16 raw apexes → 9 real riding jumps; throws/standing
   produce 0 (V8 is kite-specific).
   > **Rotation is NOT a discriminator** — a kite trick (board-off, spin,
   > handle-pass) rotates as hard as a tossed watch, so a gyro-based "tumble"
   > reject was removed (it would drop legit trick jumps). Standing/junk is
   > already handled by the run-up speed gate.

### 3.5 Throws — a separate ballistic path, SPEED-DISJOINT from kite
A **thrown watch** (rider standing, testing) flies ballistically and the baro
barely moves, so its height must come from **time-of-flight**, not the baro.
`detectThrows` (ON by default) runs a separate ballistic pass:
- **launch spike** (≥2.5 g) → **FIRST landing impact** (≥2.0 g) within a physical
  flight bound (**≤2.5 s** ≈ 7.7 m — a hand throw tops out here; a longer "flight"
  is a STANDING GAP between handling events, which would read as a false 12 m).
  First-landing (not last) keeps a throw-and-rest from inflating the airtime; the
  2.0 g landing threshold finds the real touchdown.
- height = `½·g·(0.5·airtime)²` (symmetric ballistic arc), capped at 12 m.
- **gated to STANDING speed** (≤3 m/s). Kite jumps require *planing* speed (≥5),
  so the two paths are **disjoint** — the throw path can NEVER fire during kite
  riding. (This is what protects the kite, not a free-fall test.)
- **No free-fall-window requirement** — a *spinning* throw has centripetal accel
  and no free-fall window, yet those are the realistic throws; the standing gate
  alone keeps the kite safe.

Measured: on the Hoolan throw session it detects **6 throws at the right times**
(matching Hoolan), airtimes 1.4–1.9 s, heights 2.5–4.6 m; on the kite session it
adds **0** ballistic detections (kite unchanged, 9 jumps). Throw HEIGHT is rough
(time-of-flight on a hand throw, and the wrist under-reads vs Hoolan's 3.9–8.8 m)
— but the user accepted that; detection + timing are solid. Disable with
`detectThrows: false` to keep V8 pure-kite. Hoolan/Surfr likely use a board/water
sensor for tighter throw heights.

*Result on the current 0.36 Hz log (top-4 by height, matched by rank — Surfr
shows only its top jumps): heights [4.05,3.82,3.38,3.17] vs [3.77,3.45,3.17,3.14]
→ **height RMS 0.26 m**, airtimes [4.78,4.65,4.37,4.23] vs [4.33,4.12,4.59,4.37]
→ **airtime RMS 0.37 s**. (Surfr's per-jump Time column couldn't be aligned to a
unique 4-subset — its intervals 177/223/375 s match no V8 subset — so comparison
is by rank, which is what Surfr's "top jumps" list invites.) This is the
sensor-limited ceiling; a ≥1 Hz baro is required for ≤0.20 m (§5).*

DSP used: rolling-percentile baseline, parabolic sub-sample apex, zero-phase EMA
(diagnostics). **No** quaternion EKF / Euler / matrix inversion needed — the OS
already fuses attitude, and integrating wrist accel is futile here (§2).

### 3.3.2 Multi-signal cross-validation (robust to a degraded barometer)
A real kite jump is coherent across independent channels; each agreeing channel
raises confidence, and a channel's ABSENCE never rejects (a trick jump moves the
hand, weakening the IMU channels — baro+speed already confirmed it):
1. **Baro dip** — height/apex (the essential gate).
2. **Calm window** — airborne, the wrist leaves the water so the chop (rolling
   std of |userAccel|) is QUIETER than this jump's run-up. Compared LOCALLY (arc
   vs run-up), not to a global baseline (smooth riding is globally quiet too).
   Gives an independent, baro-free airtime → survives a wet/wetsuit-covered baro.
3. **Bar-pull** — to launch, the rider pulls the bar hard toward the body and
   HOLDS it through the rip-out: a sustained elevated |userAccel| in the ~1 s
   before take-off (not a brief spike). Confirms take-off intent.
4. **Planing speed** — context (the essential gate, §3.3).
Confidence = sum of agreements. Fields `measuredAirtimeSec / airborneConfirmed /
barPullConfirmed` are surfaced for the dashboard. **Do NOT reject on airborne
rotation / hand movement** — tricks (board-offs, spins, handle-passes) move the
hand and change the gravity vector; that is a legitimate jump.

### 3.3 Why this beats V7
V7 used spike-to-spike airtime × a fixed ascent fraction — fragile because kite
airtime is decoupled from height (glide), and it tried to use the IMU for height
which §2 proves impossible. V8 reads the **actual apex** from the barometer, and
cross-validates with the IMU (calm window + bar-pull) for robustness.

---

## 4. Do we need…?
- **DSP filters:** yes — rolling median (baro baseline), zero-phase EMA (chop
  suppression on `a_v`), and the complementary/Kalman filter itself.
- **Matrices / vector rotation:** minimal — one dot product against the gravity
  unit vector per sample (world-up projection). No full quaternion EKF needed
  because the OS already fuses attitude (`|g|`=1.000).
- **Euler angles:** not needed (we work with the gravity unit vector directly).
- **Large offline buffer:** yes — a per-jump buffer (~6–10 s at 50 Hz ≈ 300–500
  samples) analysed after landing. Cheap.

---

## 5. Higher-rate sensors (the real accuracy ceiling)
The 50 Hz IMU + 0.36 Hz baro caps us near ~0.2 m. To go tighter and make airtime
exact, record on **Apple Watch S9/Ultra** via:
- **`CMBatchedSensorManager` — 800 Hz accel / 200 Hz gyro** → resolves the
  water-release and water-contact transients (exact airtime; sharper apex).
- **`CMWaterSubmersionManager`** (Ultra) → a *direct* out-of-water signal =
  ground-truth airtime bracket.
- Baro stays ~1 Hz (Apple-locked) — fusion remains necessary.
See `SENSOR_RESEARCH_S9_ULTRA.md`.

---

## 6. Deliverable (the function)
```
analyseJumps(stream, config) → JumpResult[]
  config: sample rates, thresholds, fusion gains
  JumpResult: { heightM (±0.2 m), airtimeS, distanceM, t, confidence }
```
- Online state machine detects jumps (≥1.5 m, ≥2 s).
- Per jump: run §3.2 offline; emit a few seconds after landing.

---

## 7. Plan of work
1. **[done]** Research modules `research/01–07` — sensor truth + fusion probe.
2. Tune the fusion (gains, median window, ZUPT) → lock ≤0.20 m on Surfr top-4.
3. Implement `jumpEngineV8.ts` (TS, dashboard mirror) with the §3 pipeline.
4. Streaming state-machine wrapper + buffer capture.
5. Port to Swift (`KitesurfJumpEngineV8.swift`), line-for-line.
6. Wire into `sessionAnalysis` + admin dashboard reference-compare.
7. Validate on both logs; document final params.
8. (Hardware) add 800 Hz / submersion capture path on Ultra.
