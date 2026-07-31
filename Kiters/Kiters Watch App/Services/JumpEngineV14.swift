//
//  JumpEngineV14.swift
//  Kiters Watch App
//
//  V14 hybrid jump engine — IMU + pressure detection, on-demand absolute
//  altitude for height cross-checking.
//
//  ── Detection formula (all thresholds live in V14Config, nothing hidden) ──
//
//  RIDING (continuous):
//    • Rider baseline = rolling MEDIAN of relative (pressure) altitude over
//      `baselineWindowSec` (3–5 s). Median, not mean: a wrist dip into water
//      reads as a huge negative pressure spike (~8 m per cm of water) and
//      would drag a mean down by tens of metres; the median holds.
//    • Smoothed vertical load (gravity-projected acceleration, ~0.15 s window)
//      is tracked from the IMU.
//
//  TAKEOFF — a jump opens when:
//    IMU signature: smoothed load ≤ `unweightG` for at least
//    `unweightDutyCycleFraction` of the raw samples across `unweightSec`
//    (a preceding pop impulse ≥ `popG` within `popLeadSec` raises confidence;
//    it is a gate only when `requirePop` is true). The window tolerates
//    brief pops above the ceiling rather than requiring an unbroken streak:
//    a spinning takeoff injects transient noise into the gravity-projected
//    load even during genuine freefall (the fused gravity vector lags fast
//    wrist rotation), and a strict streak missed those jumps entirely.
//    Takeoff time = start of the unweight window (IMU-accurate).
//    The engine immediately asks the host to START the absolute-altitude
//    stream via `onAbsoluteWindowRequest(true, …)` — the stream runs ONLY from
//    detection until the landing baseline is confirmed stable.
//
//  AIRBORNE:
//    • Apex tracking: max relative altitude above the takeoff baseline, and
//      max absolute altitude from the on-demand window.
//    • Flight lasts exactly as long as the unweight does: touchdown is a
//      landing impact ≥ `landingImpactG`, or the smoothed load crossing back
//      above `flightLoadCeilingG` and holding for `flightEndHoldSec` — but
//      only once gyro has settled below `landingMaxGyroRadS`. A load spike
//      while still spinning hard is a mid-air impact (chop, a rotation
//      trick), not the touchdown; gating on it too keeps a rotating flight
//      from being cut to a few hundred ms by the first bump. Airtime is
//      therefore the measured low-load duration — an arm swing's brief dip
//      cannot inflate into seconds of phantom flight.
//    • `maxFlightSec` is the only duration ceiling (physical bound, visible).
//    • Violent gyro/load near takeoff flags `turbulentTakeoff` and applies a
//      stricter pressure/physics corroboration bar at finalize. This decision
//      is sensor-only and never consults GPS.
//
//  LANDING CONFIRM — the jump ends where a stable median baseline reappears:
//    relative-altitude samples after touchdown must span `landingStableSec`
//    and stay within `landingStableBandM`. Only then is the result emitted and
//    the absolute stream stopped (`onAbsoluteWindowRequest(false, …)`).
//    If the water stays choppy past `landingConfirmTimeoutSec` the jump is
//    still emitted with reduced confidence (documented, not hidden).
//
//  HEIGHT (cross-checked, no upper limit):
//    • heightRelative = apex relative altitude − pre-takeoff median baseline.
//    • heightAbsolute = max absolute in window − median of the post-landing
//      absolute samples. Used only when the channel is healthy: ≥ 2 distinct
//      values (an OS-frozen channel repeats one value bit-for-bit).
//    • Final height = absolute when healthy (authoritative for peak height),
//      else relative, else — `allowBallisticHeightFallback` — g·T²/8 from
//      airtime, reported with heightSource "ballistic".
//    • The user's "start counting height" setting (`minRiseM`, 1/1.5/2 m) is
//      part of the detection formula: a finalized arc below it is rejected.
//
//  GPS is metrics-only: speed/distance/coordinates may enrich the emitted
//  result, but never affect detection, timing, height, or confidence.
//

import Foundation

// MARK: - Config

public struct V14Config {
    // Detection formula — user-facing rise threshold (1 / 1.5 / 2 m picker).
    public var minRiseM = 1.0

    // Rider baseline (relative/pressure channel).
    public var baselineWindowSec = 4.0        // rolling median window, 3–5 s
    public var minBaselineSamples = 2

    // IMU takeoff signature.
    public var popG = 1.6                     // pre-jump impulse (confidence)
    public var popLeadSec = 0.8               // pop must precede unweight start
    public var requirePop = false             // impulse as hard gate (off: confidence only)
    public var unweightG = 0.75               // smoothed load ceiling while lifting off
    public var unweightSec = 0.35             // sustained unweight to open
    public var loadSmoothingSec = 0.15        // vertical-load moving average

    // A spinning takeoff injects transient noise into the gravity-projected
    // load estimate even during genuine freefall (the fused gravity vector
    // lags fast wrist rotation) — a strict unbroken low-load streak over
    // `unweightSec` misses real rotating jumps entirely. Once the window
    // elapses, accept it if at least this fraction of the raw samples inside
    // it were low, instead of requiring every single one to be.
    public var unweightDutyCycleFraction = 0.65

    // Landing. Flight ends when the load comes back: either an impact spike
    // or the smoothed load re-crossing the flight ceiling.
    public var landingImpactG = 1.9
    public var flightLoadCeilingG = 0.85      // smoothed load above this ends the flight
    public var flightEndHoldSec = 0.25        // crossing must hold; kite-tension jitter mid-flight does not land

    // A real landing coincides with rotation stopping — a load spike while
    // the rider is still visibly spinning (chop, a mid-air rotation trick)
    // is not the touchdown, just a transient impact. Impact/ceiling
    // touchdown only locks once gyro has settled below this rate.
    public var landingMaxGyroRadS = 6.0
    public var landingStableSec = 2.0         // stable median baseline confirms the end
    public var landingStableBandM = 0.6
    public var landingConfirmTimeoutSec = 6.0 // choppy water: emit anyway, lower confidence

    // Physical bounds (visible, documented — not tuning knobs).
    public var minAirtimeSec = 0.4
    public var maxFlightSec = 20.0
    public var retriggerGuardSec = 0.8

    // Water-artifact filter on the relative channel: a wrist dip reads as a
    // 20–400 m pressure step in one barometer tick, far beyond any real jump.
    // Steps larger than this are skipped; `relStepReacceptCount` consecutive
    // out-of-band samples re-accept the new level (legitimate datum shift).
    public var relStepRejectM = 10.0
    public var relStepReacceptCount = 3

    // Height fallback when both pressure channels fail mid-flight.
    public var allowBallisticHeightFallback = true

    // Height-measurement quality (relative-altitude-first layer, see
    // V14HeightAnalyzer). Initial conservative estimates — not yet
    // calibrated against replay logs; treat `isStable`/`heightConfidence`
    // as directional until a calibration pass (V14_RELATIVE_HEIGHT_UPGRADE_PLAN
    // phase 5) tunes them against real baro cadence and dip statistics.
    public var baselineStabilityVarianceM = 0.5
    public var baselineMaxGapSec = 5.0

    // Physical height ceiling per airtime: a kite only ever EXTENDS airtime
    // for a given height, so no real jump exceeds g·T²/8 by much. A channel
    // reading above ballistic × this factor is sensor noise and falls through
    // to the next height source. The absolute channel keeps a trust floor at
    // its own step-response scale: its arcs legitimately overshoot short hops
    // by ~2 m, so readings up to `absoluteTrustFloorM` are accepted on the
    // channel's own authority; beyond that the airtime must support them.
    public var maxHeightBallisticFactor = 1.3
    public var absoluteTrustFloorM = 2.5

    // Ballistic height is IMU timing alone — no pressure channel measured a
    // rise. Above `absoluteTrustFloorM` that is never accepted on its own: a
    // real jump that tall keeps the on-demand absolute window open in flight
    // and shows in the baro, so at least one pressure channel must have seen
    // this fraction of the ballistic height. Independently, a relative
    // channel that DID measure (baseline + flight max exist) and saw less
    // than the same fraction actively contradicts the airtime at any height —
    // the wrist unweighted but the watch never gained altitude (shakes,
    // arm swings).
    public var ballisticCorroborationFraction = 0.4

    // Takeoff turbulence gate — pure IMU. A ride jump leaves the water as a
    // smooth unweight: across the reference water log every takeoff stays
    // under 6 rad/s wrist rotation and 2.5g raw load in
    // [takeoff − takeoffScanBackSec, takeoff + takeoffScanForwardSec], while
    // shakes, drops and throws all exceed 9.5 rad/s or 4.3g in the same
    // window. Either bound breached means the unweight was violent wrist
    // motion, not a jump — the candidate never opens (or the flight aborts
    // inside the forward window).
    public var takeoffMaxGyroRadS = 8.0
    public var takeoffMaxLoadG = 4.0
    public var takeoffScanBackSec = 0.3
    public var takeoffScanForwardSec = 0.6

    // IMU double-integration height (4th source, between absolute and
    // ballistic): the fused gravity vector lags fast wrist rotation (see the
    // takeoff-turbulence comment above), which corrupts the raw vertical-load
    // signal this integrates — so it is only trusted when the whole flight
    // stayed calm. `imuIntegrationMaxGyroRadS` reuses the landing settle rate
    // as "calm"; a flight with faster rotation anywhere just skips this
    // source and falls through to ballistic, same as before this existed.
    public var imuIntegrationMaxGyroRadS = 6.0
    public var minImuIntegrationSamples = 10

    // History and GPS matching.
    public var historySec = 60.0
    public var gpsMatchToleranceSec = 2.5

    public init() {}
}

// MARK: - Result

public enum V14HeightSource: String {
    case relativeAltitude
    case absoluteAltitude
    /// Double integration of the measured vertical IMU load across the
    /// flight, boundary-corrected so the profile returns to the takeoff
    /// baseline at touchdown. Only attempted on a calm (non-rotating)
    /// flight — see `imuIntegrationMaxGyroRadS`.
    case imuIntegrated
    case ballistic
    /// No height source cleared the ceiling/corroboration checks. The jump
    /// itself was already confirmed by the IMU state machine (touchdown +
    /// landing baseline) — a height failure never deletes it.
    case unavailable
}

/// Why `heightSource == .unavailable` — diagnostic only, never a detection
/// gate. See V14_RELATIVE_HEIGHT_UPGRADE_PLAN.md §13.
public enum V14HeightFailureReason: String {
    case insufficientPreTakeoffSamples
    case unstableBaseline
    case missingApexSamples
    case invalidAltitudeDelta
    case noHeightSource
}

public struct V14Jump {
    public let heightM: Double
    public let heightRelativeM: Double?
    public let heightAbsoluteM: Double?
    public let heightSource: V14HeightSource
    public let heightFailureReason: V14HeightFailureReason?

    public let airtimeSec: Double
    public let takeoffT: TimeInterval
    public let landingT: TimeInterval
    public let apexT: TimeInterval

    public let baselineRelM: Double?
    public let peakAbsoluteM: Double?
    public let landingAbsoluteM: Double?

    public let popImpulseG: Double
    public let landingImpactG: Double
    public let peakG: Double
    public let maxGyroRadS: Double
    public let rotationTurns: Double

    public let takeoffSpeedMS: Double?
    public let landingSpeedMS: Double?
    public let distanceM: Double?
    public let launchLat: Double?
    public let launchLng: Double?
    public let landingLat: Double?
    public let landingLng: Double?

    /// Legacy single confidence value, derived from the two below for
    /// backward compatibility with existing UI/log consumers.
    public let confidence: Double
    /// Confidence the flight itself is a real jump (IMU signature quality —
    /// pop, landing confirmation, turbulence flags).
    /// Independent of whether height could be measured.
    public let detectionConfidence: Double
    /// Confidence in the measured height value specifically. Low/zero when
    /// `heightSource == .unavailable`, but the jump above is still real.
    public let heightConfidence: Double
    public let baselineQuality: Double?
    public let apexConfidence: Double?
    public let altitudeCoverage: Double?

    public let landingConfirmed: Bool
    public let emittedAtT: TimeInterval
}

public protocol JumpEngineV14Delegate: AnyObject {
    func jumpDetected(_ jump: V14Jump)
}

// MARK: - Engine

public final class JumpEngineV14 {
    public weak var delegate: JumpEngineV14Delegate?
    public var onDebug: (TimeInterval, String) -> Void = { _, _ in }
    /// Host hook for the on-demand absolute altimeter: `true` = start the
    /// stream (jump opened), `false` = stop it (landing baseline confirmed or
    /// candidate rejected). Fired at most once per transition.
    public var onAbsoluteWindowRequest: (Bool, String) -> Void = { _, _ in }

    private let cfg: V14Config

    private struct TimedValue {
        let t: TimeInterval
        let v: Double
    }

    private struct GpsPt {
        let t: TimeInterval
        let lat: Double
        let lng: Double
        let spd: Double
    }

    private struct Flight {
        let takeoffT: TimeInterval
        let baselineRelM: Double?
        let popImpulseG: Double
        let launchGPS: GpsPt?

        // Baseline diagnostics captured at candidate-open time from the same
        // pre-takeoff window `medianBaseline` reads — measurement-quality
        // metadata only, never fed back into the takeoff decision.
        let baselineSampleCount: Int
        let baselineVarianceM: Double
        let baselineMaxGapSec: Double

        var maxRelM: Double?
        var maxRelT: TimeInterval?
        var maxAbsM: Double?
        var maxAbsT: TimeInterval?
        var absSamples: [TimedValue] = []
        // Full-resolution relative-altitude trail during the flight, for
        // apex persistence/quality analysis. Aggregation only — does not
        // change maxRelM/maxRelT tracking.
        var relFlightSamples: [TimedValue] = []

        var peakG: Double = 0
        var maxGyro: Double = 0
        var rotationIntegral: Double = 0
        var lastImuT: TimeInterval?

        // Raw vertical-load samples for the IMU double-integration height
        // source. Collected only up to touchdown (see updateFlightIMU) —
        // post-touchdown load reflects landing dynamics, not free flight.
        var imuAccelSamples: [(t: TimeInterval, aUpMS2: Double)] = []

        var touchdownT: TimeInterval?
        var landingImpactG: Double = 0
        var ceilingCrossT: TimeInterval?

        // Set when the takeoff window is violent. Finalize demands stronger
        // height corroboration for these — the raw kinematic gate cannot tell
        // a hard-rotating trick from a wipeout, so pressure/physics evidence
        // takes over instead of discarding the candidate outright.
        var turbulentTakeoff = false
    }

    private enum Phase {
        case riding
        case airborne(Flight)
        case landingConfirm(Flight)
    }

    private var phase: Phase = .riding
    private var absoluteWindowOpen = false

    // Continuous channels.
    private var relHistory: [TimedValue] = []
    private var gpsHistory: [GpsPt] = []
    private var loadWindow: [TimedValue] = []
    // Short raw-IMU trail (|load|, gyro) for the takeoff turbulence scan —
    // long enough to cover scan-back plus the sustained-unweight latency.
    private var imuTrail: [(t: TimeInterval, load: Double, gyro: Double, signedLoad: Double)] = []
    private var smoothedLoad = 1.0
    private var lastPopT: TimeInterval = -.infinity
    private var lastPopG = 0.0
    private var unweightStartT: TimeInterval?
    private var relOutOfBandCount = 0
    private var lastLandingT: TimeInterval = -.infinity
    private var lastImuT: TimeInterval = -.infinity
    private var lastRelT: TimeInterval = -.infinity
    private var lastAbsT: TimeInterval = -.infinity
    private var lastGpsT: TimeInterval = -.infinity
    private var lastRejectDebug = ""

    public init(_ cfg: V14Config = V14Config()) {
        self.cfg = cfg
    }

    public func reset() {
        closeAbsoluteWindow(reason: "reset")
        phase = .riding
        relHistory.removeAll(keepingCapacity: true)
        gpsHistory.removeAll(keepingCapacity: true)
        loadWindow.removeAll(keepingCapacity: true)
        imuTrail.removeAll(keepingCapacity: true)
        smoothedLoad = 1.0
        lastPopT = -.infinity
        lastPopG = 0
        unweightStartT = nil
        relOutOfBandCount = 0
        lastLandingT = -.infinity
        lastImuT = -.infinity
        lastRelT = -.infinity
        lastAbsT = -.infinity
        lastGpsT = -.infinity
        lastRejectDebug = ""
    }

    // MARK: Inputs

    /// `verticalLoadG` is the gravity-projected load in g: ~1 at rest, ~0 in
    /// freefall, > 1 under pop/landing compression. The adapter computes it
    /// from userAcceleration·gravity so the engine stays platform-free.
    public func addIMU(t: TimeInterval, verticalLoadG: Double, gyroRadS: Double) {
        guard t.isFinite, verticalLoadG.isFinite, t > lastImuT else { return }
        lastImuT = t

        imuTrail.append((t: t, load: abs(verticalLoadG), gyro: gyroRadS, signedLoad: verticalLoadG))
        let trailHorizon = cfg.takeoffScanBackSec + cfg.unweightSec + 2.0
        while let first = imuTrail.first, first.t < t - trailHorizon {
            imuTrail.removeFirst()
        }

        updateSmoothedLoad(t: t, loadG: abs(verticalLoadG))
        let load = smoothedLoad

        if abs(verticalLoadG) >= cfg.popG {
            lastPopT = t
            lastPopG = max(lastPopG, abs(verticalLoadG))
        }

        switch phase {
        case .riding:
            trackTakeoff(t: t, load: load)

        case .airborne(var flight):
            updateFlightIMU(t: t, rawLoadG: abs(verticalLoadG), load: load, gyroRadS: gyroRadS,
                            signedLoadG: verticalLoadG, flight: &flight)
            // Forward half of the takeoff turbulence gate: the opening of a
            // real flight is usually ballistic and quiet. A rider-initiated
            // rotation (kiteloop, board-off spin) can look just as violent as
            // a shake, so flag `turbulentTakeoff` for stricter sensor-only
            // corroboration at finalize instead of using GPS or hard-rejecting.
            if t - flight.takeoffT <= cfg.takeoffScanForwardSec,
               gyroRadS > cfg.takeoffMaxGyroRadS || abs(verticalLoadG) > cfg.takeoffMaxLoadG,
               !flight.turbulentTakeoff {
                flight.turbulentTakeoff = true
                onDebug(t, "TURBULENT flight flagged "
                    + "gyro=\(fmt(gyroRadS)) load=\(fmt(abs(verticalLoadG)))")
            }
            phase = .airborne(flight)
            detectTouchdown(t: t, rawLoadG: abs(verticalLoadG), load: load, gyroRadS: gyroRadS)

        case .landingConfirm(var flight):
            updateFlightIMU(t: t, rawLoadG: abs(verticalLoadG), load: load, gyroRadS: gyroRadS,
                            signedLoadG: verticalLoadG, flight: &flight)
            phase = .landingConfirm(flight)
            confirmLandingIfStable(now: t)
            // A fresh unweight while the previous landing is still confirming
            // is the next jump: end the previous one now and track the new one.
            if case .landingConfirm(let pending) = phase, updateUnweight(t: t, load: load) {
                emit(flight: pending, emittedAt: t, landingConfirmed: false, via: "nextTakeoff")
                tryOpenTakeoff(t: t)
            } else if case .riding = phase {
                trackTakeoff(t: t, load: load)
            }
        }
    }

    /// Relative (pressure) altitude — the continuous channel. Feeds the rider
    /// baseline and the in-flight relative apex.
    ///
    /// Water-artifact filter: a step beyond `relStepRejectM` from the last
    /// accepted sample is a submersion pressure spike, not motion — it is
    /// skipped so it can poison neither the median baseline nor the apex.
    /// `relStepReacceptCount` consecutive out-of-band samples re-accept the
    /// new level (a real datum shift settles; a dip bounces back).
    public func addRelativeAltitude(t: TimeInterval, altitudeM: Double) {
        guard t.isFinite, altitudeM.isFinite, t > lastRelT else { return }
        lastRelT = t

        if let lastAccepted = relHistory.last, abs(altitudeM - lastAccepted.v) > cfg.relStepRejectM {
            relOutOfBandCount += 1
            if relOutOfBandCount < cfg.relStepReacceptCount {
                rejectDebug(t, "RELSPIKE skip delta=\(fmt(altitudeM - lastAccepted.v)) n=\(relOutOfBandCount)")
                return
            }
            onDebug(t, "RELSPIKE reaccept level=\(fmt(altitudeM)) after=\(relOutOfBandCount)")
        }
        relOutOfBandCount = 0

        relHistory.append(TimedValue(t: t, v: altitudeM))
        pruneHistory(now: t)

        switch phase {
        case .riding:
            break

        case .airborne(var flight):
            flight.relFlightSamples.append(TimedValue(t: t, v: altitudeM))
            if flight.maxRelM == nil || altitudeM > flight.maxRelM! {
                flight.maxRelM = altitudeM
                flight.maxRelT = t
            }
            phase = .airborne(flight)

        case .landingConfirm:
            confirmLandingIfStable(now: t)
        }
    }

    /// Absolute altitude — only flows while the on-demand window is open.
    public func addAbsoluteAltitude(t: TimeInterval, altitudeM: Double) {
        guard t.isFinite, altitudeM.isFinite, t > lastAbsT else { return }
        lastAbsT = t

        switch phase {
        case .riding:
            break

        case .airborne(var flight):
            recordAbsolute(t: t, altitudeM: altitudeM, flight: &flight)
            phase = .airborne(flight)

        case .landingConfirm(var flight):
            recordAbsolute(t: t, altitudeM: altitudeM, flight: &flight)
            phase = .landingConfirm(flight)
        }
    }

    public func addGPS(t: TimeInterval, lat: Double, lng: Double, speedMS: Double) {
        guard t.isFinite, t > lastGpsT else { return }
        lastGpsT = t
        gpsHistory.append(GpsPt(t: t, lat: lat, lng: lng, spd: max(0, speedMS)))
        while let first = gpsHistory.first, first.t < t - cfg.historySec {
            gpsHistory.removeFirst()
        }
    }

    /// Session-end flush: a flight still waiting for its stable landing
    /// baseline is finalized as-is (confidence-penalized, landingConfirmed
    /// false); an open airborne candidate without touchdown is discarded.
    public func flush(now: TimeInterval) -> [V14Jump] {
        defer {
            phase = .riding
            closeAbsoluteWindow(reason: "flush")
        }

        switch phase {
        case .riding:
            return []
        case .airborne:
            onDebug(now, "REJECT reason=sessionEndedMidFlight")
            return []
        case .landingConfirm(let flight):
            if let jump = finalize(flight: flight, emittedAt: now, landingConfirmed: false, via: "flush") {
                return [jump]
            }
            return []
        }
    }

    // MARK: Takeoff

    /// Maintains the sustained-unweight tracker. Returns true once the
    /// window has lasted `unweightSec` AND stayed low enough for enough of
    /// it (see `unweightDutyCycleFraction`) — a rotating takeoff bounces the
    /// gravity-projected load estimate around even in genuine freefall, so a
    /// single noisy sample above the ceiling no longer cancels the window
    /// outright the way it used to.
    private func updateUnweight(t: TimeInterval, load: Double) -> Bool {
        if unweightStartT == nil {
            guard load <= cfg.unweightG else { return false }
            unweightStartT = t
            return false
        }

        let start = unweightStartT!
        guard t - start >= cfg.unweightSec else { return false }

        let windowSamples = imuTrail.filter { $0.t >= start && $0.t <= t }
        let lowCount = windowSamples.filter { $0.load <= cfg.unweightG }.count
        let dutyCycle = windowSamples.isEmpty ? 0 : Double(lowCount) / Double(windowSamples.count)

        if dutyCycle >= cfg.unweightDutyCycleFraction {
            // unweightStartT is left set to `start` — tryOpenTakeoff reads it
            // and is responsible for clearing it, same as the pre-existing
            // continuous-streak path did.
            return true
        }
        unweightStartT = load <= cfg.unweightG ? t : nil
        return false
    }

    private func trackTakeoff(t: TimeInterval, load: Double) {
        guard updateUnweight(t: t, load: load) else { return }
        tryOpenTakeoff(t: t)
    }

    private func tryOpenTakeoff(t: TimeInterval) {
        guard let start = unweightStartT else { return }

        guard t - lastLandingT >= cfg.retriggerGuardSec else {
            rejectDebug(t, "REJECT(candidate) reason=retriggerGuard")
            return
        }
        let popRecent = start - lastPopT <= cfg.popLeadSec
        if cfg.requirePop, !popRecent {
            rejectDebug(t, "REJECT(candidate) reason=noPopImpulse")
            return
        }

        // Backward half of the takeoff turbulence gate: scan the raw-IMU
        // trail from just before the unweight up to now. The forward half
        // continues inside the flight's opening window. A violent scan used
        // to hard-reject here — but a rider-initiated rotation (kiteloop,
        // board-off spin) throws the wrist just as hard as a chop impact
        // does, and the raw kinematic gate cannot tell them apart from a
        // pre-takeoff snapshot alone. So this half now matches the forward
        // gate's philosophy: flag `turbulentTakeoff` and let the flight
        // proceed — finalize()'s physics/height corroboration and the
        // landing-confirm state machine are what actually separate a real
        // (rotating) jump from a false trigger, not a 0.3 s backward window.
        var scanPeakGyro = 0.0
        var scanPeakLoad = 0.0
        for sample in imuTrail where sample.t >= start - cfg.takeoffScanBackSec {
            scanPeakGyro = max(scanPeakGyro, sample.gyro)
            scanPeakLoad = max(scanPeakLoad, sample.load)
        }
        let turbulentTakeoff = scanPeakGyro > cfg.takeoffMaxGyroRadS || scanPeakLoad > cfg.takeoffMaxLoadG
        if turbulentTakeoff {
            onDebug(t, "TURBULENT takeoff flagged gyro=\(fmt(scanPeakGyro)) load=\(fmt(scanPeakLoad))")
        }

        // GPS is metrics-only (distance/speed context on the emitted jump) —
        // it must never gate detection. A jump can genuinely launch at low
        // groundspeed (send off a wave, water-restart pop), and a stale or
        // low-accuracy fix within the match window shouldn't be trusted to
        // veto a real IMU-confirmed takeoff.
        let launchGPS = gpsPoint(near: start)

        let baseline = medianBaseline(before: start)
        let baselineDiag = baselineDiagnostics(before: start)
        // Backfill the IMU-integration accel trail from the true unweight
        // start (`start`), not from now (`t`) — the candidate only confirms
        // once the duty-cycle streak over `unweightSec` completes, by which
        // point real ascent has already happened. Anchoring the integration
        // at `t` instead of `start` silently skips that ascent and breaks
        // the "height returns to ~0 at touchdown" boundary assumption the
        // integration relies on. `imuTrail` already buffers this far back
        // for the turbulence scan, so no extra state is needed.
        let imuAccelBackfill: [(t: TimeInterval, aUpMS2: Double)] = imuTrail
            .filter { $0.t >= start && $0.t <= t }
            .map { (t: $0.t, aUpMS2: ($0.signedLoad - 1.0) * 9.80665) }
        let flight = Flight(
            takeoffT: start,
            baselineRelM: baseline,
            popImpulseG: popRecent ? lastPopG : 0,
            launchGPS: launchGPS,
            baselineSampleCount: baselineDiag.sampleCount,
            baselineVarianceM: baselineDiag.varianceM,
            baselineMaxGapSec: baselineDiag.maxGapSec,
            imuAccelSamples: imuAccelBackfill,
            turbulentTakeoff: turbulentTakeoff
        )
        unweightStartT = nil
        lastPopG = 0
        phase = .airborne(flight)
        openAbsoluteWindow(reason: "takeoff t=\(fmt(start))")
        onDebug(t, "CANDIDATE takeoff=\(fmt(start)) baseline=\(baseline.map(fmt) ?? "n/a") pop=\(popRecent)")
    }

    // MARK: Airborne

    private func updateFlightIMU(t: TimeInterval,
                                 rawLoadG: Double,
                                 load: Double,
                                 gyroRadS: Double,
                                 signedLoadG: Double,
                                 flight: inout Flight) {
        flight.peakG = max(flight.peakG, rawLoadG)
        flight.maxGyro = max(flight.maxGyro, gyroRadS)
        if let prev = flight.lastImuT, t > prev {
            flight.rotationIntegral += gyroRadS * (t - prev)
        }
        flight.lastImuT = t

        // Only collect while still pre-touchdown — this same function also
        // runs during .landingConfirm (landing dynamics, not free flight).
        // Uses the SIGNED load (not the abs() used elsewhere in this
        // function) — integration needs true direction, not magnitude.
        if flight.touchdownT == nil, signedLoadG.isFinite {
            flight.imuAccelSamples.append((t: t, aUpMS2: (signedLoadG - 1.0) * 9.80665))
        }
    }

    private func detectTouchdown(t: TimeInterval, rawLoadG: Double, load: Double, gyroRadS: Double) {
        guard case .airborne(var flight) = phase else { return }

        if t - flight.takeoffT > cfg.maxFlightSec {
            onDebug(t, "REJECT reason=maxFlightExceeded air=\(fmt(t - flight.takeoffT))")
            phase = .riding
            closeAbsoluteWindow(reason: "maxFlightExceeded")
            return
        }

        // A real landing coincides with rotation stopping. A load spike
        // while still spinning hard (chop, mid-air rotation) is a transient
        // impact, not the touchdown — without this, a rotating flight gets
        // cut to a few hundred ms by the first bump instead of running to
        // the actual landing.
        let rotationSettled = gyroRadS <= cfg.landingMaxGyroRadS

        if rawLoadG >= cfg.landingImpactG, rotationSettled {
            flight.touchdownT = t
            flight.landingImpactG = rawLoadG
            phase = .landingConfirm(flight)
            onDebug(t, "TOUCHDOWN impact=\(fmt(rawLoadG))g air=\(fmt(t - flight.takeoffT))")
            return
        }

        if load >= cfg.flightLoadCeilingG, rotationSettled {
            if flight.ceilingCrossT == nil { flight.ceilingCrossT = t }
            if let cross = flight.ceilingCrossT, t - cross >= cfg.flightEndHoldSec {
                flight.touchdownT = cross
                flight.landingImpactG = load
                phase = .landingConfirm(flight)
                onDebug(t, "TOUCHDOWN loadReturn air=\(fmt(cross - flight.takeoffT))")
                return
            }
        } else {
            flight.ceilingCrossT = nil
        }

        phase = .airborne(flight)
    }

    private func recordAbsolute(t: TimeInterval, altitudeM: Double, flight: inout Flight) {
        flight.absSamples.append(TimedValue(t: t, v: altitudeM))
        if flight.touchdownT == nil, flight.maxAbsM == nil || altitudeM > flight.maxAbsM! {
            flight.maxAbsM = altitudeM
            flight.maxAbsT = t
        }
    }

    // MARK: Landing confirm

    private func confirmLandingIfStable(now: TimeInterval) {
        guard case .landingConfirm(let flight) = phase,
              let touchdown = flight.touchdownT else { return }

        let window = relHistory.filter { $0.t >= touchdown }
        let spansEnough = (window.last?.t ?? touchdown) - touchdown >= cfg.landingStableSec
        let stable: Bool
        if window.count >= 2, spansEnough {
            let values = window.map(\.v)
            stable = (values.max()! - values.min()!) <= cfg.landingStableBandM
        } else {
            stable = false
        }

        if stable {
            emit(flight: flight, emittedAt: now, landingConfirmed: true, via: "stableBaseline")
        } else if now - touchdown >= cfg.landingConfirmTimeoutSec {
            emit(flight: flight, emittedAt: now, landingConfirmed: false, via: "confirmTimeout")
        }
    }

    private func emit(flight: Flight, emittedAt: TimeInterval, landingConfirmed: Bool, via: String) {
        phase = .riding
        lastLandingT = flight.touchdownT ?? emittedAt
        closeAbsoluteWindow(reason: via)

        if let jump = finalize(flight: flight, emittedAt: emittedAt, landingConfirmed: landingConfirmed, via: via) {
            delegate?.jumpDetected(jump)
            onDebug(emittedAt, "JUMP h=\(fmt(jump.heightM))m src=\(jump.heightSource.rawValue) "
                + "air=\(fmt(jump.airtimeSec))s conf=\(fmt(jump.confidence)) via=\(via)")
        }
    }

    // MARK: Finalize

    private func finalize(flight: Flight,
                          emittedAt: TimeInterval,
                          landingConfirmed: Bool,
                          via: String) -> V14Jump? {
        guard let touchdown = flight.touchdownT else { return nil }
        let airtime = touchdown - flight.takeoffT

        guard airtime >= cfg.minAirtimeSec else {
            rejectDebug(emittedAt, "REJECT reason=airtimeTooShort air=\(fmt(airtime)) via=\(via)")
            return nil
        }

        // Height, cross-checked across the three sources.
        let heightRelative: Double?
        if let baseline = flight.baselineRelM, let maxRel = flight.maxRelM, maxRel > baseline {
            heightRelative = maxRel - baseline
        } else {
            heightRelative = nil
        }

        let inFlightAbs = flight.absSamples.filter { $0.t < touchdown }
        let postLandingAbs = flight.absSamples.filter { $0.t >= touchdown }
        // Health must be judged on the in-flight samples themselves — a
        // channel that freezes for the whole flight and only recovers after
        // landing still shows ≥2 distinct values across the combined set
        // (frozen peak + a different post-landing anchor), which used to
        // pass this check and fabricate a height from one stale reading
        // against an unrelated anchor. A real barometric/GPS-fused stream
        // always shows some noise across 2+ in-flight samples; bit-identical
        // in-flight readings are the frozen-channel signature to catch.
        let distinctInFlightAbsValues = Set(inFlightAbs.map(\.v)).count
        let absoluteHealthy = distinctInFlightAbsValues >= 2 && !postLandingAbs.isEmpty
        let landingAbsolute = postLandingAbs.isEmpty ? nil : median(postLandingAbs.map(\.v))
        let heightAbsolute: Double?
        if absoluteHealthy, let peak = flight.maxAbsM, let anchor = landingAbsolute, peak > anchor {
            heightAbsolute = peak - anchor
        } else {
            heightAbsolute = nil
        }

        // IMU double-integration — a real measured profile, but the fused
        // gravity vector lags fast wrist rotation (same caveat as the
        // takeoff-turbulence gate), so it's only attempted on a flight that
        // stayed calm throughout, not just at takeoff.
        let heightImuIntegrated: Double?
        if !flight.turbulentTakeoff, flight.maxGyro <= cfg.imuIntegrationMaxGyroRadS {
            heightImuIntegrated = V14HeightAnalyzer.imuIntegratedApexHeightM(
                accelSamples: flight.imuAccelSamples,
                minSamples: cfg.minImuIntegrationSamples
            )
        } else {
            heightImuIntegrated = nil
        }

        let ballisticHeight = 9.80665 * airtime * airtime / 8.0

        // Physics cross-check: for a given airtime no real jump exceeds the
        // ballistic height (a kite only stretches airtime). A channel reading
        // above the ceiling is noise — fall through to the next source.
        let ballisticCeiling = ballisticHeight * cfg.maxHeightBallisticFactor
        func passesCeiling(_ h: Double?, ceiling: Double, _ label: String) -> Double? {
            guard let h else { return nil }
            guard h <= ceiling else {
                onDebug(emittedAt, "HEIGHT \(label)=\(fmt(h)) exceeds ceiling "
                    + "\(fmt(ceiling)) (air=\(fmt(airtime))) — discarded")
                return nil
            }
            return h
        }

        // Relative altitude is the primary height source (V14_RELATIVE_HEIGHT_
        // UPGRADE_PLAN.md §10): the flight is already confirmed by the IMU
        // state machine at this point, so height is a measurement question,
        // not a detection question. Absolute altitude — when the on-demand
        // window happened to catch a healthy channel — is an opportunistic
        // second-choice fallback, never a requirement; it is not preferred
        // over relative even when both are healthy.
        var heightFailureReason: V14HeightFailureReason?
        let height: Double
        let source: V14HeightSource
        if let h = passesCeiling(heightRelative, ceiling: ballisticCeiling, "relative") {
            height = h
            source = .relativeAltitude
        } else if let h = passesCeiling(heightAbsolute,
                                        ceiling: max(ballisticCeiling, cfg.absoluteTrustFloorM),
                                        "absolute") {
            height = h
            source = .absoluteAltitude
        } else if let h = passesCeiling(heightImuIntegrated, ceiling: ballisticCeiling, "imuIntegrated") {
            height = h
            source = .imuIntegrated
        } else if cfg.allowBallisticHeightFallback {
            // Combined-evidence guard for the IMU-only fallback. A flight
            // the forward turbulence gate flagged carries more false-positive
            // risk with zero pressure-channel evidence, so it must clear a
            // higher corroboration bar here. These two rejects are evidence-
            // calibrated false-positive filters on the candidate itself (the
            // physics contradicts a jump happened), not a measurement
            // failure on an accepted jump — they intentionally still reject.
            let corroborationFraction = flight.turbulentTakeoff
                ? cfg.ballisticCorroborationFraction * 1.5
                : cfg.ballisticCorroborationFraction
            let corroborationM = ballisticHeight * corroborationFraction
            let relativeRise: Double?
            if let baseline = flight.baselineRelM, let maxRel = flight.maxRelM {
                relativeRise = max(0, maxRel - baseline)
            } else {
                relativeRise = nil
            }
            if let relativeRise, relativeRise < corroborationM {
                rejectDebug(emittedAt, "REJECT reason=relativeContradictsBallistic "
                    + "relRise=\(fmt(relativeRise)) ballistic=\(fmt(ballisticHeight)) via=\(via)")
                return nil
            }
            let corroborated = (heightAbsolute ?? 0) >= corroborationM
                || (relativeRise ?? 0) >= corroborationM
            if ballisticHeight > cfg.absoluteTrustFloorM, !corroborated {
                rejectDebug(emittedAt, "REJECT reason=ballisticUncorroborated "
                    + "ballistic=\(fmt(ballisticHeight)) floor=\(fmt(cfg.absoluteTrustFloorM)) via=\(via)")
                return nil
            }
            height = ballisticHeight
            source = .ballistic
        } else {
            // No height source cleared the ceiling — but touchdown +
            // landing-confirm already happened above, i.e. the IMU state
            // machine already validated this as a jump. A measurement
            // failure must not delete it (V14_RELATIVE_HEIGHT_UPGRADE_PLAN.md
            // §13): emit with heightSource=.unavailable instead of REJECT.
            height = 0
            source = .unavailable
            heightFailureReason = flight.baselineRelM == nil
                ? .insufficientPreTakeoffSamples
                : .noHeightSource
            onDebug(emittedAt, "HEIGHT unavailable — jump kept, no source cleared ceiling via=\(via)")
        }

        // The user's counted-height setting is part of the formula, not a
        // display filter: below it the arc is not a counted jump. Only
        // applies to a measured height — an unavailable measurement cannot
        // be compared against it, and the jump is kept regardless (see above).
        if source != .unavailable {
            guard height >= cfg.minRiseM else {
                rejectDebug(emittedAt, "REJECT reason=belowMinRise h=\(fmt(height)) "
                    + "min=\(fmt(cfg.minRiseM)) src=\(source.rawValue) via=\(via)")
                return nil
            }
        }

        // The held absolute sample delivered at window-open can carry a stamp
        // slightly before takeoff; the apex itself is inside the flight.
        let rawApexT = flight.maxAbsT ?? flight.maxRelT ?? (flight.takeoffT + airtime / 2)
        let apexT = min(max(rawApexT, flight.takeoffT), touchdown)
        let landingGPS = gpsPoint(near: touchdown)
        let distance = gpsDistance(from: flight.launchGPS, to: landingGPS, airtime: airtime)

        let baseline = V14HeightAnalyzer.baselineQuality(
            sampleCount: flight.baselineSampleCount,
            varianceM: flight.baselineVarianceM,
            maxGapSec: flight.baselineMaxGapSec,
            minSamples: cfg.minBaselineSamples,
            stabilityVarianceM: cfg.baselineStabilityVarianceM,
            maxAllowedGapSec: cfg.baselineMaxGapSec
        )
        let apex = V14HeightAnalyzer.apexQuality(
            samples: flight.relFlightSamples.map { (t: $0.t, v: $0.v) },
            flightStart: flight.takeoffT,
            flightEnd: touchdown
        )
        if source == .unavailable, flight.baselineRelM != nil, !baseline.isStable {
            heightFailureReason = .unstableBaseline
        }
        let altitudeCoverage = flight.relFlightSamples.isEmpty ? 0.0 : min(1, Double(apex.sampleCount) / 5.0)

        // Detection confidence — the IMU signature quality alone, no height
        // terms. Independent of whether height could be measured.
        var detectionConfidence = 0.6
        if flight.popImpulseG > 0 { detectionConfidence += 0.05 }
        if !landingConfirmed { detectionConfidence -= 0.15 }
        if flight.turbulentTakeoff { detectionConfidence -= 0.1 }
        detectionConfidence = min(max(detectionConfidence, 0.05), 0.95)

        let heightConfidence = V14HeightAnalyzer.heightConfidence(source: source, baseline: baseline, apex: apex)

        // Legacy blended value for existing UI/log consumers — kept in the
        // same 0.05...0.95 range and shape as before (detection base, plus
        // up to ~0.25 credit for a well-measured height).
        let confidence = min(max(detectionConfidence + 0.25 * heightConfidence, 0.05), 0.95)

        return V14Jump(
            heightM: round2(height),
            heightRelativeM: heightRelative.map(round2),
            heightAbsoluteM: heightAbsolute.map(round2),
            heightSource: source,
            heightFailureReason: heightFailureReason,
            airtimeSec: round2(airtime),
            takeoffT: flight.takeoffT,
            landingT: touchdown,
            apexT: apexT,
            baselineRelM: flight.baselineRelM.map(round2),
            peakAbsoluteM: flight.maxAbsM.map(round2),
            landingAbsoluteM: landingAbsolute.map(round2),
            popImpulseG: round2(flight.popImpulseG),
            landingImpactG: round2(flight.landingImpactG),
            peakG: round2(flight.peakG),
            maxGyroRadS: round2(flight.maxGyro),
            rotationTurns: round2(flight.rotationIntegral / (2 * .pi)),
            takeoffSpeedMS: flight.launchGPS.map { round2($0.spd) },
            landingSpeedMS: landingGPS.map { round2($0.spd) },
            distanceM: distance.map(round2),
            launchLat: coordinate(flight.launchGPS)?.lat,
            launchLng: coordinate(flight.launchGPS)?.lng,
            landingLat: coordinate(landingGPS)?.lat,
            landingLng: coordinate(landingGPS)?.lng,
            confidence: confidence,
            detectionConfidence: detectionConfidence,
            heightConfidence: heightConfidence,
            baselineQuality: round2(baseline.quality),
            apexConfidence: round2(apex.confidence),
            altitudeCoverage: round2(altitudeCoverage),
            landingConfirmed: landingConfirmed,
            emittedAtT: emittedAt
        )
    }

    // MARK: Absolute window control

    private func openAbsoluteWindow(reason: String) {
        guard !absoluteWindowOpen else { return }
        absoluteWindowOpen = true
        onAbsoluteWindowRequest(true, reason)
    }

    private func closeAbsoluteWindow(reason: String) {
        guard absoluteWindowOpen else { return }
        absoluteWindowOpen = false
        onAbsoluteWindowRequest(false, reason)
    }

    // MARK: Helpers

    private func updateSmoothedLoad(t: TimeInterval, loadG: Double) {
        loadWindow.append(TimedValue(t: t, v: loadG))
        while let first = loadWindow.first, first.t < t - cfg.loadSmoothingSec {
            loadWindow.removeFirst()
        }
        smoothedLoad = loadWindow.reduce(0) { $0 + $1.v } / Double(loadWindow.count)
    }

    /// Rolling median of the relative channel over `baselineWindowSec` before
    /// `t`. nil until the window holds `minBaselineSamples` — takeoff can still
    /// open (IMU timing); height then comes from the relative/ballistic chain.
    private func medianBaseline(before t: TimeInterval) -> Double? {
        let values = relHistory
            .filter { $0.t >= t - cfg.baselineWindowSec && $0.t < t }
            .map(\.v)
        guard values.count >= cfg.minBaselineSamples else { return nil }
        return median(values)
    }

    /// Measurement-quality metadata over the same pre-takeoff window
    /// `medianBaseline` reads. Never influences the takeoff decision —
    /// consumed only by V14HeightAnalyzer for `heightConfidence`/
    /// `baselineQuality` diagnostics.
    private func baselineDiagnostics(before t: TimeInterval) -> (sampleCount: Int, varianceM: Double, maxGapSec: Double) {
        let samples = relHistory
            .filter { $0.t >= t - cfg.baselineWindowSec && $0.t < t }
            .sorted { $0.t < $1.t }
        guard !samples.isEmpty else { return (0, 0, 0) }
        let values = samples.map(\.v)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        var maxGap = 0.0
        for i in 1..<samples.count {
            maxGap = max(maxGap, samples[i].t - samples[i - 1].t)
        }
        return (samples.count, variance, maxGap)
    }

    private func pruneHistory(now: TimeInterval) {
        while let first = relHistory.first, first.t < now - cfg.historySec {
            relHistory.removeFirst()
        }
    }

    private func gpsPoint(near t: TimeInterval) -> GpsPt? {
        gpsHistory
            .filter { abs($0.t - t) <= cfg.gpsMatchToleranceSec }
            .min { abs($0.t - t) < abs($1.t - t) }
    }

    private func gpsDistance(from a: GpsPt?, to b: GpsPt?, airtime: Double) -> Double? {
        if let a, let b, coordinate(a) != nil, coordinate(b) != nil {
            return haversineM(a.lat, a.lng, b.lat, b.lng)
        }
        if let a {
            return a.spd * airtime
        }
        return nil
    }

    private func coordinate(_ p: GpsPt?) -> (lat: Double, lng: Double)? {
        guard let p, p.lat != 0 || p.lng != 0 else { return nil }
        return (p.lat, p.lng)
    }

    private func haversineM(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private func rejectDebug(_ t: TimeInterval, _ msg: String) {
        guard msg != lastRejectDebug else { return }
        lastRejectDebug = msg
        onDebug(t, msg)
    }

    private func round2(_ v: Double) -> Double {
        (v * 100).rounded() / 100
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}
