#!/usr/bin/env python3
"""Score a JumpReplay actual.json against the Surfr ground truth for
log_20260626_163255 (the 2026-06-26 session, 9 jumps per the Surfr app).

Surfr 'Time' column = takeoff time, seconds from session start.
Match window ±10s (Surfr time = takeoff, our detector spike often +0..+6s).
"""
import json, sys

# (surfr#, takeoffSec, heightM, airtimeS, distanceM)
GT = [
    (1, 1078, 1.26, 2.11, 13),
    (2, 1311, 1.90, 2.41, 23),
    (3, 1569, 1.71, 2.27, 0),
    (4, 1599, 2.03, 2.62, 0),
    (5, 1753, 2.16, 3.61, 0),
    (6, 1837, 2.49, 3.41, 0),
    (7, 1945, 1.86, 2.95, 0),
    (8, 2144, 2.03, 2.81, 9),
    (9, 2477, 1.96, 2.55, 16),
]
WIN = 10.0
NOISE_CUTOFF = 600.0  # first 10 min must have zero jumps

path = sys.argv[1] if len(sys.argv) > 1 else "output/log_20260626_163255_E04B8F70.actual.json"
rep = json.load(open(path))
acc = [j for j in rep["jumps"] if j["accepted"]]
acc.sort(key=lambda j: j["takeoffOffsetSec"])

used = set()
print(f"{'S#':<3}{'gtT':>6}{'ourT':>8}{'dt':>6}  {'h gt/our':>14} {'air gt/our':>14}")
matched = 0
for (n, t, h, air, dist) in GT:
    cand = [(i, j) for i, j in enumerate(acc) if i not in used and abs(j["takeoffOffsetSec"] - t) <= WIN]
    if not cand:
        print(f"{n:<3}{t:>6}{'--MISS--':>8}")
        continue
    i, j = min(cand, key=lambda x: abs(x[1]["takeoffOffsetSec"] - t))
    used.add(i)
    matched += 1
    dt = j["takeoffOffsetSec"] - t
    print(f"{n:<3}{t:>6}{j['takeoffOffsetSec']:>8.1f}{dt:>+6.1f}  "
          f"{h:>5.2f}/{j['height']:<6.2f} {air:>5.2f}/{j['airtime']:<6.2f}")

fp = [j for i, j in enumerate(acc) if i not in used]
noise_fp = [j for j in fp if j["takeoffOffsetSec"] < NOISE_CUTOFF]
print(f"\nGround truth jumps: {len(GT)}   matched: {matched}   missed: {len(GT)-matched}")
print(f"Accepted total: {len(acc)}   false positives: {len(fp)}")
print(f"  of which in first 10 min (noise zone): {len(noise_fp)}")
print(f"\nRESULT recall={matched}/{len(GT)}  precision={matched}/{len(acc) if acc else 1}"
      f"  first10min_clean={'YES' if not noise_fp else 'NO ('+str(len(noise_fp))+')'}")
