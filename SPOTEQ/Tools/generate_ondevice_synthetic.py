#!/usr/bin/env python3
"""
Generate a synthetic on-device (watchOS SessionLogger) CSV log with 2 jumps.

This produces a CSV in the exact format written by SessionLogger.swift:
  idx,t,ax,ay,az,aM,gx,gy,gz,gM,gvX,gvY,gvZ,baro,baseBaro,spd,lowG,state,evt

Where:
  - ax/ay/az  : user-acceleration in g (gravity removed)
  - gx/gy/gz  : gyroscope in rad/s
  - gvX/gvY/gvZ : gravity unit-vector in g  (|g| ≈ 1)
  - baro      : barometric pressure in hPa
  - t         : seconds from session start (0.0, 0.020, 0.040, ...)
  - state     : IDLE / RIDING / AIRBORNE / COOLDOWN
  - spd       : GPS speed in m/s

Two jumps:
  jump 1: takeoff @ 30s,  height ≈ 2.5 m
  jump 2: takeoff @ 90s,  height ≈ 4.0 m
"""

import math, random

random.seed(7)

# ── Config ────────────────────────────────────────────────────────────────────
DURATION_S   = 150.0
DT           = 0.020          # 50 Hz
G            = 9.81
BASE_BARO    = 1013.25        # hPa sea-level
BARO_M_PER_HPA = 8.3          # metres / hPa
RIDING_SPEED = 8.5            # m/s (above minSpeed threshold of ~4.17)

JUMPS = [
    # (takeoff_t_s, height_m)
    (30.0, 2.5),
    (90.0, 4.0),
]

# Compute airtime from height: t_air = 2*sqrt(2h/g)
def airtime(h):
    return 2 * math.sqrt(2 * h / G)

# Pre-compute jump intervals
jump_intervals = []
for (t0, h) in JUMPS:
    air = airtime(h)
    jump_intervals.append((t0 - 0.06, t0, t0 + air, t0 + air + 0.08))
    # phases: pre-impulse, takeoff, airborne, landing

def noise(scale):
    return random.gauss(0, scale)

lines = []
idx = 0
t = 0.0
low_g_count = 0
base_baro_rolling = BASE_BARO

# Header comments (matching SessionLogger format)
lines.append("# SPOTEQ Session Log")
lines.append("# session: synth001")
lines.append("# date: 20260602_165920")
lines.append("# mode: Standard")
lines.append("# devMode: false")
lines.append("# sampleRate: 50 Hz")
lines.append("# --- 6 Parameters ---")
lines.append("# minSpeed(m/s): 4.17")
lines.append("# takeoffG(g): 1.50")
lines.append("# landingG(g): 2.00")
lines.append("# minAirtime(s): 0.50")
lines.append("# maxAirtime(s): 8.00")
lines.append("# cooldown(s): 1.50")
lines.append("# --- Columns ---")
lines.append("# ax/ay/az = userAcceleration (g, gravity removed)")
lines.append("# gx/gy/gz = gyroscope (rad/s)")
lines.append("# gvX/gvY/gvZ = gravity vector (g)")
lines.append("# baro = barometric pressure (hPa)")
lines.append("# baseBaro = rolling baseline pressure (hPa)")
lines.append("# spd = GPS speed (m/s)")
lines.append("# lowG = consecutive low-g sample count")
lines.append("# -----------------------")
lines.append("idx,t,ax,ay,az,aM,gx,gy,gz,gM,gvX,gvY,gvZ,baro,baseBaro,spd,lowG,state,evt")

while t <= DURATION_S:
    idx += 1

    # Determine phase
    state = "RIDING"
    evt   = ""
    ax_g  = noise(0.08)
    ay_g  = noise(0.08)
    az_g  = noise(0.08)
    gx_r  = noise(0.05)
    gy_r  = noise(0.05)
    gz_r  = noise(0.05)
    baro  = BASE_BARO + noise(0.05)
    spd   = RIDING_SPEED + noise(0.3)

    for (pre_t, tk, land_t, post_t) in jump_intervals:
        if pre_t <= t < tk:
            # Build-up / takeoff impulse
            az_g  = 2.5 + noise(0.3)   # strong upward accel in g (>takeoffG 1.5)
            gx_r  = noise(0.2)
            evt   = "TAKEOFF_SPIKE" if abs(t - tk) < DT * 2 else ""
            state = "RIDING"
            break
        elif tk <= t < land_t:
            # Airborne: near free-fall (low-g)
            h_frac = (t - tk) / (land_t - tk)
            h      = JUMPS[jump_intervals.index((pre_t, tk, land_t, post_t))][1]
            cur_h  = 4 * h * h_frac * (1 - h_frac)   # parabolic height
            dp     = cur_h / BARO_M_PER_HPA
            baro   = BASE_BARO - dp + noise(0.02)
            ax_g   = noise(0.05)
            ay_g   = noise(0.05)
            az_g   = noise(0.05)   # near zero (free-fall)
            gx_r   = noise(0.8)    # rotation while airborne
            gy_r   = noise(0.6)
            gz_r   = noise(0.4)
            spd    = RIDING_SPEED + noise(0.1)
            low_g_count += 1
            state  = "AIRBORNE"
            break
        elif land_t <= t < post_t:
            # Landing impulse
            az_g  = -(3.5 + noise(0.4))   # downward impact in g (>landingG 2.0)
            state = "AIRBORNE"
            evt   = "HARD_LAND" if abs(t - land_t) < DT * 2 else ""
            low_g_count = 0
            break
        elif post_t <= t < post_t + 1.5:
            # Cooldown
            state = "COOLDOWN"
            low_g_count = 0
            break
    else:
        low_g_count = 0

    aM = math.sqrt(ax_g**2 + ay_g**2 + az_g**2)
    gM = math.sqrt(gx_r**2 + gy_r**2 + gz_r**2)

    # Gravity vector (unit vector pointing down in g)
    gvX =  0.0 + noise(0.01)
    gvY =  0.0 + noise(0.01)
    gvZ = -1.0 + noise(0.01)   # watchOS: gravity points toward earth = negative Z

    # Slow-drift rolling baseline
    base_baro_rolling = 0.999 * base_baro_rolling + 0.001 * baro

    def f(v): return f"{v:.3f}"

    row = (
        f"{idx},{t:.3f},"
        f"{f(ax_g)},{f(ay_g)},{f(az_g)},{f(aM)},"
        f"{f(gx_r)},{f(gy_r)},{f(gz_r)},{f(gM)},"
        f"{f(gvX)},{f(gvY)},{f(gvZ)},"
        f"{baro:.2f},{base_baro_rolling:.2f},"
        f"{spd:.2f},{low_g_count},{state},{evt}"
    )
    lines.append(row)

    t = round(t + DT, 6)

output = "\n".join(lines) + "\n"
import os
out_path = os.path.join(os.path.dirname(__file__), "../logs/log_ondevice_synthetic.csv")
with open(out_path, "w") as fh:
    fh.write(output)

print(f"Written {idx} samples ({DURATION_S}s @ 50Hz), 2 jumps.")
print(f"Output: {out_path}")
