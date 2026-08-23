# Apple Watch Real-Time Replay

The watch app contains a hardware-in-the-loop replay lab for production
`KSLG v2` session logs. It executes the selected production `JumpDetecting`
adapter on the watch CPU and watchOS runtime while replacing only the sensor
source.

## Architecture

```text
                            JumpDetecting
                                 ▲
                                 │
                         SensorProviderEvent
                       ┌─────────┴─────────┐
                       │                   │
              LiveSensorProvider   ReplaySensorProvider
                       │                   │
     Motion/Altimeter/Location        KSLG v2 log
```

`SessionManager` receives live IMU, altitude, GPS, and submersion data through
`LiveSensorProvider`. `ReplaySessionController` receives the same app-native
events from `ReplaySensorProvider` and forwards them to an unchanged detector
adapter (`V7` through `V15`).

Relevant files:

- `Services/SensorProvider.swift` — shared event boundary and live provider.
- `Services/ReplaySensorProvider.swift` — streaming KSLG decoder and replay clock.
- `Services/ReplaySessionController.swift` — detector runner, telemetry, and regression reports.
- `Views/ReplayLabView.swift` — watch controls and debug overlay.

## Timing and ordering guarantees

- Each KSLG record retains its recorded nanosecond timestamp.
- Records are emitted in file/arrival order.
- Different sensor streams keep their native cadence. There is no resampling,
  interpolation, or synthetic sample insertion.
- A fixed `ContinuousClock` origin is used for every play interval. Each
  deadline is calculated from the log timestamp and replay speed, rather than
  from the previous timer firing, so timer jitter does not accumulate.
- If records are timestamped out of order, their order is not changed. A record
  whose deadline is already in the past is emitted immediately.
- Pause/resume creates a new clock anchor at the exact playhead.
- Seek rebuilds detector state deterministically from the beginning to the
  requested point before paced playback resumes. It never jumps over input the
  state machine would have consumed.

The replay parser scans records from mapped file data and holds only the latest
zero-order-held sensor values. It does not materialize hundreds of thousands
of decoded objects, which keeps long sessions within watch memory limits.

## Using the Replay Lab

1. Record a sensor or normal kitesurf session on the watch.
2. End the session so its `.kslog` is closed.
3. Open **Settings → Replay Lab**.
4. Select a session, detector engine, and `1×`, `2×`, `5×`, or `10×`.
5. Use Play, Pause, Stop, Restart, or Seek ±5 seconds.

At `1×`, the GUI, watch timers, memory pressure, and operating system scheduling
remain active for the original session duration. Faster modes are intended for
regression iteration after `1×` behavior has been verified.

## Telemetry and reports

Every delivered record is appended to a CSV under:

```text
Documents/replay_reports/
```

The CSV includes source timestamp, replay time, event type, IMU/load/gyro
values, pressure, relative and absolute altitude, baseline when exposed by an
engine debug event, FSM state, candidate status/score, jump height/confidence,
filter output, jump ID, and debug flags.

At completion, a deterministic JSON report is written to the same directory.
Jump fingerprints intentionally omit random UUIDs and absolute run dates. They
use the selected engine plus rounded takeoff, landing, height, airtime, and
confidence values. The report also stores the effective detector configuration
snapshot so a result can be traced to the exact thresholds used by that run.

Choose **Save regression baseline** after a trusted run. Later runs of the same
log and engine show whether their deterministic fingerprint matches or changed.
Rejected V14/V15 candidate reasons are included in the report.

## Supported input

On-watch replay accepts production `KSLG v2` logs. Legacy `KSLG v1`, CSV, and
JSON inputs remain supported by the macOS `Tools/JumpReplay` workflow but are
not loaded into the constrained watch runtime.

The KSLG v2 decoder understands the stream tags currently written by
`SessionLogger`: motion, raw acceleration, relative altitude/pressure, absolute
altitude, GPS, submersion, event, sync, system status, and V13 audit.

## Validation

Useful verification commands from the repository root:

```sh
xcodebuild -project SPOTEQ/SPOTEQ.xcodeproj \
  -target "SPOTEQ Watch App" \
  -sdk watchsimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build

swift run --package-path SPOTEQ/Tools/JumpReplay \
  JumpReplay --engine-e2e-selftest
```

The first command compiles both simulator architectures for the watch target.
The second exercises the shared production detector adapters and KSLG stream
loader using the existing replay fixtures.
