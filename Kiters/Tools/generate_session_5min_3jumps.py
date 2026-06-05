#!/usr/bin/env python3
"""
Generate a physically-consistent 5-minute kitesurf session log with 3 jumps.

Output format matches the existing JSON logs (CoreMotion-style fields):
  - timestamp (ISO-8601 with microseconds)
  - accX/Y/Z      : raw accelerometer m/s² (gravity INCLUDED)
  - gravX/Y/Z     : gravity unit vector (|g|=1)
  - baro          : pressure hPa
  - gyrX/Y/Z      : gyro deg/s
  - gpsLat/Lon, gpsAcc(m), gpsSpeed(m/s)

Note: The Loader auto-detects this as `android` format. Android branch expects
linear (gravity-removed) accel. To match, we encode `acc = userLinearAccel`
(without gravity), keeping `grav` as the unit-vector. This is consistent with
the realistic_log.csv conventions already calibrated in the repo.

Three jumps are inserted at known times with stated heights:
  jump 1:  takeoff @ 70s , height 2.8 m
  jump 2:  takeoff @ 150s, height 6.5 m
  jump 3:  takeoff @ 240s, height 4.2 m

For each jump:
  airtime t = 2 * sqrt(2h/g)        (symmetric ballistic arc)
  takeoff impulse: ~3.5 g vertical for 60ms
  airborne phase : |linAccel| ≈ 0 (free fall) ± noise
  landing impulse: ~4 g vertical for 60ms
  baro dip       : Δp = h / 8.3 hPa, parabolic in time
  gyro           : moderate rotation rate

Outside jumps: rider is "riding" — small chop noise ~0.3 g, ~12 m/s GPS speed.
"""
import json
import math
import random
from datetime import datetime, timedelta

random.seed(42)

# ── Configuration ────────────────────────────────────────────────────────────
START_TIME = datetime(2026, 6, 2, 16, 59, 20, 970358)
DURATION_S = 300.0
RATE_HZ    = 50.0
DT         = 1.0 / RATE_HZ

JUMPS = [
    # (takeoff_t_s, height_m)
    ( 70.0, 2.8),
    (150.0, 6.5),
    (240.0, 4.2),
]

BASE_PRESSURE = 1013.25       # hPa, sea-level baseline
BARO_FACTOR   = 8.3           # m / hPa  (matches detector)
G             = 9.81

START_LAT = 32.840059
START_LON = 35.055326
HEADING   = math.radians(15)  # NNE
SPEED_MPS = 12.0

# ── Helpers ──────────────────────────────────────────────────────────────────

def isofmt(t: datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond:06d}"

def deg_per_meter(lat_deg: float):
    """Approximate degrees-per-meter at given latitude."""
    lat_rad = math.radians(lat_deg)
    m_per_deg_lat = 111_132.0
    m_per_deg_lon = 111_320.0 * math.cos(lat_rad)
    return 1.0 / m_per_deg_lat, 1.0 / m_per_deg_lon

DLAT_PM, DLON_PM = deg_per_meter(START_LAT)

# ── Jump kinematics ──────────────────────────────────────────────────────────

def jump_profile(h: float):
    """
    Returns a function f(tau) -> (vertAccel_g, baroDelta_hPa, jumpPhase)
    where:
      tau          = seconds from start of takeoff impulse
      vertAccel_g  = world-vertical USER acceleration (Apple CMDeviceMotion
                     convention: total - gravity), in g, positive = up.
                     - At rest                  →  0g
                     - Takeoff impulse (kite pop) → strong positive (peaks 4-6g)
                     - Free-fall (airborne)      → +1g UP (sensor reads 0,
                       gravity is removed from it; net = -gravity = +up)
                     - Landing impulse (decel)   → strong positive (peaks 4-6g)
      baroDelta_hPa= pressure drop relative to baseline (positive = dipped)
      phase        = 'takeoff' | 'airborne' | 'landing' | 'done'

    Impulse: half-sine over `impulse_dur` s. Peak chosen so ∫a dt = v0
    (apex velocity, v0 = sqrt(2·g·h)).
    """
    airtime     = 2.0 * math.sqrt(2.0 * h / G)
    v0          = math.sqrt(2.0 * G * h)
    impulse_dur = 0.30                       # 300 ms — kite-style smooth pop
    # Half-sine integrates to (peak * dur * 2/π) = v0  →  peak = v0·π/(2·dur)
    # That accelerates the rider from rest to v0. The takeoff impulse is the
    # USER acceleration on top of the +1g "free-fall offset" the sensor sees
    # immediately after liftoff (because gravity is removed from a zero raw).
    # We add the +1g offset so the impulse curve smoothly transitions into the
    # +1g airborne plateau.
    peak_a_g    = v0 * math.pi / (2.0 * impulse_dur) / G

    total_dur   = impulse_dur + airtime + impulse_dur
    delta_p_max = h / BARO_FACTOR

    def f(tau):
        if tau < 0 or tau > total_dur:
            return 0.0, 0.0, 'done'
        if tau < impulse_dur:
            # Takeoff: half-sine on top of 0g rest baseline → ramps up to peak,
            # back down to 0 at end of impulse, then airborne adds +1g step.
            shape = math.sin(math.pi * tau / impulse_dur)
            return peak_a_g * shape, 0.0, 'takeoff'
        tau_air = tau - impulse_dur
        if tau_air < airtime:
            # Free-fall: userAccel = -gravity = +1g UP (Apple convention).
            t = tau_air
            altitude = max(0.0, v0 * t - 0.5 * G * t * t)
            dp = (altitude / h) * delta_p_max
            return 1.0, dp, 'airborne'
        tau_land = tau_air - airtime
        if tau_land < impulse_dur:
            # Landing: half-sine on top of +1g airborne baseline (we are
            # decelerating downward velocity → strong positive userAccel).
            shape = math.sin(math.pi * tau_land / impulse_dur)
            return 1.0 + peak_a_g * shape, 0.0, 'landing'
        return 0.0, 0.0, 'done'

    return f, total_dur

def find_jump(t_s):
    for (t0, h) in JUMPS:
        prof, dur = jump_profile(h)
        if t0 <= t_s <= t0 + dur:
            return prof(t_s - t0)
    return 0.0, 0.0, 'idle'

# ── Generation ───────────────────────────────────────────────────────────────

def gen():
    n = int(DURATION_S * RATE_HZ)
    rows = []
    lat, lon = START_LAT, START_LON
    # Slow weather drift on baseline pressure (±0.3 hPa over 5 min)
    for i in range(n):
        t_s = i * DT
        ts  = START_TIME + timedelta(seconds=t_s)

        # Slow weather drift (sinusoidal, ±0.05 hPa)
        weather = 0.05 * math.sin(2 * math.pi * t_s / 240.0)

        vG_lin, dp, phase = find_jump(t_s)

        # World-vertical linear accel in g (positive = up)
        vert_lin_g = vG_lin

        # Baseline noise: small chop while riding
        if phase == 'idle':
            chop_g = random.gauss(0, 0.15)   # vertical chop
            horiz_g = (random.gauss(0, 0.10), random.gauss(0, 0.10))
            gyro_dps = (
                random.gauss(0, 25),
                random.gauss(0, 25),
                random.gauss(0, 25),
            )
        elif phase == 'takeoff':
            chop_g = random.gauss(0, 0.05)
            horiz_g = (random.gauss(0, 0.4), random.gauss(0, 0.4))
            gyro_dps = (random.gauss(0, 80), random.gauss(0, 80), random.gauss(0, 80))
        elif phase == 'airborne':
            chop_g = random.gauss(0, 0.02)   # very low noise in air
            horiz_g = (random.gauss(0, 0.05), random.gauss(0, 0.05))
            gyro_dps = (random.gauss(0, 60), random.gauss(0, 60), random.gauss(0, 60))
        elif phase == 'landing':
            chop_g = random.gauss(0, 0.10)
            horiz_g = (random.gauss(0, 0.6), random.gauss(0, 0.6))
            gyro_dps = (random.gauss(0, 100), random.gauss(0, 100), random.gauss(0, 100))
        else:
            chop_g = horiz_g = (0,)
            chop_g = 0; horiz_g = (0,0); gyro_dps = (0,0,0)

        total_vert_lin_g = vert_lin_g + chop_g

        # Gravity unit vector — small tilt simulation (board roll)
        # Riding: roughly upright (gravity ≈ (0, 0, -1))
        tilt_x = math.radians(random.gauss(0, 3))    # roll
        tilt_y = math.radians(random.gauss(0, 3))    # pitch
        gx = math.sin(tilt_x)
        gy = -math.sin(tilt_y) * math.cos(tilt_x)
        gz = -math.cos(tilt_x) * math.cos(tilt_y)
        gmag = math.sqrt(gx*gx + gy*gy + gz*gz)
        gx /= gmag; gy /= gmag; gz /= gmag

        # Linear acceleration in body frame
        # World-frame linear accel: (horiz_x, horiz_y, vert) in g
        # Project onto body frame: subtract from gravity tilt → simplest
        # (good enough for synthetic): treat body axes ≈ world here.
        ax_lin = horiz_g[0] * G
        ay_lin = horiz_g[1] * G
        az_lin = total_vert_lin_g * G   # positive = up in world

        # The Loader.android branch expects:
        #   accX/Y/Z = LINEAR accel (m/s², gravity removed)
        #   gravX/Y/Z = unit vector
        # And produces userAccel by dividing by g.
        # So we write linear accel directly here.
        accX = ax_lin
        accY = ay_lin
        # World-vertical positive = up. The watch is worn upright, so world-up
        # corresponds to body -gravZ (if gz≈-1). We want acc.az to read
        # +vertical-up when body is oriented with gravity along -z.
        # So az reading = vertical_lin (positive up)
        accZ = az_lin

        # Add small IMU bias / sensor noise
        accX += random.gauss(0, 0.05)
        accY += random.gauss(0, 0.05)
        accZ += random.gauss(0, 0.05)

        # Pressure
        pressure = BASE_PRESSURE + weather - dp
        # Sensor noise
        pressure += random.gauss(0, 0.02)

        # GPS
        # Advance position
        speed = SPEED_MPS + random.gauss(0, 0.5)
        if phase == 'airborne':
            speed *= 0.95
        dist = speed * DT
        lat += dist * math.cos(HEADING) * DLAT_PM
        lon += dist * math.sin(HEADING) * DLON_PM
        gps_acc = max(2.0, random.gauss(5.0, 1.0))

        rows.append({
            "timestamp": isofmt(ts),
            "accX": round(accX, 6),
            "accY": round(accY, 6),
            "accZ": round(accZ, 6),
            "gravX": round(gx, 6),
            "gravY": round(gy, 6),
            "gravZ": round(gz, 6),
            "baro": round(pressure, 6),
            "gyrX": round(gyro_dps[0], 6),
            "gyrY": round(gyro_dps[1], 6),
            "gyrZ": round(gyro_dps[2], 6),
            "gpsLat": round(lat, 7),
            "gpsLon": round(lon, 7),
            "gpsAcc(m)": round(gps_acc, 6),
            "gpsSpeed(m/s)": round(speed, 6),
        })
    return rows


if __name__ == "__main__":
    import sys
    rows = gen()
    out = sys.argv[1] if len(sys.argv) > 1 else "logs/kitesurf_session_5min_3jumps.json"
    with open(out, "w") as f:
        json.dump(rows, f, separators=(",", ":"))
    print(f"wrote {len(rows)} rows → {out}")
    print(f"jumps:")
    for (t0, h) in JUMPS:
        airtime = 2.0 * math.sqrt(2.0 * h / G)
        dp = h / BARO_FACTOR
        print(f"  t={t0:.1f}s  h={h}m  airtime={airtime:.2f}s  baroDip={dp:.3f}hPa")
