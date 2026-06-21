# Watch V7 Replay Summary - 2026-06-19

This summary was generated with the current watchOS V7 algorithm after the GPS-aware stationary gate and live UI changes.

Commands used:

```bash
Kiters/Tools/JumpReplay/.build/debug/JumpReplay --output /tmp/kiters_replay_standard <log>
Kiters/Tools/JumpReplay/.build/debug/JumpReplay --no-gps --output /tmp/kiters_replay_nogps <log>
```

Important note: the current regular mode applies the background-noise gate when regular distance exists: distance `<30m`, rotations `0`, displayed airtime `<3s`, and height `<2m` are rejected together as noise. `--no-gps` has no regular distance, so the same low events may still appear in the no-GPS replay.

## Calibration Update - 2026-06-21

This section supersedes the count summary below. The watchOS V7 height calibration was updated to `kinematicCalibration = 1.25`, and the barometer smoothing was made more responsive (`medianHalfWindow = 3`, `lowPassAlpha1 = 0.45`, `lowPassAlpha2 = 0.30`). The physical barometer stream is still controlled by watchOS `CMAltimeter`; the app now keeps it on a separate queue and zero-order-holds the latest pressure onto the 50Hz IMU stream.

| Log | Regular jumps | No-GPS jumps | Max regular height m |
|---|---:|---:|---:|
| `log2` | 21 | 23 | 5.16 |
| `log_20260619_123224_61A41698` | 6 | 6 | 4.22 |
| `log_20260619_125840_E4422EF7` | 7 | 8 | 9.80 |
| `log_20260619_161142_00DC2259` | 6 | 6 | 8.51 |
| `log_20260619_181339_37987CFB` | 2 | 2 | 1.59 |
| `log_20260619_181518_CE0EFDD6` | 4 | 4 | 3.82 |
| `log_20260619_182742_B8F3B8E7` | 3 | 3 | 3.18 |
| `log_20260619_234938_78F4CE13` | 6 | 8 | 6.57 |

Latest 10-minute cloud log after the height calibration:

| # | t(s) | Height m | Airtime s | Phys air s | Conf | Rot | Dist regular m |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 25.69 | 2.09 | 2.98 | 4.08 | 54.6 | 0 | 32.6 |
| 1 | 44.84 | 4.94 | 4.58 | 6.32 | 69.5 | 0 | 50.2 |
| 2 | 60.87 | 6.57 | 5.29 | 7.32 | 54.1 | 2 | 57.9 |
| 3 | 75.24 | 6.00 | 5.05 | 6.91 | 53.9 | 2 | 55.4 |
| 4 | 92.00 | 5.56 | 4.86 | 6.69 | 53.2 | 3 | 53.3 |
| 5 | 101.26 | 2.17 | 3.04 | 4.18 | 68.4 | 2 | 33.3 |

## Count Summary

| Log | Regular jumps | No-GPS jumps |
|---|---:|---:|
| `log2.json` | 21 | 22 |
| `log_20260619_123224_61A41698.kslog` | 5 | 5 |
| `log_20260619_125840_E4422EF7.kslog` | 7 | 8 |
| `log_20260619_161142_00DC2259.kslog` | 6 | 6 |
| `log_20260619_181339_37987CFB.kslog` | 1 | 1 |
| `log_20260619_181518_CE0EFDD6.kslog` | 4 | 4 |
| `log_20260619_182742_B8F3B8E7.kslog` | 3 | 3 |
| `log_20260619_234938_78F4CE13.kslog` | 6 | 8 |

## log2.json

| # | t(s) | Height m | Airtime s | Phys air s | Conf | Rot | Dist regular m | Dist no-GPS m |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 43.37 | 2.47 | 3.62 | 4.99 | 84.3 | 1 | 0 | 0 |
| 1 | 112.09 | 1.36 | 2.69 | 3.69 | 69 | 1 | 3.1 | 0 |
| 2 | 132.1 | 3.17 | 4.1 | 5.63 | 69.5 | 0 | 51.6 | 0 |
| 3 | 148.55 | 3.66 | 4.41 | 6.03 | 69.6 | 0 | 55.5 | 0 |
| 4 | 321.03 | 1.62 | 2.93 | 4.03 | 54.5 | 0 | 36.5 | 0 |
| 5 | 437.84 | 3.06 | 4.03 | 5.61 | 69.6 | 0 | 48.4 | 0 |
| 6 | 484.5 | 3.37 | 4.23 | 5.81 | 54.6 | 0 | 54.1 | 0 |
| 7 | 491.87 | 4.24 | 4.74 | 6.49 | 62.6 | 0 | 58.3 | 0 |
| 8 | 558.66 | 1.6 | 3.46 | 4.77 | 69.6 | 0 | 41 | 0 |
| 9 | 646.24 | 1.6 | 3.08 | 4.23 | 100 | 0 | 43.8 | 0 |
| 10 | 681 | 2.55 | 3.68 | 5.03 | 54.4 | 0 | 49.9 | 0 |
| 11 | 706.12 | 2.92 | 3.05 | 4.19 | 84.6 | 0 | 38.8 | 0 |
| 12 | 743.76 | 2.88 | 3.91 | 5.37 | 69.5 | 0 | 46 | 0 |
| 13 | 882.41 | 1.34 | 2.67 | 3.67 | 62.4 | 0 | 36.3 | 0 |
| 14 | 981.74 | 3.33 | 4.2 | 5.74 | 69.6 | 0 | 43.8 | 0 |
| 15 | 1064.54 | 1.8 | 3.1 | 4.25 | 62.5 | 0 | 38.7 | 0 |
| 16 | 1281.82 | 4.6 | 2.57 | 3.5 | 77.5 | 0 | 39.6 | 0 |
| 17 | 1293.25 | 3.17 | 4.1 | 5.59 | 69.1 | 1 | 33.3 | 0 |
| 18 | 1350.53 | 2.95 | 2.93 | 4.02 | 76.8 | 1 | 33.2 | 0 |
| 19 | 1369.94 | 1.52 | 2.93 | 4.01 | 77.5 | 0 | 32.4 | 0 |
| 20 | 1410.17 | 1.69 | 2.93 | 4.05 | 76.8 | 1 | 35 | 0 |

No-GPS-only event rejected in regular mode by the background-noise gate: `1391.56s`, `1.26m`, `2.58s`, `rot=0`.

## log_20260619_123224_61A41698.kslog

| # | t(s) | Height m | Airtime s | Phys air s | Conf | Rot | Dist regular m | Dist no-GPS m |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 25.26 | 3.37 | 4.23 | 5.81 | 68.2 | 3 | 46.4 | 0 |
| 1 | 48.72 | 1.4 | 2.73 | 3.74 | 67.5 | 2 | 29.9 | 0 |
| 2 | 61.81 | 1.77 | 3.07 | 4.2 | 53.1 | 2 | 33.6 | 0 |
| 3 | 67.55 | 1.11 | 2.42 | 3.31 | 83.7 | 1 | 26.6 | 0 |
| 4 | 72.02 | 1.42 | 2.74 | 3.8 | 68.7 | 1 | 30.1 | 0 |

## log_20260619_125840_E4422EF7.kslog

| # | t(s) | Height m | Airtime s | Phys air s | Conf | Rot | Dist regular m | Dist no-GPS m |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 0 | 2.1 | 3.34 | 4.71 | 53.3 | 2 | 36.6 | 0 |
| 1 | 46.17 | 3.33 | 4.2 | 5.8 | 68.3 | 3 | 46.1 | 0 |
| 2 | 53.6 | 3.54 | 4.34 | 5.92 | 52.9 | 4 | 47.5 | 0 |
| 3 | 76.64 | 7.84 | 6.45 | 8.87 | 53.9 | 3 | 70.7 | 0 |
| 4 | 78.76 | 2.18 | 3.4 | 4.66 | 69.7 | 0 | 37.3 | 0 |
| 5 | 91.47 | 2.16 | 3.39 | 4.66 | 68 | 3 | 37.1 | 0 |
| 6 | 107.2 | 3.73 | 4.45 | 6.1 | 53.6 | 2 | 48.8 | 0 |
No-GPS-only event rejected in regular mode by the background-noise gate: `133.88s`, `1.33m`, `2.66s`, `rot=0`.

## log_20260619_161142_00DC2259.kslog

| # | t(s) | Height m | Airtime s | Phys air s | Conf | Rot | Dist regular m | Dist no-GPS m |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 31.06 | 6.81 | 6.02 | 8.23 | 53.4 | 4 | 6.4 | 0 |
| 1 | 53.59 | 5.89 | 5.59 | 7.73 | 52.7 | 5 | 0 | 0 |
| 2 | 61.92 | 4.21 | 4.73 | 6.52 | 54.3 | 1 | 3.4 | 0 |
| 3 | 76.99 | 2.43 | 3.59 | 4.92 | 52.3 | 4 | 4.6 | 0 |
| 4 | 89.69 | 3.68 | 4.42 | 6.15 | 53.7 | 2 | 14.4 | 0 |
| 5 | 96.58 | 3.3 | 4.19 | 5.72 | 54.8 | 0 | 4.4 | 0 |

## Cloud logs 2026-06-19 18:00-19:00

These three logs were pulled from the cloud into `cloud_logs_20260619_18_19/` and replayed with the same current watchOS V7 algorithm.

| Log | Regular jumps | No-GPS jumps |
|---|---:|---:|
| `log_20260619_181339_37987CFB.kslog` | 1 | 1 |
| `log_20260619_181518_CE0EFDD6.kslog` | 4 | 4 |
| `log_20260619_182742_B8F3B8E7.kslog` | 3 | 3 |

## log_20260619_181339_37987CFB.kslog

| # | t(s) | Height m | Airtime s | Phys air s | Conf | Rot | Dist regular m | Dist no-GPS m |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 3.24 | 1.27 | 2.6 | 3.6 | 82.7 | 2 | 4.3 | 0 |

## log_20260619_181518_CE0EFDD6.kslog

| # | t(s) | Height m | Airtime s | Phys air s | Conf | Rot | Dist regular m | Dist no-GPS m |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 58.55 | 2.39 | 3.56 | 4.9 | 67 | 4 | 0 | 0 |
| 1 | 90.36 | 3.06 | 4.03 | 5.51 | 68.9 | 2 | 0 | 0 |
| 2 | 90.36 | 1.16 | 2.48 | 3.4 | 69.4 | 0 | 0 | 0 |
| 3 | 131.83 | 1.17 | 2.5 | 3.42 | 66.5 | 3 | 0 | 0 |

Note: `log_20260619_181518_CE0EFDD6.kslog` currently has two accepted jumps with the same takeoff time around `90.36s`; this should be investigated as a possible double-detection/coalescing issue.

## log_20260619_182742_B8F3B8E7.kslog

| # | t(s) | Height m | Airtime s | Phys air s | Conf | Rot | Dist regular m | Dist no-GPS m |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 3.16 | 2.55 | 3.68 | 5.04 | 84 | 1 | 0 | 0 |
| 1 | 40.12 | 1.51 | 2.83 | 3.88 | 83 | 2 | 2.3 | 0 |
| 2 | 46.93 | 2.45 | 3.61 | 4.94 | 69.2 | 1 | 2.8 | 0 |

## Cloud latest 10 minutes - 2026-06-19 23:43-23:53 IDT

One log was found in the latest 10-minute cloud window and downloaded into `cloud_logs_latest_10min/`.

| Log | Regular jumps | No-GPS jumps | Duration s | Samples | Rate Hz |
|---|---:|---:|---:|---:|---:|
| `log_20260619_234938_78F4CE13.kslog` | 6 | 8 | 140.41 | 7071 | 50.35 |

## log_20260619_234938_78F4CE13.kslog

| # | t(s) | Height m | Airtime s | Phys air s | Conf | Rot | Dist regular m | Dist no-GPS m |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 25.69 | 1.67 | 2.98 | 4.08 | 54.6 | 0 | 32.6 | 0 |
| 1 | 44.84 | 3.96 | 4.58 | 6.32 | 69.5 | 0 | 50.2 | 0 |
| 2 | 60.87 | 5.26 | 5.29 | 7.32 | 54.1 | 2 | 57.9 | 0 |
| 3 | 75.24 | 4.8 | 5.05 | 6.91 | 53.9 | 2 | 55.4 | 0 |
| 4 | 92 | 4.45 | 4.86 | 6.69 | 53.2 | 3 | 53.3 | 0 |
| 5 | 101.26 | 1.74 | 3.04 | 4.18 | 68.4 | 2 | 33.3 | 0 |

No-GPS-only events rejected in regular mode by the background-noise gate: `19.13s`, `1.00m`, `2.31s`, `rot=0`; and `91.22s`, `1.13m`, `2.45s`, `rot=0`.
