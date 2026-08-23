//
//  JumpEngineV15.swift
//  SPOTEQ Watch App
//
//  V15-FIX APPLIED (research/fabel5/V15_FIX_SPEC_HE.pdf, 20.7.2026):
//    F1 rescue over local-maxima pop clusters, capped attempts (792-event spam
//       -> loggerQueueBacklog on 20.7).
//    F2 noRiseAbort consults only non-disturbed channels (frozen abs filled
//       the arc with zeros and killed real flights).
//    F3 triple freeze detector: cross-liveness vs the rel/pressure channel,
//       1 m fusion-grid granularity (measured 1.037->2.037->4.037 with
//       "excellent" accuracy), static-in-motion. Frozen channel = ABSENT.
//    F4 splash-closed landing corroborates ballistic (emit conf 0.4 above the
//       trust ceiling); ceiling 2.5 -> 3.0. PLUS acceptance-test guards:
//       ballistic requires a hard (impact) landing and is hard-capped at 6 m --
//       glassy quiet + a wave-dunk dive faked 32/36 m jumps in replay.
//    F6 minRiseM 1.0, GPS gate 1.5 m/s, open-reject cooldown 1 s.
//
//  V15 "clean" engine — second generation: IMU-LED detection with barometric
//  MEASUREMENT. Designed from V15_SPEC_HE.pdf (17.7.2026 measurement day) and
//  calibrated directly against the four Surfr golden jumps in the CLEAN log
//  (log_clean_20260717_141359). Fully self-contained: no dependency on any
//  other engine or app condition.
//
//  ── Design principles (binding, spec §1) ─────────────────────────────────
//  P1  Zero phantoms without paying in misses; borderline events are emitted
//      with low confidence, never swallowed silently.
//  P2  Height via a simple parabolic fit — no Kalman, no aerodynamics.
//  P3  Every mechanism is justified by measured evidence from the logs.
//  P4  Single-consumer, continuous absolute-altitude stream from session
//      start to end — no onDemand windows, no watchdog restarts. (Measured:
//      25 min alone = 0% freeze; parallel consumer = 24%; onDemand = 96%.)
//
//  ── What the CLEAN log actually measured (drives every threshold) ────────
//  • Takeoff pops are SMALL: 1.29–2.03 g on all four goldens. The 3–7.7 g
//    spikes are the LANDING impacts. Riding crosses 2.2 g ~52 times in
//    25 min — a big-yank opener is wrong on both ends.
//  • Flight is QUIET but not freefall: 1 s load std 0.10–0.37 g, mean
//    0.91–1.08 g (the kite carries the rider through the harness). Smooth
//    planing is ALSO quiet — quiet alone cannot separate riding from flight.
//  • Mid-flight jolts cross the impact threshold (J2: 2.83 g at +1.5 s), so
//    an impact spike alone must not end the flight.
//  • Every real landing floods the pressure port: abs dives below base
//    (−0.81…−5.3 m) within ~1.2 s of the impact, all four goldens.
//  • The measured float ratio airtime/T_bal(Surfr height) = 2.44–2.64.
//
//  ── State machine ────────────────────────────────────────────────────────
//  RIDING     Global trailing 1 s load window. When it turns quiet
//             (std ≤ quietStdG, mean in the measured band), scan the raw
//             ring BACK for the last takeoff pop (≥ yankOpenG) within
//             `quietStartDeadlineSec` before the quiet began. Pop found ⇒
//             flight opens RETROACTIVELY: t₀ = pop time (±5 ms), base B =
//             6 s median before the pop, arc points since t₀ are seeded from
//             the channel history. Quiet with no pop = calm riding — ignored.
//  AIRBORNE   Dual collection: abs arc vs B (+ rel backup) while the quiet
//             holds. An impact spike (≥ impactG) becomes a PENDING landing,
//             confirmed within `landingConfirmSec` by the baro splash dive
//             (below base / sharp drop) or by the quiet not resuming; a
//             stronger spike inside the window replaces it. Quiet resuming
//             with no splash = mid-flight jolt — keep flying.
//  LANDING-   Quiet collapsed with no spike at all: soft landing — only the
//  WAIT       baro returning to B ± `softReturnBandM` closes the jump.
//  EMIT       ≥ `emitDelaySec` after landing.
//
//  ── Height: three floors (spec §6) ───────────────────────────────────────
//  A  apexFit on the abs arc: LSQ z(τ)=bτ+cτ², h=−b²/4c, anchored to B.
//     conf 0.9 (−0.15 when the landing was soft).
//  B  rel backup + physics-forced parabola (zeros at 0 and airtime). conf 0.65.
//  C  ballistic h = g·(T_bal/2)²/2, T_bal = airtime/floatFactor — airtime to
//     the PHYSICAL landing, never a timer. Guarded: baro-closed landing
//     required, and above `ballisticTrustCeilingM` a pressure channel must
//     corroborate. conf 0.5.
//  All floors pass the §3.2 physics gates (t_apex, rise rate, airtime↔height
//  ballistic consistency) and the user's minRise threshold.
//
//  ── Channel hygiene (spec §5) ────────────────────────────────────────────
//  splash-guard 3 s after impact; datum-step |Δ|≥5 m ⇒ window reset; rise
//  rate > 25 m/s (world-record v₀) ⇒ sample dropped; unchanged abs for 2 s
//  in flight ⇒ frozen; accuracy ≥100 = re-anchor sentinel, ≥12 = degenerate
//  warm-up — dropped.
//
//  ── Removed vs V14 (spec §5) ─────────────────────────────────────────────
//  takeoffTurbulence gyro gate (8–22 rad/s is a legitimate rotating trick)
//  and gpsSpeedBelowRiding. GPS is metrics-only.
//

import Foundation

// MARK: - Config

public struct V15Config {
    // User-facing counted-height threshold (1 / 1.5 / 2 m picker; spec §5
    // default 1.5 m — same as Surfr/Hoolan).
    public var minRiseM = 1.0

    // Base B: 6 s median locked at the takeoff pop (spec §5 — NOT 10 s; the
    // measured ±6 m/20 s base wander pollutes a long window).
    public var baselineWindowSec = 6.0
    public var minBaselineSamples = 2

    // IMU signature — calibrated on the CLEAN 17.7 goldens (gravity-projected
    // load): takeoff pops 1.29–2.03 g; flight 1 s std 0.10–0.37 g with mean
    // 0.91–1.08 g.
    public var yankOpenG = 1.2            // takeoff pop floor
    public var quietStdG = 0.45           // trailing-1 s std ceiling for flight quiet
    public var quietMeanMinG = 0.6        // measured flight-load mean band
    public var quietMeanMaxG = 1.35
    public var quietWindowSec = 1.0
    public var quietStartDeadlineSec = 1.2 // pop must precede the quiet onset by at most this
    public var floatLoadG = 0.95          // "float" = load below this (goldens: 40–52%)
    public var minFloatFraction = 0.35    // spec §5: measured 35–96%

    // Landing: an impact spike proposes a landing; the baro splash dive (or
    // the quiet not resuming) confirms it. A stronger spike inside the window
    // replaces the pending one (J3: 2.13 g jolt, real 4.0 g landing 0.75 s
    // later).
    public var impactG = 1.9              // landing spikes measured 2.27–3.04 g
    public var impactSearchSec = 0.8
    public var landingConfirmSec = 1.5
    public var splashDropM = 1.2          // pre-spike → post-spike abs drop confirming water entry
    public var softReturnBandM = 0.75     // baro back to B±0.75 confirms a soft landing
    public var softConfirmTimeoutSec = 6.0

    // Channel hygiene (spec §5).
    public var splashGuardSec = 3.0       // baro blackout after impact (measured −0.8…−5.9 m dives)
    public var datumStepResetM = 5.0      // |Δ|≥5 m ⇒ window reset (13.7 phantoms were 5.8–6.2 m steps)
    public var maxRiseRateMS = 25.0       // above world-record v₀ = spike, dropped
    public var freezeSec = 2.0            // unchanged abs for 2 s in flight = frozen (CLEAN p90=0.33 s)
    public var degradedAccuracyM = 12.0   // healthy CLEAN accuracy 5–8; ≥12 = degenerate warm-up
    public var sentinelAccuracyM = 100.0  // Core Motion re-anchor sentinel

    // Physical acceptance bounds (spec §3.2 — visible physics).
    public var minAirtimeSec = 1.2
    public var maxFlightSec = 30.0        // world Big-Air ceiling
    public var flightAbortNoRiseSec = 5.0 // smooth planing reads as quiet too: no arc rise by maxTApex+1 s = not flying; the abort frees the engine so a real jump folded into a fake flight can be re-opened by lookback
    public var minTApexSec = 0.3
    public var maxTApexSec = 4.0
    public var minAvgRiseRateMS = 0.5
    public var maxAirtimeBallisticRatio = 3.5  // airtime ≤ 3.5 × T_bal(h) — world float ceiling
    public var minAirtimeBallisticRatio = 0.5  // height↔time consistency floor

    // Height floors.
    // floatFactor is the spec §9 single calibration knob: T_bal = airtime/f.
    // Calibrated on the four 17.7 goldens: measured airtime/T_bal(Surfr
    // height) = 2.64, 2.61, 2.44, 2.62 — with 2.6 the ballistic floor lands
    // within ±0.35 m of all four Surfr heights.
    public var floatFactor = 2.6
    /// Ballistic lift correction: faster entry ⇒ more kite lift ⇒ more float
    /// per metre of height. h·clamp(1 − slope·(vIn − ref), 0.8, 1.25).
    /// Validated on 12 Surfr goldens (LOO MAE 0.31 → 0.26 m, cross-session).
    public var vInRefMS = 6.5
    public var vInSlope = 0.12
    /// Ballistic airtime shrinkage (small-jump regime only): the IMU landing
    /// time is ±1 s noisy in glassy water (kite landings are SOFT — measured:
    /// no impact spike at Surfr's landing time in 9/12 goldens; the pre-landing
    /// kite-redirect jerk arrives ~1.3 s early), while physics compresses a
    /// counted 0.8–3 m jump into T ∈ [2.6, 4.6] s. MMSE: T_eff =
    /// (1−w)·T_meas + w·prior. Goldens: engine airtime MAE 1.05 s → 0.30 s.
    /// Above shrinkMax the measured T is used as-is (big air has unmistakable
    /// long-float evidence).
    public var airtimePriorSec = 3.4
    public var airtimePriorWeight = 0.75
    public var airtimeShrinkMaxSec = 6.0
    /// Display tolerance: report a jump once height ≥ minRiseM − this (±20 cm
    /// height error ⇒ a 1 m user threshold should surface from 80 cm).
    public var reportToleranceM = 0.2
    public var minArcPoints = 3           // abs points needed for the free apexFit

    // Ballistic floor trust: without pressure corroboration the IMU-only
    // height is believed only up to this ceiling (goldens' ballistic heights
    // are 1.7–2.2 m; a fake flight's ballistic explodes with airtime).
    public var ballisticTrustCeilingM = 3.0
    public var ballisticCorroborationFraction = 0.4
    /// No unmeasured (ballistic) height above this is ever emitted (F4 safety).
    public var ballisticHardCapM = 6.0
    /// F6: cooldown after a rejected open attempt (stops the REJECT(open) spam).
    public var openRejectCooldownSec = 1.0
    /// F1: rescue attempt cap per rejected flight.
    public var rescueMaxAttempts = 5
    /// F3: fusion coarse-grid -- median distinct-step at/above this = disturbed.
    public var granularityBadM = 0.45
    /// F3: cross-liveness -- rel/pressure moved >= this while abs sat still = frozen.
    public var crossLiveMoveM = 0.4

    // GPS assist — a deliberate, measured deviation from spec §5 (which
    // removed the V14 gate): replaying the CLEAN log, every beach/warm-up
    // phantom opened at 0.1–1.4 m/s while all four goldens took off at
    // 6.5–7.3 m/s. Like V14, the gate applies ONLY when a fix exists near
    // t₀ — an unlocked GPS never blocks detection.
    public var minTakeoffGpsSpeedMS = 1.5

    // Emission & retrigger (spec §5).
    public var emitDelaySec = 1.0
    public var retriggerGuardSec = 5.0    // echo guard: same jump re-emitted 2.2-4 s after landing
    /// JUMP-EVIDENCE gate (real-vs-phantom, validated 12 real / 9 phantoms →
    /// 12/12 kept, 8/9 killed). Physics: a jump is popped OFF AN EDGE riding
    /// fast, and the landing is downwind of the take-off line, so a real jump
    /// shows entry speed ≥ gateMinEntry AND at least one of: course change ≥
    /// gateCourseDeg, in-air speed ratio ≤ gateDropFraction, yank ≥ gateYankG.
    /// Skipped when GPS is absent.
    public var gateMinEntryMS = 5.0
    public var gateCourseDeg = 25.0
    public var gateDropFraction = 0.40
    public var gateYankG = 4.0
    /// Retro yank-anchor scan depth before quiet start (1.2 s missed real
    /// 6.8 g pops 2.6 s back and anchored on late chop instead).
    public var anchorLookbackSec = 3.0
    /// Rotation-refined ballistic height (small-jump regime only): total wrist
    /// rotation over the flight scales with jump size. h = base + slope*rotI,
    /// clamped to [0.6, 1.8]*ballistic. LOO-validated: MAE 0.52 -> 0.29 m.
    public var rotHeightBase = 1.2
    public var rotHeightSlope = 0.10

    // History.
    public var historySec = 60.0
    public var gpsMatchToleranceSec = 2.5

    public init() {}
}

// MARK: - Result

public enum V15HeightSource: String {
    case apexFit          // floor A: parabola on the abs arc
    case relativeParabola // floor B: rel backup + physics-forced parabola
    case ballistic        // floor C: airtime only
}

public struct V15Jump {
    public let heightM: Double
    public let heightSource: V15HeightSource
    public let heightApexFitM: Double?
    public let heightRelativeM: Double?
    public let heightBallisticM: Double

    public let airtimeSec: Double
    public let takeoffT: TimeInterval
    public let landingT: TimeInterval
    public let apexT: TimeInterval

    public let baseAbsM: Double?
    public let peakAbsM: Double?
    public let arcPointCount: Int

    public let yankG: Double
    public let landingImpactG: Double
    public let peakG: Double
    public let floatFraction: Double
    public let maxGyroRadS: Double
    public let rotationTurns: Double

    public let takeoffSpeedMS: Double?
    public let landingSpeedMS: Double?
    public let distanceM: Double?
    public let launchLat: Double?
    public let launchLng: Double?
    public let landingLat: Double?
    public let landingLng: Double?

    public let confidence: Double
    public let hardLanding: Bool
    public let emittedAtT: TimeInterval
}

public protocol JumpEngineV15Delegate: AnyObject {
    func jumpDetected(_ jump: V15Jump)
}

// MARK: - Engine

public final class JumpEngineV15 {
    public weak var delegate: JumpEngineV15Delegate?
    public var onDebug: (TimeInterval, String) -> Void = { _, _ in }

    private let cfg: V15Config
    private let g0 = 9.80665

    private struct TimedValue {
        let t: TimeInterval
        let v: Double
    }

    private struct ImuSample {
        let t: TimeInterval
        let load: Double
        let gyro: Double
    }

    private struct GpsPt {
        let t: TimeInterval
        let lat: Double
        let lng: Double
        let spd: Double
        let course: Double            // deg, -1 = unknown
    }

    /// One pressure channel (abs 3 Hz measurer / rel 0.4 Hz backup): rolling
    /// accepted-sample window, datum-step reset, freeze bookkeeping.
    private struct PressureChannel {
        var window: [TimedValue] = []
        var lastChangedT: TimeInterval = -.infinity
        var lastChangedV: Double?
        var resetCount = 0

        mutating func removeAll() {
            window.removeAll(keepingCapacity: true)
            lastChangedT = -.infinity
            lastChangedV = nil
            resetCount = 0
        }
    }

    private struct Flight {
        let t0: TimeInterval              // takeoff pop (±5 ms), found retroactively
        let yankG: Double
        let baseAbs: Double?              // B, 6 s median before the pop, locked
        let baseRel: Double?
        let launchGPS: GpsPt?

        // Signature metrics (catch-up from the raw ring at open, then live).
        var floatSamples = 0
        var totalSamples = 0
        var peakG = 0.0
        var maxGyro = 0.0
        var rotationIntegral = 0.0
        var lastImuT: TimeInterval?

        // Dual collection: (τ, z) relative to t0 / channel base.
        var arcAbs: [TimedValue] = []
        var arcRel: [TimedValue] = []
        var absDisturbed = false          // datum reset / freeze / spike during flight
        var relDisturbed = false

        // True for flights rebuilt by the folded-jump rescue: only a MEASURED
        // height floor (apexFit / rel parabola) may emit them — the ballistic
        // floor on a reconstructed envelope is where phantoms live.
        var rescued = false

        // Landing.
        var quietCollapseT: TimeInterval?
        var pendingImpactT: TimeInterval?   // spike awaiting splash/no-quiet confirmation
        var pendingImpactG = 0.0
        var preImpactAbsZ: Double?          // abs z just before the pending spike
        var landingT: TimeInterval?
        var landingImpactG = 0.0
        var hardLanding = false
        var baroClosedLanding = false       // splash dive / return-to-base confirmed it
    }

    private enum Phase {
        case riding
        case airborne(Flight)
        case landingWait(Flight)          // quiet collapsed w/o impact: baro must close it
        case emitPending(Flight)          // landed; emit ≥1 s after landing
    }

    private var phase: Phase = .riding

    // Continuous channels.
    private var absChannel = PressureChannel()
    private var relChannel = PressureChannel()
    private var gpsHistory: [GpsPt] = []

    // Raw IMU ring: pop lookback (quiet window + deadline) and post-impact
    // quiet verdicts. Also carries the trailing-1 s quiet stats (running sums).
    private var rawRing: [ImuSample] = []
    private var quietWindow: [TimedValue] = []
    private var quietSum = 0.0
    private var quietSqSum = 0.0

    private var lastQuietVerdict: Bool?
    // F3: abs frozen by cross-liveness / granularity / static-in-motion.
    private var absFrozen = false
    private var relAtLastAbsChange: Double?
    private var absDistinctSteps: [Double] = []
    // F6: open-attempt cooldown.
    private var lastOpenRejectT: TimeInterval = -.infinity
    private var baroBlackoutUntil: TimeInterval = -.infinity
    private var lastLandingT: TimeInterval = -.infinity
    /// Landing time of the last EMITTED jump — the retrigger/echo reference.
    /// (lastLandingT is set by every confirmed landing, including rejected
    /// fakes, and must not arm the guard.)
    private var lastEmittedLandingT: TimeInterval = -.infinity
    private var lastImuT: TimeInterval = -.infinity
    private var lastAbsT: TimeInterval = -.infinity
    private var lastRelT: TimeInterval = -.infinity
    private var lastGpsT: TimeInterval = -.infinity
    private var lastRejectDebug = ""

    // Forensic counters (spec-external): surfaced once at flush() so an
    // offline replay can tell "no absolute samples delivered" apart from
    // "delivered but hygiene-rejected" without instrumenting every call.
    private var absReceivedCount = 0
    private var absNonMonotonicDropped = 0
    private var absAcceptedCount = 0
    private var relReceivedCount = 0

    public init(_ cfg: V15Config = V15Config()) {
        self.cfg = cfg
    }

    public func reset() {
        phase = .riding
        absChannel.removeAll()
        relChannel.removeAll()
        gpsHistory.removeAll(keepingCapacity: true)
        rawRing.removeAll(keepingCapacity: true)
        quietWindow.removeAll(keepingCapacity: true)
        quietSum = 0
        quietSqSum = 0
        lastQuietVerdict = nil
        absFrozen = false
        relAtLastAbsChange = nil
        absDistinctSteps.removeAll(keepingCapacity: true)
        lastOpenRejectT = -.infinity
        baroBlackoutUntil = -.infinity
        lastLandingT = -.infinity
        lastEmittedLandingT = -.infinity
        lastImuT = -.infinity
        lastAbsT = -.infinity
        lastRelT = -.infinity
        lastGpsT = -.infinity
        lastRejectDebug = ""
    }

    // MARK: Inputs

    /// `verticalLoadG` is the gravity-projected load in g (~1 at rest, ~0 in
    /// freefall, >1 under pop/impact compression). 200 Hz.
    public func addIMU(t: TimeInterval, verticalLoadG: Double, gyroRadS: Double) {
        guard t.isFinite, verticalLoadG.isFinite, t > lastImuT else { return }
        lastImuT = t
        let load = abs(verticalLoadG)
        // A NaN gyro row must not poison the rotation integral.
        let gyro = gyroRadS.isFinite ? gyroRadS : 0

        rawRing.append(ImuSample(t: t, load: load, gyro: gyro))
        // The ring serves the pop lookback, post-impact quiet verdicts AND the
        // folded-jump rescue — it must span a typical airtime plus margins.
        let ringHorizon = max(cfg.quietWindowSec + cfg.quietStartDeadlineSec + cfg.landingConfirmSec + 1.0, 8.0)
        while let first = rawRing.first, first.t < t - ringHorizon {
            rawRing.removeFirst()
        }

        let quiet = updateQuietStats(t: t, load: load)
        lastQuietVerdict = quiet

        switch phase {
        case .riding:
            if quiet == true {
                tryOpenFlight(now: t)
            }

        case .airborne(var flight):
            trackFlightIMU(t: t, load: load, gyro: gyro, flight: &flight, quiet: quiet)
            phase = .airborne(flight)
            airborneIMU(t: t, load: load)

        case .landingWait(var flight):
            trackFlightIMU(t: t, load: load, gyro: gyro, flight: &flight, quiet: quiet)
            phase = .landingWait(flight)
            landingWaitIMU(t: t, load: load)

        case .emitPending(let flight):
            if let landing = flight.landingT, t - landing >= cfg.emitDelaySec {
                emit(flight: flight, at: t)
                if quiet == true {
                    tryOpenFlight(now: t)
                }
            }
        }
    }

    /// Absolute altitude — the continuous 3 Hz measurer (single consumer, P4).
    public func addAbsoluteAltitude(t: TimeInterval, altitudeM: Double, accuracyM: Double? = nil) {
        absReceivedCount += 1
        guard t.isFinite, altitudeM.isFinite, t > lastAbsT else {
            if t.isFinite, altitudeM.isFinite { absNonMonotonicDropped += 1 }
            return
        }
        lastAbsT = t
        // Routing runs after ingest returns: confirmLanding may purge the
        // channel window, which must not overlap the ingest's inout borrow.
        if ingestPressure(t: t, altitudeM: altitudeM, accuracyM: accuracyM, channel: &absChannel, isAbs: true) {
            absAcceptedCount += 1
            routePressureToFlight(t: t, altitudeM: altitudeM, isAbs: true)
        }
    }

    /// Relative altitude — the 0.4 Hz backup channel.
    public func addRelativeAltitude(t: TimeInterval, altitudeM: Double) {
        relReceivedCount += 1
        guard t.isFinite, altitudeM.isFinite, t > lastRelT else { return }
        lastRelT = t
        if ingestPressure(t: t, altitudeM: altitudeM, accuracyM: nil, channel: &relChannel, isAbs: false) {
            routePressureToFlight(t: t, altitudeM: altitudeM, isAbs: false)
        }
    }

    /// GPS is metrics-only (spec §4): distance/speed enrich the result, no
    /// gate reads it. The engine is fully functional with zero GPS input.
    public func addGPS(t: TimeInterval, lat: Double, lng: Double, speedMS: Double, courseDeg: Double = -1) {
        // GPS is a 1 Hz stream; offline replays hold it on 200 Hz IMU rows.
        // Rate-limit so the history stays ~1 Hz either way.
        guard t.isFinite, t > lastGpsT + 0.5 else { return }
        lastGpsT = t
        gpsHistory.append(GpsPt(t: t, lat: lat, lng: lng, spd: max(0, speedMS),
                                course: courseDeg.isFinite ? courseDeg : -1))
        while let first = gpsHistory.first, first.t < t - cfg.historySec {
            gpsHistory.removeFirst()
        }
    }

    /// Session-end flush: a landed jump waiting out its emit delay is emitted
    /// as-is; an open flight without a landing is discarded.
    public func flush(now: TimeInterval) -> [V15Jump] {
        defer { phase = .riding }
        onDebug(now, "SUMMARY absReceived=\(absReceivedCount) absAccepted=\(absAcceptedCount) "
            + "absNonMonotonicDropped=\(absNonMonotonicDropped) absWindowSize=\(absChannel.window.count) "
            + "relReceived=\(relReceivedCount)")
        switch phase {
        case .riding:
            return []
        case .airborne, .landingWait:
            onDebug(now, "REJECT reason=sessionEndedMidFlight")
            return []
        case .emitPending(let flight):
            if let jump = finalize(flight: flight, emittedAt: now) {
                return [jump]
            }
            return []
        }
    }

    // MARK: Quiet tracking (global trailing window)

    /// Maintains the trailing `quietWindowSec` load stats. Returns the quiet
    /// verdict for a FULL window (nil while the window is still filling).
    private func updateQuietStats(t: TimeInterval, load: Double) -> Bool? {
        quietWindow.append(TimedValue(t: t, v: load))
        quietSum += load
        quietSqSum += load * load
        while let first = quietWindow.first, first.t < t - cfg.quietWindowSec {
            quietWindow.removeFirst()
            quietSum -= first.v
            quietSqSum -= first.v * first.v
        }
        guard let first = quietWindow.first,
              t - first.t >= cfg.quietWindowSec * 0.9,
              quietWindow.count >= 20 else { return nil }
        let n = Double(quietWindow.count)
        let mean = quietSum / n
        let variance = max(0, quietSqSum / n - mean * mean)
        let std = variance.squareRoot()
        return std <= cfg.quietStdG && mean >= cfg.quietMeanMinG && mean <= cfg.quietMeanMaxG
    }

    // MARK: Flight opening (riding → airborne)

    /// The trailing window just reads quiet. Flight quiet must FOLLOW a
    /// takeoff pop — scan the ring back for the last pop within the deadline
    /// before the quiet began. Quiet with no pop is calm riding / smooth
    /// planing and opens nothing.
    private func tryOpenFlight(now: TimeInterval) {
        guard now - lastOpenRejectT >= cfg.openRejectCooldownSec else { return }   // F6
        let quietStart = now - cfg.quietWindowSec
        let lookbackStart = quietStart - max(cfg.quietStartDeadlineSec, cfg.anchorLookbackSec)
        // STRONGEST pop in the lookback range: the takeoff pop is the biggest
        // pre-quiet event (J4: real pop 1.35 g vs 1.20 g early-flight
        // excursion; J3: 1.30 g pop vs 1.21 g chop before it) — earliest- or
        // latest-first both misanchor t₀ by up to a second.
        let range = rawRing.filter {
            $0.t >= lookbackStart && $0.t <= quietStart + 0.1 && $0.load >= cfg.yankOpenG
        }
        guard let pop = range.max(by: { $0.load < $1.load }) else { return }

        let t0 = pop.t
        guard t0 - lastEmittedLandingT >= cfg.retriggerGuardSec else {
            lastOpenRejectT = now
            rejectDebug(now, "REJECT(open) reason=retriggerGuard")
            return
        }

        // GPS assist: gate only when a fix is actually present — no GPS, no
        // gate. Beach/warm-up phantoms open at 0.1–1.4 m/s; ride takeoffs at
        // 6.5–7.3 m/s (measured, CLEAN log).
        let launchGPS = gpsPoint(near: t0)
        if let launchGPS, launchGPS.spd < cfg.minTakeoffGpsSpeedMS {
            lastOpenRejectT = now
            rejectDebug(now, "REJECT(open) reason=gpsSpeedBelowRiding spd=\(fmt(launchGPS.spd))")
            return
        }

        // F3: a frozen abs channel is ABSENT -- it must not lock a base.
        let baseAbs = absFrozen ? nil : lockedBase(channel: absChannel, before: t0)
        let baseRel = lockedBase(channel: relChannel, before: t0)

        var flight = Flight(
            t0: t0,
            yankG: pop.load,
            baseAbs: baseAbs,
            baseRel: baseRel,
            launchGPS: launchGPS
        )
        if absFrozen { flight.absDisturbed = true }   // F3

        // Catch-up: the flight opened retroactively — seed the signature
        // metrics from the ring and the arcs from the channel history.
        var prevT: TimeInterval?
        for s in rawRing where s.t > t0 {
            flight.totalSamples += 1
            if s.load <= cfg.floatLoadG { flight.floatSamples += 1 }
            flight.peakG = max(flight.peakG, s.load)
            flight.maxGyro = max(flight.maxGyro, s.gyro)
            if let p = prevT { flight.rotationIntegral += s.gyro * (s.t - p) }
            prevT = s.t
        }
        flight.lastImuT = prevT
        if let baseAbs {
            flight.arcAbs = absChannel.window
                .filter { $0.t > t0 }
                .map { TimedValue(t: $0.t - t0, v: $0.v - baseAbs) }
        }
        if let baseRel {
            flight.arcRel = relChannel.window
                .filter { $0.t > t0 }
                .map { TimedValue(t: $0.t - t0, v: $0.v - baseRel) }
        }

        phase = .airborne(flight)
        onDebug(now, "CANDIDATE t0=\(fmt(t0)) yank=\(fmt(pop.load))g "
            + "quietAt=\(fmt(now)) B(abs)=\(baseAbs.map(fmt) ?? "n/a") "
            + "B(rel)=\(baseRel.map(fmt) ?? "n/a")")
    }

    private func lockedBase(channel: PressureChannel, before t: TimeInterval) -> Double? {
        let values = channel.window
            .filter { $0.t >= t - cfg.baselineWindowSec && $0.t < t }
            .map(\.v)
        guard values.count >= cfg.minBaselineSamples else { return nil }
        return median(values)
    }

    // MARK: In-flight IMU tracking

    private func trackFlightIMU(t: TimeInterval,
                                load: Double,
                                gyro: Double,
                                flight: inout Flight,
                                quiet: Bool?) {
        flight.peakG = max(flight.peakG, load)
        flight.maxGyro = max(flight.maxGyro, gyro)
        if let prev = flight.lastImuT, t > prev {
            flight.rotationIntegral += gyro * (t - prev)
        }
        flight.lastImuT = t
        flight.totalSamples += 1
        if load <= cfg.floatLoadG { flight.floatSamples += 1 }

        // BUG-3 (20.7 replay): accepted-abs sparser than 2 s (vs the ~3 Hz
        // contract) is a dead/onDemand channel — its junk points defeated the
        // no-rise checks. Stale abs = disturbed for this flight.
        if t - lastAbsT > 2.0, !absChannel.window.isEmpty {
            flight.absDisturbed = true
        }

        if quiet == false {
            // BUG-2 guard: the opening yank sits in the trailing window for
            // quietWindowSec after t0 — a "collapse" there is the takeoff itself.
            if flight.quietCollapseT == nil, t - flight.t0 > cfg.quietWindowSec {
                flight.quietCollapseT = t
            }
        } else if quiet == true, flight.quietCollapseT != nil, flight.pendingImpactT == nil {
            // Quiet resumed with no impact pending: the disturbance was a
            // mid-flight jolt (kite-loop / harness snap), not a landing.
            flight.quietCollapseT = nil
        }
    }

    private func airborneIMU(t: TimeInterval, load: Double) {
        guard case .airborne(var flight) = phase else { return }

        if t - flight.t0 > cfg.maxFlightSec {
            // Same rationale as the noRiseAbort rescue below: a pending
            // impact this close to the world-record ceiling is still real
            // physical evidence and would otherwise be discarded a moment
            // before its own confirm window resolves it.
            if let pending = flight.pendingImpactT {
                confirmLanding(&flight, landingT: pending, impactG: flight.pendingImpactG,
                               hard: true, baroClosed: false, via: "impact+maxFlightExceeded")
                phase = .emitPending(flight)
                return
            }
            rejectDebug(t, "REJECT reason=maxFlightExceeded air=\(fmt(t - flight.t0))")
            phase = .riding
            reopenAfterAbort(now: t)
            return
        }

        // Fake-flight exit: smooth planing also reads as flight-quiet, but a
        // real flight this long shows its baro arc (a pro 8 m jump gives
        // 15–27 arc points, spec §3.1). No rise at all by maxTApex+1 s means
        // we are not flying. Checked against BOTH pressure channels — the abs
        // measurer can be starved for an entire session (observed: a real
        // device delivering absolute-altitude updates only a handful of times
        // in 12+ minutes) while the rel backup keeps flowing at its ~0.4 Hz
        // design cadence; abs-only evidence falsely kills every real flight
        // whenever abs is unavailable. Deliberately ignores pending impacts
        // and channel disturbances — chop spikes cycle pendings forever on a
        // fake flight, and a disturbed channel cannot prove a flight either.
        // The reopen below immediately recovers a real jump that was folded
        // into the fake flight (its pop is still inside the lookback ring).
        if t - flight.t0 > cfg.flightAbortNoRiseSec {
            // F2: a disturbed channel cannot prove "no rise" -- consult only the
            // healthy witnesses; both disturbed => skip the abort entirely
            // (maxFlight + float still guard the fake flight).
            var arcWitnesses: [Double] = []
            if !flight.absDisturbed, let m = flight.arcAbs.map(\.v).max() { arcWitnesses.append(m) }
            if !flight.relDisturbed, let m = flight.arcRel.map(\.v).max() { arcWitnesses.append(m) }
            if let arcMax = arcWitnesses.max(), arcMax < cfg.minRiseM {
                // A pending impact awaiting its landingConfirmSec verdict is
                // itself physical evidence (an impactG-or-stronger spike),
                // even without a measurable pressure rise — land on it
                // rather than discard: the alternative silently drops a real
                // jump whose confirm window hadn't elapsed yet when this 5 s
                // cap fired (measured: a real landing killed 1 s before its
                // own pending impact would have resolved).
                if let pending = flight.pendingImpactT {
                    confirmLanding(&flight, landingT: pending, impactG: flight.pendingImpactG,
                                   hard: true, baroClosed: false, via: "impact+noRiseAbort")
                    phase = .emitPending(flight)
                    return
                }
                // Soft-close instead of outright reject: a real glassy
                // landing is often spikeless (soft kite landing) — finalize's
                // jump-evidence gate is the judge; fakes still fail it there.
                confirmLanding(&flight, landingT: t, impactG: 0,
                               hard: false, baroClosed: false, via: "noRiseAbort-softClose")
                phase = .emitPending(flight)
                return
            }
        }

        // Impact spike ⇒ PENDING landing (t_land ±5 ms if confirmed). A
        // mid-flight kite-loop jolt also crosses `impactG` (J2 measured
        // 2.83 g at +1.5 s), so the spike is held for `landingConfirmSec` and
        // must be confirmed by the baro splash dive (routePressureToFlight)
        // or by the quiet NOT resuming. A stronger spike inside the window
        // replaces the pending one.
        if load >= cfg.impactG, t > flight.t0 + cfg.minAirtimeSec * 0.5 {
            if flight.pendingImpactT == nil {
                flight.preImpactAbsZ = lastAbsZ(base: flight.baseAbs, before: t)
                flight.pendingImpactT = t
                flight.pendingImpactG = load
                onDebug(t, "IMPACT pending=\(fmt(load))g air=\(fmt(t - flight.t0))")
            } else if load >= flight.pendingImpactG {
                flight.pendingImpactT = t
                flight.pendingImpactG = load
            }
        }

        // Pending impact timed out without a baro splash. A pending impact at
        // a PLAUSIBLE airtime IS the landing: glassy water stays quiet AFTER
        // the landing too (the rider planes smoothly), so the older "quiet
        // resumed ⇒ discard" verdict swallowed real landings there and let the
        // flight run 30–50 s to a random chop spike (inflated airtime/height
        // + phantoms). Only a VERY early spike (< 1.5·minAirtime), where the
        // rider is still clearly airborne, is a mid-flight kite-loop jolt —
        // discarded when the quiet genuinely resumed.
        if let pending = flight.pendingImpactT, t - pending >= cfg.landingConfirmSec {
            let veryEarly = pending - flight.t0 < cfg.minAirtimeSec * 1.5
            var discard = false
            if veryEarly {
                let post = rawRing.filter { $0.t >= pending + 0.15 }
                if post.count >= 10 {
                    let mean = post.reduce(0) { $0 + $1.load } / Double(post.count)
                    let variance = max(0, post.reduce(0) { $0 + ($1.load - mean) * ($1.load - mean) } / Double(post.count))
                    discard = variance.squareRoot() <= cfg.quietStdG // still airborne
                }
            }
            if !discard {
                confirmLanding(&flight, landingT: pending, impactG: flight.pendingImpactG,
                               hard: true, baroClosed: false, via: "impact")
                phase = .emitPending(flight)
                return
            }
            onDebug(t, "IMPACT discarded=\(fmt(flight.pendingImpactG))g — early mid-flight jolt (quiet resumed)")
            flight.pendingImpactT = nil
            flight.pendingImpactG = 0
            flight.preImpactAbsZ = nil
            flight.quietCollapseT = nil
        }

        // GPS speed-recovery landing: a long spikeless flight (soft landing,
        // no baro) is closed when GPS shows ride-speed RECOVERY after the
        // in-air dip — the rider is provably planing again.
        if flight.pendingImpactT == nil, t - flight.t0 > cfg.airtimeShrinkMaxSec,
           let entryG = gpsPoint(near: flight.t0 - 1.0) ?? flight.launchGPS,
           entryG.spd >= cfg.gateMinEntryMS {
            var dipT: TimeInterval?
            var recT: TimeInterval?
            for g in gpsHistory where g.t > flight.t0 + 0.5 && g.t <= t {
                if dipT == nil {
                    if g.spd <= entryG.spd * cfg.gateDropFraction { dipT = g.t }
                } else if recT == nil, g.spd >= cfg.gateMinEntryMS {
                    recT = g.t
                    break
                }
            }
            if let recT, t - recT >= 1.0 {
                confirmLanding(&flight, landingT: recT, impactG: 0,
                               hard: false, baroClosed: false, via: "gpsSpeedRecovery")
                phase = .emitPending(flight)
                return
            }
        }

        // Quiet collapsed with no impact spike at all: soft-landing path —
        // only the baro can close the jump (spec §4.1 row 3).
        if let collapse = flight.quietCollapseT, flight.pendingImpactT == nil,
           t - collapse > cfg.impactSearchSec {
            phase = .landingWait(flight)
            onDebug(t, "QUIET collapse=\(fmt(collapse)) — waiting impact/baroReturn")
            return
        }

        phase = .airborne(flight)
    }

    private func landingWaitIMU(t: TimeInterval, load: Double) {
        guard case .landingWait(var flight) = phase,
              let collapse = flight.quietCollapseT else { return }

        // Late impact inside the search window ⇒ hard landing.
        if t - collapse <= cfg.impactSearchSec, load >= cfg.impactG {
            confirmLanding(&flight, landingT: t, impactG: load, hard: true,
                           baroClosed: false, via: "impact(late)")
            phase = .emitPending(flight)
            return
        }

        if t - collapse > cfg.softConfirmTimeoutSec {
            // No impact and the baro never returned to B: nothing closed the
            // jump (spec §4.1 — a soft landing is baro-confirmed or not at all).
            rejectDebug(t, "REJECT reason=softLandingUnconfirmed collapse=\(fmt(collapse))")
            phase = .riding
            reopenAfterAbort(now: t)
            return
        }

        if t - flight.t0 > cfg.maxFlightSec {
            rejectDebug(t, "REJECT reason=maxFlightExceeded air=\(fmt(t - flight.t0))")
            phase = .riding
            reopenAfterAbort(now: t)
            return
        }

        phase = .landingWait(flight)
    }

    /// After an aborted fake flight: if the wrist is quiet RIGHT NOW, a real
    /// flight may be in progress (its pop swallowed by the fake flight) —
    /// re-open it from the ring with the correct t₀.
    private func reopenAfterAbort(now: TimeInterval) {
        if lastQuietVerdict == true {
            tryOpenFlight(now: now)
        }
    }

    /// Last accepted abs sample before `t`, as z relative to the flight base.
    private func lastAbsZ(base: Double?, before t: TimeInterval) -> Double? {
        guard let base,
              let last = absChannel.window.last(where: { $0.t < t }) else { return nil }
        return last.v - base
    }

    /// Stamp the landing onto the flight and clean both pressure channels:
    /// splash-guard blackout (measured −0.8…−5.9 m dives after every landing)
    /// and purge of any splash samples that already arrived after t_land, so
    /// the dive can poison neither the next base nor this arc.
    private func confirmLanding(_ flight: inout Flight,
                                landingT: TimeInterval,
                                impactG: Double,
                                hard: Bool,
                                baroClosed: Bool,
                                via: String) {
        flight.landingT = landingT
        flight.landingImpactG = impactG
        flight.hardLanding = hard
        flight.baroClosedLanding = baroClosed
        baroBlackoutUntil = landingT + cfg.splashGuardSec
        absChannel.window.removeAll { $0.t > landingT }
        relChannel.window.removeAll { $0.t > landingT }
        lastLandingT = landingT
        onDebug(landingT, "LANDING \(via) impact=\(fmt(impactG))g air=\(fmt(landingT - flight.t0))")
    }

    // MARK: Pressure ingest (shared hygiene, spec §5)

    /// Channel hygiene. Returns true when the sample was accepted into the
    /// window — the caller then routes it to the active flight (kept outside
    /// this function so a landing confirmation may purge the channel window
    /// without overlapping the inout borrow).
    private func ingestPressure(t: TimeInterval,
                                altitudeM: Double,
                                accuracyM: Double?,
                                channel: inout PressureChannel,
                                isAbs: Bool) -> Bool {
        let tag = isAbs ? "abs" : "rel"

        // Core Motion re-anchor sentinel / degenerate warm-up accuracy.
        if isAbs, let accuracyM, accuracyM.isFinite {
            if accuracyM >= cfg.sentinelAccuracyM { return false }
            if accuracyM >= cfg.degradedAccuracyM {
                rejectDebug(t, "BARO \(tag) drop reason=degradedAccuracy acc=\(fmt(accuracyM))")
                return false
            }
        }

        // splash-guard: after impact the pressure port floods — the channel lies.
        if t < baroBlackoutUntil {
            return false
        }

        if let last = channel.window.last {
            let delta = altitudeM - last.v
            let dt = t - last.t
            // datum-step: a ≥5 m step is a new datum, not motion — reset the
            // window so the step can become neither base nor arc.
            if abs(delta) >= cfg.datumStepResetM {
                onDebug(t, "BARO \(tag) datumStep delta=\(fmt(delta)) — window reset")
                channel.window.removeAll(keepingCapacity: true)
                channel.resetCount += 1
                markDisturbance(isAbs: isAbs)
            } else if dt > 0, delta / dt > cfg.maxRiseRateMS {
                // Faster than the world-record v₀: spike, dropped.
                rejectDebug(t, "BARO \(tag) drop reason=riseRate rate=\(fmt(delta / dt))")
                markDisturbance(isAbs: isAbs)
                return false
            }
        }

        // Freeze bookkeeping (spec §5) + F3 granularity / cross-liveness.
        if channel.lastChangedV != altitudeM {
            if isAbs, let prev = channel.lastChangedV {
                absDistinctSteps.append(abs(altitudeM - prev))
                if absDistinctSteps.count > 10 { absDistinctSteps.removeFirst() }
                // F3 granularity: the fusion coarse mode quantises to a 1 m grid
                // (measured 1.037->2.037->4.037 with accuracy 0-5.5) -- values
                // "change" but the channel is degenerate.
                if absDistinctSteps.count >= 4 {
                    let sortedSteps = absDistinctSteps.sorted()
                    let gran = sortedSteps[sortedSteps.count / 2]
                    let bad = gran >= cfg.granularityBadM
                    if bad, !absFrozen { onDebug(t, "ABS coarse-grid granularity=\(fmt(gran))m -- disturbed") }
                    absFrozen = bad
                    if bad { markDisturbance(isAbs: true) }
                }
            }
            channel.lastChangedV = altitudeM
            channel.lastChangedT = t
            if isAbs { relAtLastAbsChange = relChannel.lastChangedV }
            if !isAbs, let anchor = relAtLastAbsChange,
               abs(altitudeM - anchor) >= cfg.crossLiveMoveM,
               t - absChannel.lastChangedT > cfg.quietWindowSec {
                // F3 cross-liveness: the pure barometer moved while the abs
                // fusion output sat still => abs frozen (measured 20.7:
                // rel/pressure 100% alive through a 2.5-min abs freeze whose
                // accuracy looked "excellent").
                if !absFrozen { onDebug(t, "ABS frozen (cross-liveness)") }
                absFrozen = true
                markDisturbance(isAbs: true)
            }
        } else if isAbs, t - channel.lastChangedT >= cfg.freezeSec, isInFlight {
            absFrozen = true
            markDisturbance(isAbs: true)
        }

        channel.window.append(TimedValue(t: t, v: altitudeM))
        while let first = channel.window.first, first.t < t - cfg.historySec {
            channel.window.removeFirst()
        }

        return true
    }

    private var isInFlight: Bool {
        switch phase {
        case .airborne, .landingWait: return true
        case .riding, .emitPending: return false
        }
    }

    private func markDisturbance(isAbs: Bool) {
        func mark(_ flight: inout Flight) {
            if isAbs { flight.absDisturbed = true } else { flight.relDisturbed = true }
        }
        switch phase {
        case .airborne(var f): mark(&f); phase = .airborne(f)
        case .landingWait(var f): mark(&f); phase = .landingWait(f)
        case .riding, .emitPending: break
        }
    }

    private func routePressureToFlight(t: TimeInterval, altitudeM: Double, isAbs: Bool) {
        func collect(_ flight: inout Flight) {
            guard flight.landingT == nil else { return }
            if isAbs, let base = flight.baseAbs {
                flight.arcAbs.append(TimedValue(t: t - flight.t0, v: altitudeM - base))
            } else if !isAbs, let base = flight.baseRel {
                flight.arcRel.append(TimedValue(t: t - flight.t0, v: altitudeM - base))
            }
        }

        switch phase {
        case .riding, .emitPending:
            break
        case .airborne(var flight):
            collect(&flight)
            // Splash confirmation for a pending impact: the pressure port
            // floods on water entry — the channel dives BELOW base (measured
            // −0.81…−3.35 m after the golden landings) or drops sharply from
            // its pre-spike level. A mid-flight jolt shows neither (J2's
            // 2.83 g jolt: abs held +2.0 m throughout).
            if let pending = flight.pendingImpactT, t >= pending {
                let base = isAbs ? flight.baseAbs : flight.baseRel
                let z = base.map { altitudeM - $0 }
                let belowBase = z.map { $0 <= -cfg.softReturnBandM } ?? false
                let sharpDrop: Bool
                if isAbs, let pre = flight.preImpactAbsZ, let z {
                    sharpDrop = pre - z >= cfg.splashDropM
                } else {
                    sharpDrop = false
                }
                if belowBase || sharpDrop {
                    confirmLanding(&flight, landingT: pending, impactG: flight.pendingImpactG,
                                   hard: true, baroClosed: true, via: "impact+splash(\(isAbs ? "abs" : "rel"))")
                    phase = .emitPending(flight)
                    return
                }
            }
            phase = .airborne(flight)
        case .landingWait(var flight):
            // Soft landing: the baro closing back to B confirms it (spec §4).
            // BUG-1 guard (20.7 replay): "return to base" is only a landing if
            // we flew at least minAirtime AND the arc actually LEFT the base —
            // a re-anchored flight's first sample is naturally still at base
            // and closed a jump at air=0.01 s.
            let arcForGuard = isAbs ? flight.arcAbs : flight.arcRel
            let leftBase = arcForGuard.contains { abs($0.v) > cfg.softReturnBandM }
            let base = isAbs ? flight.baseAbs : flight.baseRel
            if let base, t - flight.t0 >= cfg.minAirtimeSec, leftBase,
               abs(altitudeM - base) <= cfg.softReturnBandM {
                confirmLanding(&flight, landingT: flight.quietCollapseT ?? t,
                               impactG: 0, hard: false, baroClosed: true,
                               via: "soft baroReturn(\(isAbs ? "abs" : "rel"))")
                phase = .emitPending(flight)
            } else {
                phase = .landingWait(flight)
            }
        }
    }

    // MARK: Emit / finalize

    private func emit(flight: Flight, at t: TimeInterval) {
        phase = .riding
        // A rejected flight may have FOLDED a real jump inside it (smooth
        // planing opens fake flights whose locked base is off; the real
        // takeoff pop then lands inside the fake's long airtime). Before
        // giving up, reconstruct pop→quiet→impact directly from the ring.
        let jump = finalize(flight: flight, emittedAt: t)
            ?? rescueFoldedJump(from: flight, emittedAt: t)
        if let jump {
            lastEmittedLandingT = flight.landingT ?? t
            delegate?.jumpDetected(jump)
            onDebug(t, "JUMP h=\(fmt(jump.heightM))m src=\(jump.heightSource.rawValue) "
                + "air=\(fmt(jump.airtimeSec))s conf=\(fmt(jump.confidence))")
        } else if let landing = flight.landingT,
                  flight.landingImpactG >= cfg.gateYankG, landing > flight.t0 {
            // REANCHOR: a rejected (fake) flight that "landed" on a STRONG
            // spike swallowed a real takeoff — glassy chop opens a fake 1–8 s
            // before the jump and the real 4–8 g pop reads as its landing.
            openFlight(at: landing, yank: flight.landingImpactG, now: t)
        }
    }

    /// Open a flight anchored at an EXPLICIT pop — the REANCHOR path.
    private func openFlight(at t0: TimeInterval, yank: Double, now: TimeInterval) {
        guard t0 - lastEmittedLandingT >= cfg.retriggerGuardSec else { return }   // echo guard
        let launchGPS = gpsPoint(near: t0)
        let baseAbs = absFrozen ? nil : lockedBase(channel: absChannel, before: t0)
        let baseRel = lockedBase(channel: relChannel, before: t0)
        var flight = Flight(t0: t0, yankG: yank, baseAbs: baseAbs, baseRel: baseRel, launchGPS: launchGPS)
        if absFrozen { flight.absDisturbed = true }
        var prevT: TimeInterval?
        for smp in rawRing where smp.t > t0 + 0.2 {
            flight.totalSamples += 1
            if smp.load <= cfg.floatLoadG { flight.floatSamples += 1 }
            flight.peakG = max(flight.peakG, smp.load)
            flight.maxGyro = max(flight.maxGyro, smp.gyro)
            if let pv = prevT { flight.rotationIntegral += smp.gyro * (smp.t - pv) }
            prevT = smp.t
        }
        flight.lastImuT = prevT
        if let baseAbs {
            flight.arcAbs = absChannel.window.filter { $0.t > t0 }
                .map { TimedValue(t: $0.t - t0, v: $0.v - baseAbs) }
        }
        if let baseRel {
            flight.arcRel = relChannel.window.filter { $0.t > t0 }
                .map { TimedValue(t: $0.t - t0, v: $0.v - baseRel) }
        }
        phase = .airborne(flight)
        onDebug(now, "CANDIDATE(reanchor) t0=\(fmt(t0)) yank=\(fmt(yank))g")
    }

    /// Entry speed/course come from BEFORE t0 — a 1 Hz lagged GPS point at t0
    /// is already inside the jump's deceleration (measured: real 6 m/s entries
    /// read 3.8 at t0). Returns nil when there is no usable GPS.
    private func jumpEvidence(_ flight: Flight) -> (pass: Bool, reason: String)? {
        guard let landing = flight.landingT else { return nil }
        guard let entryG = gpsPoint(near: flight.t0 - 1.0) ?? flight.launchGPS,
              entryG.spd > 0.5 else { return nil }
        let vin = entryG.spd
        if vin < cfg.gateMinEntryMS { return (false, "gateEntrySpeed vin=\(fmt(vin))") }
        var vmin = Double.infinity
        for g in gpsHistory where g.t >= flight.t0 + 0.5 && g.t <= landing + 1.5 {
            vmin = min(vmin, g.spd)
        }
        var dCourse = -1.0
        if entryG.course >= 0, let landG = gpsPoint(near: landing + 1.0), landG.course >= 0 {
            var d = abs(landG.course - entryG.course).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            dCourse = d
        }
        let pass = dCourse >= cfg.gateCourseDeg
            || (vmin.isFinite && vmin / vin <= cfg.gateDropFraction)
            || flight.yankG >= cfg.gateYankG
        return (pass, pass ? "ok" : "gateNoJumpEvidence dCrs=\(fmt(max(0, dCourse))) "
            + "drop=\(vmin.isFinite ? fmt(vmin / vin) : "n/a") yank=\(fmt(flight.yankG))")
    }

    // MARK: Folded-jump rescue

    /// Landing-first reconstruction over the raw ring: find a takeoff pop P
    /// and a later impact I such that [P, I] is flight-quiet and the airtime
    /// is physical, rebuild the flight against a re-locked base, and run the
    /// normal finalize gates. Earliest pop wins; for that pop the LATEST
    /// impact with a still-quiet span wins (post-landing chop poisons the
    /// span, so the search cannot extend past the real landing — measured on
    /// J2: the mid-flight 2.83 g jolt stays inside the quiet span, the
    /// landing cluster does not).
    private func rescueFoldedJump(from rejected: Flight, emittedAt: TimeInterval) -> V15Jump? {
        guard let fakeLanding = rejected.landingT else { return nil }

        // F1: cluster the ring to LOCAL MAXIMA (0.5 s separation) and cap the
        // attempts -- iterating every 200 Hz sample above the pop floor produced
        // hundreds of finalize+log passes per second (loggerQueueBacklog).
        var pops: [ImuSample] = []
        for sample in rawRing where sample.load >= cfg.yankOpenG {
            if let last = pops.last, sample.t - last.t < 0.5 {
                if sample.load > last.load { pops[pops.count - 1] = sample }
            } else {
                pops.append(sample)
            }
        }
        var attempts = 0
        for pop in pops {
            guard attempts < cfg.rescueMaxAttempts else { break }
            let p = pop.t
            // The rejected flight's own anchor was already tried.
            guard abs(p - rejected.t0) > 0.5, p < fakeLanding - cfg.minAirtimeSec else { continue }
            if let launch = gpsPoint(near: p), launch.spd < cfg.minTakeoffGpsSpeedMS { continue }

            // Latest impact whose span back to the pop is still flight-quiet.
            let impacts = rawRing.filter {
                $0.load >= cfg.impactG
                    && $0.t - p >= cfg.minAirtimeSec
                    && $0.t <= fakeLanding + 0.1
            }
            guard let impact = impacts.last(where: { quietSpan(from: p + 0.35, to: $0.t - 0.05) })
            else { continue }
            attempts += 1

            var flight = Flight(
                t0: p,
                yankG: pop.load,
                baseAbs: lockedBase(channel: absChannel, before: p),
                baseRel: lockedBase(channel: relChannel, before: p),
                launchGPS: gpsPoint(near: p)
            )
            var prevT: TimeInterval?
            for s in rawRing where s.t > p && s.t <= impact.t {
                flight.totalSamples += 1
                if s.load <= cfg.floatLoadG { flight.floatSamples += 1 }
                flight.peakG = max(flight.peakG, s.load)
                flight.maxGyro = max(flight.maxGyro, s.gyro)
                if let prev = prevT { flight.rotationIntegral += s.gyro * (s.t - prev) }
                prevT = s.t
            }
            // Arcs: channel windows were purged past the fake landing, but
            // the rejected flight's own arc kept everything it collected —
            // reconstruct absolute values through the fake base.
            if let newBase = flight.baseAbs {
                if let fakeBase = rejected.baseAbs {
                    flight.arcAbs = rejected.arcAbs
                        .filter { $0.t + rejected.t0 > p }
                        .map { TimedValue(t: $0.t + rejected.t0 - p, v: $0.v + fakeBase - newBase) }
                } else {
                    flight.arcAbs = absChannel.window
                        .filter { $0.t > p }
                        .map { TimedValue(t: $0.t - p, v: $0.v - newBase) }
                }
            }
            if let newBase = flight.baseRel {
                if let fakeBase = rejected.baseRel {
                    flight.arcRel = rejected.arcRel
                        .filter { $0.t + rejected.t0 > p }
                        .map { TimedValue(t: $0.t + rejected.t0 - p, v: $0.v + fakeBase - newBase) }
                } else {
                    flight.arcRel = relChannel.window
                        .filter { $0.t > p }
                        .map { TimedValue(t: $0.t - p, v: $0.v - newBase) }
                }
            }

            flight.rescued = true
            flight.landingT = impact.t
            flight.landingImpactG = impact.load
            flight.hardLanding = true
            // Splash check against the re-locked base: any arc sample shortly
            // after the impact at ≤ B − softReturnBandM (the dive) closes the
            // landing barometrically.
            flight.baroClosedLanding = flight.arcAbs.contains {
                let sampleT = $0.t + p
                return sampleT > impact.t && sampleT <= impact.t + cfg.landingConfirmSec
                    && $0.v <= -cfg.softReturnBandM
            }

            if let jump = finalize(flight: flight, emittedAt: emittedAt) {
                onDebug(emittedAt, "RESCUE folded jump t0=\(fmt(p)) land=\(fmt(impact.t)) "
                    + "air=\(fmt(impact.t - p))")
                return jump
            }
        }
        return nil
    }

    /// Flight-quiet verdict over a ring span: load std ≤ quietStdG and mean
    /// inside the measured band, with real coverage.
    private func quietSpan(from a: TimeInterval, to b: TimeInterval) -> Bool {
        guard b - a >= 0.5 else { return false }
        var n = 0.0, sum = 0.0, sq = 0.0
        for s in rawRing where s.t >= a && s.t <= b {
            n += 1
            sum += s.load
            sq += s.load * s.load
        }
        guard n >= (b - a) * 50 else { return false }
        let mean = sum / n
        let std = max(0, sq / n - mean * mean).squareRoot()
        return std <= cfg.quietStdG && mean >= cfg.quietMeanMinG && mean <= cfg.quietMeanMaxG
    }

    private func finalize(flight: Flight, emittedAt: TimeInterval) -> V15Jump? {
        guard let landing = flight.landingT else { return nil }
        let airtime = landing - flight.t0

        guard airtime >= cfg.minAirtimeSec else {
            rejectDebug(emittedAt, "REJECT reason=airtimeTooShort air=\(fmt(airtime))")
            return nil
        }
        guard airtime <= cfg.maxFlightSec else {
            rejectDebug(emittedAt, "REJECT reason=airtimeTooLong air=\(fmt(airtime))")
            return nil
        }

        // IMU signature completeness: float fraction (spec §5).
        let floatFraction = flight.totalSamples > 0
            ? Double(flight.floatSamples) / Double(flight.totalSamples) : 0
        guard floatFraction >= cfg.minFloatFraction else {
            rejectDebug(emittedAt, "REJECT reason=floatBelowMin float=\(fmt(floatFraction))")
            return nil
        }

        // SOFT-ECHO guard: a soft-closed (no landing impact) flight taking
        // off within 8 s of the last EMITTED landing is the same jump's wake
        // (the post-landing glide re-opens and soft-closes; measured echo
        // 5.6 s after a real landing). Real back-to-back jumps land HARD.
        if !flight.hardLanding, flight.t0 - lastEmittedLandingT < 8.0 {
            rejectDebug(emittedAt, "REJECT reason=softEcho dt=\(fmt(flight.t0 - lastEmittedLandingT))")
            return nil
        }

        // JUMP-EVIDENCE gate (see gateMinEntryMS doc): nil = no GPS to judge.
        let evidence = jumpEvidence(flight)
        if let evidence, !evidence.pass {
            rejectDebug(emittedAt, "REJECT reason=\(evidence.reason)")
            return nil
        }

        // ── Floor A: apexFit on the abs arc (conf 0.9) ─────────────────────
        var apexFitH: Double?
        var apexFitTApex: Double?
        let inFlightArc = flight.arcAbs.filter { $0.t >= 0 && $0.t <= airtime }
        if !flight.absDisturbed,
           inFlightArc.count >= cfg.minArcPoints,
           let fit = fitParabola(inFlightArc) {
            let tApex = -fit.b / (2 * fit.c)
            let h = -fit.b * fit.b / (4 * fit.c)
            if fit.c < 0, fit.b > 0, fit.b <= cfg.maxRiseRateMS,
               tApex >= cfg.minTApexSec, tApex <= cfg.maxTApexSec,
               h > 0, h / tApex >= cfg.minAvgRiseRateMS,
               ballisticConsistent(heightM: h, airtimeSec: airtime) {
                apexFitH = h
                apexFitTApex = tApex
            } else {
                onDebug(emittedAt, "ARC invalid fit b=\(fmt(fit.b)) c=\(fmt(fit.c)) "
                    + "tApex=\(fmt(tApex)) h=\(fmt(h))")
            }
        }

        // ── Floor B: rel backup + physics-forced parabola (conf 0.65) ──────
        // Needs ≥2 positive in-flight points: at the backup channel's real-world
        // cadence (0.36–1 Hz) a short flight sees 0–1 samples, and a forced
        // parabola through ONE noisy point explodes (measured 4.6–5.9 m
        // phantoms). One point is not an arc; the flight falls to floor C.
        var relH: Double?
        let relArc = flight.arcRel.filter { $0.t > 0 && $0.t < airtime && $0.v > 0 }
        if !flight.relDisturbed, relArc.count >= 2, let pk = relArc.max(by: { $0.v < $1.v }) {
            // Parabola forced through z(0)=0 and z(airtime)=0:
            // h = z_pk·T² / (4·τ_pk·(T−τ_pk)).
            let tau = pk.t
            let h: Double
            if tau > 0.1 * airtime, tau < 0.9 * airtime {
                h = pk.v * airtime * airtime / (4 * tau * (airtime - tau))
            } else {
                h = pk.v
            }
            // Floor-B safety (FINAL, 20.7 replay): the forced parabola through
            // noisy backup points explodes on merged fake flights (10.9/23.3 m
            // measured). The backup channel serves the <6 m regime by design —
            // big-air heights come from the abs apexFit floor. Absolute cap.
            if h > 0, h <= cfg.ballisticHardCapM, ballisticConsistent(heightM: h, airtimeSec: airtime) {
                relH = h
            }
        }

        // ── Floor C: pure ballistic (conf 0.5) — airtime to the PHYSICAL
        // landing, never a timer. Guarded three ways, because smooth planing
        // also reads as flight-quiet:
        //  • the landing must have been closed by the baro (splash dives were
        //    measured after ALL four golden landings — an IMU-only "landing"
        //    is not trusted);
        //  • above `ballisticTrustCeilingM` a pressure channel must have seen
        //    ≥ `ballisticCorroborationFraction` of the claimed height;
        //  • the §3.2 height↔time gates.
        // Shrunk airtime (see airtimePriorSec) + entry-speed lift correction
        // (faster entry ⇒ more kite lift ⇒ the fixed float factor
        // over-estimates height; slower ⇒ under-estimates).
        let w = airtime <= cfg.airtimeShrinkMaxSec ? cfg.airtimePriorWeight : 0
        let airtimeEff = (1 - w) * airtime + w * cfg.airtimePriorSec
        let tBal = airtimeEff / cfg.floatFactor
        var ballisticH = g0 * (tBal / 2) * (tBal / 2) / 2
        if let launch = flight.launchGPS {
            let m = 1 - cfg.vInSlope * (launch.spd - cfg.vInRefMS)
            ballisticH *= min(1.25, max(0.8, m))
        }
        // Rotation refinement (see rotHeightBase): in the small-jump regime
        // the airtime is prior-dominated — the integrated rotation carries
        // more per-jump information (r=0.52 vs h; airtime r~0).
        if airtime <= cfg.airtimeShrinkMaxSec, flight.rotationIntegral > 0 {
            let hRot = cfg.rotHeightBase + cfg.rotHeightSlope * flight.rotationIntegral
            ballisticH = min(max(hRot, 0.6 * ballisticH), 1.8 * ballisticH)
        }

        let height: Double
        let source: V15HeightSource
        var confidence: Double
        if let h = apexFitH {
            height = h
            source = .apexFit
            confidence = 0.9
        } else if let h = relH {
            height = h
            source = .relativeParabola
            confidence = 0.65
        } else {
            // With PASSED GPS jump-evidence the gate is the phantom firewall
            // and the legacy impact/baro-landing guards are waived (they
            // rejected real SOFT kite landings — measured: no impact spike at
            // 9/12 real landings). Without GPS the legacy guards stand.
            let waived = evidence?.pass == true
            guard !flight.rescued || waived else {
                rejectDebug(emittedAt, "REJECT reason=rescueNeedsMeasuredHeight "
                    + "hBal=\(fmt(ballisticH)) air=\(fmt(airtime))")
                return nil
            }
            // A splash-confirmed landing is the normal trust path; a
            // distinctly hard impact (well above the landing floor, not a
            // borderline spike) is accepted as alternative corroboration —
            // the abs/rel channels can both be too sparse this session to
            // ever see the splash dive at all (measured: a real device
            // delivering absolute-altitude updates only a handful of times
            // in 12+ minutes), which must not mean a hard 5+ g landing is
            // silently thrown away.
            // Acceptance-test guards (20.7 replay): a soft-closed "flight" with
            // no measured height is quiet+dive only -- glassy riding + a wave
            // dunk fakes exactly that (32/36 m phantoms in replay). Ballistic
            // therefore requires a REAL landing impact, and no unmeasured
            // height above the hard cap is ever emitted, splash or not.
            guard flight.hardLanding || waived else {
                rejectDebug(emittedAt, "REJECT reason=ballisticNeedsImpact "
                    + "hBal=\(fmt(ballisticH)) air=\(fmt(airtime))")
                return nil
            }
            guard ballisticH <= cfg.ballisticHardCapM else {
                rejectDebug(emittedAt, "REJECT reason=ballisticAboveHardCap "
                    + "hBal=\(fmt(ballisticH)) air=\(fmt(airtime))")
                return nil
            }
            guard flight.baroClosedLanding || flight.landingImpactG >= cfg.impactG * 1.5 || waived else {
                rejectDebug(emittedAt, "REJECT reason=ballisticWithoutBaroLanding "
                    + "hBal=\(fmt(ballisticH)) air=\(fmt(airtime))")
                return nil
            }
            confidence = 0.5
            if ballisticH > cfg.ballisticTrustCeilingM {
                let needed = ballisticH * cfg.ballisticCorroborationFraction
                let seenAbs = inFlightArc.map(\.v).max() ?? 0
                let seenRel = relArc.map(\.v).max() ?? 0
                if max(seenAbs, seenRel) < needed {
                    // F4: the splash dive IS pressure corroboration of water
                    // entry (fake glassy flights never splash) -- emit low-conf,
                    // never swallow (P1).
                    guard flight.baroClosedLanding else {
                        rejectDebug(emittedAt, "REJECT reason=ballisticUncorroborated "
                            + "hBal=\(fmt(ballisticH)) seenAbs=\(fmt(seenAbs)) seenRel=\(fmt(seenRel))")
                        return nil
                    }
                    confidence = 0.4
                }
            }
            height = ballisticH
            source = .ballistic
        }
        // Soft landing: the baro closed the jump, not an impact (spec §4.1
        // row 3 — apexFit conf drops 0.9 → 0.75).
        if !flight.hardLanding { confidence -= 0.15 }
        confidence = min(max(confidence, 0.05), 0.95)

        // The user's counted-height threshold is part of the formula.
        // Report from minRiseM − reportToleranceM (height is ±0.2 m, so a 1 m
        // user threshold should surface from 0.8 m).
        let reportFloor = max(0, cfg.minRiseM - cfg.reportToleranceM)
        guard height >= reportFloor else {
            rejectDebug(emittedAt, "REJECT reason=belowMinRise h=\(fmt(height)) "
                + "floor=\(fmt(reportFloor)) src=\(source.rawValue)")
            return nil
        }

        let apexT: TimeInterval
        if let tApex = apexFitTApex {
            apexT = flight.t0 + tApex
        } else {
            apexT = flight.t0 + airtime / 2
        }

        let landingGPS = gpsPoint(near: landing)
        let distance = gpsDistance(from: flight.launchGPS, to: landingGPS, airtime: airtime)

        return V15Jump(
            heightM: round2(height),
            heightSource: source,
            heightApexFitM: apexFitH.map(round2),
            heightRelativeM: relH.map(round2),
            heightBallisticM: round2(ballisticH),
            airtimeSec: round2(airtime),
            takeoffT: flight.t0,
            landingT: landing,
            apexT: apexT,
            baseAbsM: flight.baseAbs.map(round2),
            peakAbsM: flight.baseAbs.flatMap { base in
                inFlightArc.map(\.v).max().map { round2(base + $0) }
            },
            arcPointCount: inFlightArc.count,
            yankG: round2(flight.yankG),
            landingImpactG: round2(flight.landingImpactG),
            peakG: round2(flight.peakG),
            floatFraction: round2(floatFraction),
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
            hardLanding: flight.hardLanding,
            emittedAtT: emittedAt
        )
    }

    // MARK: Physics helpers

    /// Height↔time consistency (spec §3.2): T_bal(h) = 2·√(2h/g); the kite
    /// only EXTENDS airtime (world float ceiling ×3.5), and sampling smear
    /// can shorten the measured arc — airtime must sit in [0.5, 3.5]·T_bal.
    private func ballisticConsistent(heightM: Double, airtimeSec: Double) -> Bool {
        guard heightM > 0 else { return false }
        let tBal = 2 * (2 * heightM / g0).squareRoot()
        return airtimeSec >= cfg.minAirtimeBallisticRatio * tBal
            && airtimeSec <= cfg.maxAirtimeBallisticRatio * tBal
    }

    /// LSQ fit z(τ) = bτ + cτ² through the arc points (anchored to B at the
    /// pop by construction — z is already relative to the locked base).
    private func fitParabola(_ points: [TimedValue]) -> (b: Double, c: Double)? {
        var s1 = 0.0, s2 = 0.0, s3 = 0.0, t1 = 0.0, t2 = 0.0
        for p in points {
            let tau = p.t
            let tau2 = tau * tau
            s1 += tau2
            s2 += tau2 * tau
            s3 += tau2 * tau2
            t1 += tau * p.v
            t2 += tau2 * p.v
        }
        let det = s1 * s3 - s2 * s2
        guard abs(det) > 1e-9 else { return nil }
        let b = (t1 * s3 - t2 * s2) / det
        let c = (t2 * s1 - t1 * s2) / det
        guard b.isFinite, c.isFinite, c != 0 else { return nil }
        return (b, c)
    }

    // MARK: GPS helpers

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

    // MARK: Misc helpers

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
