# Measured and rejected — do not retry blind

Each of these looked promising and was killed by data. Recorded so the next
engineer does not spend the same days.

| idea | result |
|---|---|
| V15 as a small-jump fallback | V15's RAW landing is worse than ours: 0.92 s vs 0.71 s on smallLog, 1.40 s vs 0.34 s on log 287. Its good airtime is `T = 0.25*measured + 0.75*3.4s` — 75 % constant. |
| V10/V7 engine | 3/16 recall with 19 phantoms on smallLog; 5/14 with height MAE 3.68 m on log 287. Its `f = 0.18` ascent fraction was fitted on 3–4 jumps from one session. |
| V10 `landingContactGyro` | Fires mid-flight — the wrist rotates during the jump. Airtime MAE 1.59 s vs our 0.71 s. |
| V10 adaptive release `mu + K*sigma` | Their own code documents the abandonment: riding chop inflates sigma and SUPPRESSES real take-offs. |
| V8 parabolic baro apex | 8/16 recall, 29 phantoms, 5.40 m reported against a 3.7 m reference. |
| V12 architecture | Detects the take-offs (yank 2.8 g) then rejects them: `belowMinHeight 0.20 m`. Independent confirmation that the barometer cannot see a 2–3 m jump on this hardware. |
| quadratic / cubic / sqrt / log height forms | All lose to linear under leave-one-SESSION-out: 1.22 / 3.20 / 1.49 / 1.44 against 1.10. |
| `apex / session a_z RMS` normaliser | LOSO 0.804 vs 1.099 — but the whole-session RMS is NOT causally available. Every causal variant evaporates (60 s window 0.983, session-so-far 1.138). |
| barometric fusion, Kalman, contradiction check | relAlt arrives at 0.36 Hz. A 3–6 s flight gets 1–2 samples. Nothing recovers it. |
| impulse (area) lift gate | Knife-edge on the real engine: margin 0.08 m/s^2*s between the lowest golden and the highest chop event. |
| GPS take-off speed gate | Works, deliberately not used: detection must never depend on GPS, or bench testing breaks. |
| lowering `popClusterSec` alone | Fixes the throws but costs log 287 0.519 -> 0.643 m. Refitting recovers 0.017. Hence `apexAnchorSec`. |
| airtime < 1.5 s as a phantom filter | Dormant — zero phantoms sit under 1.5 s on any current log. Kept as a floor only. |

## Reference-app notes

**HOOLAN is not ground truth.** On the four bench throws, where physics gives an
exact answer, HOOLAN over-reads by ~1.9x. Its own reported height/airtime pairs
are mutually inconsistent under ballistics: `h/T^2` spans 0.494-0.816 where a
projectile requires 1.226 exactly, in every throw.

**Their kite model is a rise-time model.** Across 30 kite goldens their
`h/T^2` sits at 0.19-0.22, i.e. `h = 0.5*g*(0.20*T)^2` — the ascent is ~20 % of
the flight because the canopy extends the descent. Our own V10, calibrated
independently against Surfr, landed on 0.18. Two independent measurements of the
same physical constant.

**A peer-reviewed videogrammetric study** (Sensors 2021, 21(24):8353) measured
Surfr at 0.51 m RMS and WOO3 at 0.70 m over 20 kiteboarding jumps, with ALL
systems over-reading (Surfr 75 %, WOO2 95 %, WOO3 90 %) and deviations passing
20 % of true height above 5 m. Our own RMS in the same 3.07-7.30 m band measured
0.51 m. We are at parity with the reference app, not behind it.
