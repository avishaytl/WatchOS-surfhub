// ================================================================
//  KitesurfJumpEngineV11.swift
//  Apple Watch S9 · Kitesurf Jump Engine — v11 (offline buffered)
//
//  ════════════════════════════════════════════════════════════════
//  WHY v11 IS DIFFERENT FROM v7/v8/v10
//  ════════════════════════════════════════════════════════════════
//  v7/v10 are STREAMING finite-state machines: they classify each
//  sensor sample the moment it arrives and commit to "airborne" /
//  "landing" decisions in real time. That makes them fast but fragile
//  — a single accel spike from a board chop or a hand-wave can push the
//  FSM into a bad state and produce a phantom jump.
//
//  v11 takes the opposite trade: it accepts a SMALL DETECTION DELAY
//  (3–5 s) in exchange for a far more complete and reliable analysis.
//
//      Raw sensor / motion events
//              ↓  Event Normalization Layer        (normalize)
//      Session Event Buffer                        (JumpEventBufferV11)
//              ↓  Background analyzer every 3–5 s   (BufferedJumpAnalyzerV11)
//      Candidate segment detection                 (JumpCandidateSegmenterV11)
//              ↓  Start/end lifecycle pairing       (JumpStartEndDetectorV11)
//      Full jump segment analysis                  (JumpPhysicsAnalyzerV11)
//              ↓  Quality validation                (JumpQualityScorerV11)
//      Final jump event  →  Session metrics update
//
//  The background analyzer never commits a jump from a single spike. It
//  pulls the FULL motion sequence (pre-takeoff ride context → takeoff →
//  airborne → landing → post-landing continuation) out of the buffer and
//  analyses it end-to-end before scoring it 0–100 and deciding.
//
//  REPLAY / LIVE PARITY
//  --------------------
//  The "every 3–5 s" scheduler is driven by SAMPLE TIME, not a wall-clock
//  Timer. In the live app sample time advances in real time at 50 Hz, so
//  "every 3 s of sample time" ≈ every 3 s wall-clock. In the offline
//  JumpReplay harness the same code runs deterministically over recorded
//  logs. One implementation, two environments, identical results.
//
//  UNITS (watch-native — matches v7/v10):
//       accel  : g, gravity REMOVED (userAcceleration)
//       gyro   : rad/s
//       gravity: g (unit-ish vector)
//       baro   : hPa
// ================================================================

import Foundation

// ================================================================
// MARK: - Constants
// ================================================================
private enum K11 {
    static let g: Double          = 9.80665   // standard gravity (spec value)
    static let p2m: Double        = 8.43      // hPa → metres (sea level)
    static let sampleRate: Double = 50.0
    static let dt: Double         = 1.0 / 50.0
    static let ms2kn: Double      = 1.94384
    static let ms2kmh: Double     = 3.6
    static let rad2deg: Double    = 180.0 / .pi
    static let deg2rad: Double    = .pi / 180.0
    static let twoPi: Double      = 2.0 * .pi
}

// ================================================================
// MARK: - Sensor Sample (raw input, watch-native units)
//  Mirrors SensorSampleV10 so the v11 adapter can build it the same way,
//  with the addition of GPS course for heading-change analysis.
// ================================================================
struct SensorSampleV11 {
    let t: Double                 // monotonic seconds since session start
    let ax, ay, az: Double        // userAcceleration (g, gravity removed)
    let aM: Double?               // optional precomputed |a| (g)
    let gx, gy, gz: Double        // gyroscope (rad/s)
    let gM: Double?               // optional precomputed |ω| (rad/s)
    let gravX, gravY, gravZ: Double // gravity unit-ish vector (g)
    let baro: Double?             // barometric pressure (hPa), nil between updates
    let gpsSpeedMS: Double?
    let gpsLat: Double?
    let gpsLon: Double?
    let gpsAccuracyM: Double?
    let gpsCourse: Double?
    // Water submersion (Apple Watch Ultra · CMWaterSubmersionManager), ZOH-held.
    // nil when the sensor is unavailable — the engine then runs IMU-only.
    let submerged: Bool?
    let waterDepthM: Double?
    let waterPressureHPa: Double?

    init(t: Double,
         ax: Double, ay: Double, az: Double,
         aM: Double?,
         gx: Double, gy: Double, gz: Double,
         gM: Double?,
         gravX: Double, gravY: Double, gravZ: Double,
         baro: Double?,
         gpsSpeedMS: Double?,
         gpsLat: Double?,
         gpsLon: Double?,
         gpsAccuracyM: Double?,
         gpsCourse: Double?,
         submerged: Bool? = nil,
         waterDepthM: Double? = nil,
         waterPressureHPa: Double? = nil) {
        self.t = t
        self.ax = ax; self.ay = ay; self.az = az
        self.aM = aM
        self.gx = gx; self.gy = gy; self.gz = gz
        self.gM = gM
        self.gravX = gravX; self.gravY = gravY; self.gravZ = gravZ
        self.baro = baro
        self.gpsSpeedMS = gpsSpeedMS
        self.gpsLat = gpsLat
        self.gpsLon = gpsLon
        self.gpsAccuracyM = gpsAccuracyM
        self.gpsCourse = gpsCourse
        self.submerged = submerged
        self.waterDepthM = waterDepthM
        self.waterPressureHPa = waterPressureHPa
    }

    var accelMagG: Double { aM ?? (ax * ax + ay * ay + az * az).squareRoot() }
    var gyroMag: Double { gM ?? (gx * gx + gy * gy + gz * gz).squareRoot() }
}

// ================================================================
// MARK: - Normalized Surf Sensor Event (the buffered unit)
//  Produced by the Event Normalization Layer. Carries everything the
//  offline analysis needs without re-touching the raw stream.
// ================================================================
struct SurfSensorEventV11 {
    enum Source: String { case motion, gps, barometer, heading, derived }

    let t: Double                 // monotonic seconds

    // Acceleration (g)
    let ax, ay, az: Double
    let accelMag: Double          // |userAcceleration| (g)
    let gravMag: Double           // |gravity| (g, ~1 at rest)

    // Rotation (rad/s)
    let gx, gy, gz: Double
    let rotMag: Double

    // GPS
    let gpsSpeed: Double?
    let gpsLat: Double?
    let gpsLon: Double?
    let gpsAccuracy: Double?
    let gpsCourse: Double?

    // Barometer
    let baro: Double?

    // Derived
    /// Gravity-projected vertical accel in g: ~1 at rest, ~0 in free-fall,
    /// >1 on impact. Robust to wrist rotation (projects onto −gravity).
    let verticalAccelG: Double
    /// Signed gravity-projected vertical load in g. Unlike `verticalAccelG`,
    /// this preserves direction for inertial height integration.
    let signedVerticalLoadG: Double
    let motionEnergy: Double       // accelMag² proxy
    let rotationEnergy: Double     // rotMag² proxy

    // Water submersion (Apple Watch Ultra), ZOH-held from CMWaterSubmersionManager.
    // `submerged == false` is a direct "board/rider out of the water" signal — the
    // ground-truth airtime bracket. nil ⇒ sensor unavailable, engine runs IMU-only.
    let submerged: Bool?
    let waterDepthM: Double?
    let waterPressureHPa: Double?

    // ── Speed freshness (v11.1) ──
    // The kslog stores speed at a different cadence than the 50 Hz IMU and a
    // sensorOnly=true upload may omit the GPS route entirely. Repeated speed
    // values are NOT fresh 50 Hz fixes, so we carry the age of the last *change*
    // and treat stale/absent speed as low-confidence context, never a hard gate.
    var speedAgeSec: Double = .infinity   // seconds since speed last changed
    var speedFresh: Bool = false          // set by the session from speedAgeSec

    init(t: Double,
         ax: Double, ay: Double, az: Double,
         accelMag: Double,
         gravMag: Double,
         gx: Double, gy: Double, gz: Double,
         rotMag: Double,
         gpsSpeed: Double?,
         gpsLat: Double?,
         gpsLon: Double?,
         gpsAccuracy: Double?,
         gpsCourse: Double?,
         baro: Double?,
         verticalAccelG: Double,
         signedVerticalLoadG: Double,
         motionEnergy: Double,
         rotationEnergy: Double,
         submerged: Bool? = nil,
         waterDepthM: Double? = nil,
         waterPressureHPa: Double? = nil,
         speedAgeSec: Double = .infinity,
         speedFresh: Bool = false) {
        self.t = t
        self.ax = ax; self.ay = ay; self.az = az
        self.accelMag = accelMag
        self.gravMag = gravMag
        self.gx = gx; self.gy = gy; self.gz = gz
        self.rotMag = rotMag
        self.gpsSpeed = gpsSpeed
        self.gpsLat = gpsLat
        self.gpsLon = gpsLon
        self.gpsAccuracy = gpsAccuracy
        self.gpsCourse = gpsCourse
        self.baro = baro
        self.verticalAccelG = verticalAccelG
        self.signedVerticalLoadG = signedVerticalLoadG
        self.motionEnergy = motionEnergy
        self.rotationEnergy = rotationEnergy
        self.submerged = submerged
        self.waterDepthM = waterDepthM
        self.waterPressureHPa = waterPressureHPa
        self.speedAgeSec = speedAgeSec
        self.speedFresh = speedFresh
    }

    static func normalize(_ s: SensorSampleV11) -> SurfSensorEventV11 {
        let aMag = s.accelMagG
        let gMag = (s.gravX * s.gravX + s.gravY * s.gravY + s.gravZ * s.gravZ).squareRoot()
        // Project userAccel onto the up axis (−gravity) and add |g| → ~1 at rest.
        let signedLoad: Double
        if gMag > 0.01 {
            let dot = (s.ax * s.gravX + s.ay * s.gravY + s.az * s.gravZ) / gMag
            signedLoad = dot + gMag
        } else {
            signedLoad = aMag
        }
        let rMag = s.gyroMag
        return SurfSensorEventV11(
            t: s.t,
            ax: s.ax, ay: s.ay, az: s.az,
            accelMag: aMag, gravMag: gMag,
            gx: s.gx, gy: s.gy, gz: s.gz, rotMag: rMag,
            gpsSpeed: s.gpsSpeedMS, gpsLat: s.gpsLat, gpsLon: s.gpsLon,
            gpsAccuracy: s.gpsAccuracyM, gpsCourse: s.gpsCourse,
            baro: s.baro,
            verticalAccelG: abs(signedLoad),
            signedVerticalLoadG: signedLoad,
            motionEnergy: aMag * aMag,
            rotationEnergy: rMag * rMag,
            submerged: s.submerged,
            waterDepthM: s.waterDepthM,
            waterPressureHPa: s.waterPressureHPa
        )
    }
}

// ================================================================
// MARK: - Lifecycle hint events (treated as evidence, never trusted blindly)
// ================================================================
struct JumpLifecycleEventV11 {
    enum Kind: String {
        case potentialJumpStart  = "POTENTIAL_JUMP_START"
        case potentialTakeoff    = "POTENTIAL_TAKEOFF"
        case potentialAirborne   = "POTENTIAL_AIRBORNE"
        case potentialLanding    = "POTENTIAL_LANDING"
        case potentialJumpEnd    = "POTENTIAL_JUMP_END"
    }
    let t: Double
    let kind: Kind
    let confidence: Double
    let reasonCodes: [String]
}

// ================================================================
// MARK: - Candidate segment (a hypothesis, not yet a jump)
// ================================================================
struct JumpCandidateSegmentV11 {
    struct Supporting {
        var speedBefore: Double?
        var speedAfter: Double?
        var maxAcceleration: Double?
        var minVerticalG: Double?
        var maxRotationRate: Double?
        var altitudeDelta: Double?
        var estimatedAirTimeSec: Double?
    }
    var startTime: Double
    var endTime: Double
    var takeoffTime: Double?
    var landingTime: Double?
    var reasonCodes: [String]
    var confidence: Double
    var supporting: Supporting
    // Raw flags captured during segmentation (used by the scorer).
    var sawAirbornePhase: Bool
    var sawLandingImpact: Bool
    var landingKind: JumpResultV11.LandingKind
    var lifecycle: [JumpLifecycleEventV11]
}

// ================================================================
// MARK: - Physics result (full end-to-end analysis of one segment)
// ================================================================
struct JumpPhysicsResultV11 {
    var takeoffTime: Double
    var landingTime: Double
    var airTimeSec: Double
    var estimatedHeightMeters: Double
    var heightFromAirtime: Double
    var heightFromAltitude: Double?
    var inertialHeightMeters: Double?
    var inertialQuality: Double
    var inertialApexTimeSec: Double?
    var inertialLandingTimeSec: Double?
    var speedBeforeTakeoff: Double?
    var speedAfterLanding: Double?
    var speedDelta: Double?
    var distanceMeters: Double?
    var distanceGPSMeters: Double?
    var maxAccelerationG: Double
    var landingImpactG: Double
    var minVerticalG: Double
    var maxRotationRate: Double
    var airborneSec: Double         // sustained free-fall duration within the air phase
    var totalRotationDegrees: Double
    var rotationAxis: String        // "yaw" | "pitch" | "roll" | "mixed"
    var rotations: Int
    var altitudeDeltaMeters: Double?
    var apexTimeSec: Double?
    var motionEnergy: Double
    var rotationEnergy: Double
    var heightSource: JumpResultV11.HeightSource
    var confidence: Double          // physics-level 0…1 (scorer is authoritative)

    // ── v11.1 ranking inputs ─────────────────────────────────────
    var baroBaselineHPa: Double?    // local baseline pressure before take-off
    var baroMinHPa: Double?         // lowest pressure during the airborne window
    var baroDropHPa: Double?        // baseline − min (positive = went up)
    var baroRecovered: Bool         // pressure returned toward baseline after landing
    var baroHeightMeters: Double?   // drop · p2m (primary height when present)
    var baroQuality: Double         // 0…1 height-confidence from baro magnitude/recovery
    var accelEnergyBefore: Double   // mean accel² in the pre-takeoff window
    var accelEnergyDuring: Double   // mean accel² over the airborne window
    var accelEnergyAfter: Double    // mean accel² in the post-landing window
    var gyroEnergyDuring: Double    // mean rotation² over the airborne window
    var postLandingContinuation: Double // ride-motion energy after landing (0…1)
    var speedFresh: Bool            // riding speed near take-off was fresh
    var speedContextMS: Double?     // the fresh riding speed used, if any
}

// ================================================================
// MARK: - Quality score (0–100, the authoritative accept/reject gate)
// ================================================================
struct JumpQualityScoreV11 {
    struct Components {
        var takeoffConfidence: Double = 0
        var airborneConfidence: Double = 0
        var landingConfidence: Double = 0
        var sensorAgreement: Double = 0
        var gpsQuality: Double = 0
        var rotationQuality: Double = 0
        var falsePositivePenalty: Double = 0
    }
    enum Label: String { case weak, valid, strong, excellent }
    var total: Double
    var components: Components
    var label: Label
    var reasonCodes: [String]
}

// ================================================================
// MARK: - Final jump result emitted to the adapter
// ================================================================
struct JumpResultV11 {
    enum LandingKind: String { case hardImpact, settle, baroRecovery, timeout, none }
    enum HeightSource: String { case kinematic, barometric, inertial, blended }

    let takeoffTimeSeconds: Double
    let landingTimeSeconds: Double
    let airTimeSeconds: Double
    let jumpHeightMeters: Double
    let baroHeightMeters: Double?
    let baroQuality: Double
    let kinematicHeightMeters: Double
    let inertialHeightMeters: Double?
    let inertialQuality: Double
    let inertialApexTimeSeconds: Double?
    let inertialLandingTimeSeconds: Double?
    let apexTimeSeconds: Double?
    let rotations: Int
    let totalRotationDegrees: Double
    let rotationAxis: String
    let speedBeforeTakeoff: Double?
    let speedAfterLanding: Double?
    let jumpDistanceMeters: Double?
    let jumpDistanceGPSMeters: Double?
    let maxAccelerationG: Double
    let landingImpactG: Double
    let maxRotationRate: Double
    let altitudeDeltaMeters: Double?
    let maxSessionSpeedKnots: Double
    let maxSessionSpeedKmh: Double
    let confidence: Double          // 0…1 (== score / 100)
    let score: Double               // 0…100
    let label: String
    let reasonCodes: [String]
    let landingKind: LandingKind
    let heightSource: HeightSource
}

// ================================================================
// MARK: - Debug record for every accepted AND rejected segment
// ================================================================
struct JumpSegmentDebugV11: Codable {
    struct Metrics: Codable {
        var airTimeMs: Double
        var estimatedHeightMeters: Double
        var heightSource: String
        var baroHeightMeters: Double?
        var baroQuality: Double
        var inertialHeightMeters: Double?
        var inertialQuality: Double
        var inertialApexTimeSec: Double?
        var inertialLandingTimeSec: Double?
        var speedBefore: Double?
        var speedAfter: Double?
        var maxAccelerationG: Double
        var landingImpactG: Double
        var totalRotationDegrees: Double
        var minVerticalG: Double
        var airborneMs: Double
        var maxRotationRate: Double
    }
    var segmentStart: Double
    var segmentEnd: Double
    var decision: String            // "accepted" | "rejected"
    var score: Double
    var label: String
    var reasonCodes: [String]
    var metrics: Metrics
}

// ================================================================
// MARK: - Config (every threshold is tunable)
// ================================================================
struct JumpEngineV11Config {
    // ── Buffer ───────────────────────────────────────────────────
    var bufferRetentionSec   = 60.0
    var preJumpContextSec    = 1.5
    // Real-time budget: a jump must display within ~5 s of landing. The analyzer
    // waits only this long after the landing for post-context (ride resume + baro
    // recovery), then analyses on the next tick — NOT a worst-case airtime.
    var postJumpContextSec   = 2.0
    var analysisIntervalSec  = 2.0      // background analyzer cadence (every 2 s)
    var analysisWindowSec    = 12.0     // recent span scanned each tick

    // ── Segmentation (kite-aware, adaptive) ──────────────────────
    var releaseFloorG        = 1.30     // take-off spike floor (g)
    var releaseSigmaK        = 3.5      // adaptive: μ_ride + K·σ_ride
    var gyroReleaseFloor     = 1.5      // a real launch spins the wrist (rad/s)
    var landingSpikeG        = 2.00     // hard-landing impact (g) — must clear chop
    var landingSearchMinSec  = 1.00     // don't look for the landing until truly airborne
    var landingImpactSigmaK  = 4.0      // impact must also clear μ_ride + K·σ_ride
    var lowGCeiling          = 0.55     // verticalAccelG below this = airborne
    // Rate-adaptive: confirm airborne after this DURATION of sustained low-g, not
    // a fixed sample count. At 50 Hz this is 2 samples (the original tuning); at
    // CMBatchedSensorManager's 200 Hz it becomes 8 samples automatically, so the
    // gate means the same thing regardless of stream rate.
    var lowGConfirmSec       = 0.04     // was: lowGConfirmCount = 2 @ 50 Hz
    // A genuine jump has a true free-fall moment (vertical-g near 0) and a
    // wrist-spinning launch. Hard carves / chop only dip to ~0.15 g and spin
    // less, so these two gates are the strongest real-vs-false separators found
    // empirically on labelled (Surfr-referenced) sessions.
    var airborneDepthMax     = 0.10     // deepest vertical-g must reach below this
    var minTakeoffRotation   = 3.0      // rad/s — peak rotation a real launch shows
    var settleTolG           = 0.35     // |a−rideMean| within this = settled
    var settleSec            = 0.12     // rate-adaptive settle duration (was: 6 samples @ 50 Hz)
    var rideStatWindowSec    = 1.5
    var submersionTransitionToleranceSec = 1.0 // align 3 Hz water updates to IMU takeoff/landing

    // ── Physics gates ────────────────────────────────────────────
    var minAirTimeSec        = 0.25     // segmenter: earliest a landing may be declared
    var minValidAirtimeSec   = 2.1      // HARD filter: a valid jump must be airborne ≥ this
    // HARD noise filters derived empirically from labelled logs (TP vs FP): a
    // real jump always shows at least a modest landing impact and peak force.
    // Background noise (chop/carving wobble) falls below these.
    var minLandingImpactG    = 1.2      // weakest labelled landing still has clear force
    var minPeakAccelG        = 2.0      // weakest real-jump peak acceleration (log2 #4 ≈ 2.10)
    // Kite jumps span a wide airtime range: small hops ~2 s, big boosted/lofted
    // jumps reach ~5 s. The filter must cover BOTH sessions — narrow gates tuned
    // to one session silently drop the other's jumps. Discrimination belongs in
    // the scorer, not in narrow hard gates.
    var maxValidAirtimeSec   = 6.0      // HARD filter: airborne longer than this is not a kite jump
    var maxAirTimeSec        = 6.0      // segmenter scan envelope
    var minRidingSpeedMS     = 2.0      // GPS speed before jump
    var gpsAccuracyMaxM      = 25.0     // ignore GPS worse than this
    var baroNoiseFloorHPa    = 0.03     // below this baro is pure noise
    var kinematicCalibration = 1.0

    // ── Rotation realism ─────────────────────────────────────────
    // A real kite jump rotates SLOWLY (labelled logs: ≤116°/s); background noise
    // — carving, board wobble, hand motion — spins much faster. This is one of
    // the strongest noise separators found in the pure-noise zone (first 10 min
    // of log 20260626, where every detection is false).
    var maxRotationDegPerAirSec = 120.0

    // ── Kite-aware height ────────────────────────────────────────
    // A kite holds the rider up, so the descent lasts LONGER than the ascent
    // and the symmetric time-of-flight estimate g·t²/8 over-reports height on
    // boosted/looped jumps. The headline height is therefore based on the RISE
    // time (take-off → apex). When no apex is found we assume the ascent is this
    // fraction of total airtime (kitesurf-typical asymmetric arc).
    var ascentFraction       = 0.35
    var minAscentFraction    = 0.22     // rise time floor (× airtime) — guards against noisy apex
    // Low-speed / sensor-only sessions under-report inertial height because the
    // watch often sees a damped body trajectory rather than the board/rider apex.
    // Keep the estimator physically pure and apply this only at headline fusion.
    var inertialSlowSpeedMaxMS = 5.0
    var inertialSlowSpeedCalibration = 1.25

    // ── Scoring thresholds ───────────────────────────────────────
    var acceptScore          = 60.0
    var strongScore          = 75.0
    var excellentScore       = 90.0
    var duplicateWindowSec   = 1.5      // jumps closer than this = duplicate
    // Hard cooldown after an accepted jump: real boosted jumps are seconds-to-
    // minutes apart, so a single airborne event must not be re-emitted as several
    // jumps from its sub-spikes. Candidates whose take-off falls within this
    // window of the last accepted take-off are suppressed outright.
    var cooldownSec          = 5.0

    // ── False-positive penalties (all tunable) ───────────────────
    // A clean 3-phase jump scores 60 (takeoff+airborne+landing). These
    // penalties must be strong enough to push true false positives below the
    // accept threshold. Low riding speed is the single most decisive signal
    // that a "jump" is really watch handling / a stationary artefact, so it
    // is weighted heavily.
    var penaltyTooShortAirtime   = 30.0
    var penaltyUnrealisticAirtime = 30.0
    var penaltyNoLanding         = 30.0
    var penaltyNoAirborne        = 25.0
    var penaltyLowRidingSpeed    = 35.0
    var penaltyCarvePattern      = 25.0
    var penaltyUnrealisticRotation = 30.0
    var penaltyDuplicate         = 20.0

    // ════════════════════════════════════════════════════════════
    // v11.1 — Surfr-calibrated clustering + ranking pipeline
    // ════════════════════════════════════════════════════════════
    // v11.1 lets the segmenter OVER-detect raw candidates, then a ranking
    // scorer + non-maximum-suppression clusterer pick the best candidate per
    // temporal cluster. Speed is contextual confidence only (never a hard gate),
    // and height comes from the barometric pressure profile, not ballistic
    // airtime. All knobs below are tunable from the evaluation harness.

    // ── Clustering (NMS) ─────────────────────────────────────────
    var clusterWindowSec        = 15.0   // group candidates within this span (a single
                                         // jump's sub-spikes); wider would let a strong
                                         // nearby false positive swallow a real jump.
    // Emit wait: how long after a cluster's end to hold before emitting its winner
    // (lets all of one jump's sub-spikes land in the cluster first). Kept short for
    // the ≤5 s display budget — a single jump's sub-spikes are all within its
    // airtime, so they are already buffered by the time we analyse.
    var clusterSettleSec        = 2.0
    var clusterMinSeparationSec = 8.0    // two winners need ≥ this gap + distinct evidence

    // ── Speed freshness (contextual, not a gate) ─────────────────
    var speedStaleAfterSec      = 4.0    // speed older than this is "stale"

    // ── Barometric height (primary) ──────────────────────────────
    var baroBaselinePreSec      = 25.0   // rolling local baseline window before take-off
    var baroBaselineGuardSec    = 2.0    // exclude immediate pre-takeoff pressure sag
    var baroHeightSearchSec     = 8.0    // height-only pressure-min search after takeoff.
                                         // The apex (pressure min) is within the airtime
                                         // (≤ maxValidAirtimeSec), so this need only cover
                                         // the flight + a little baro lag — keeping it small
                                         // is what lets analysis start within the 5 s budget.
    var baroP2M                 = 8.43   // hPa → metres
    var baroHeightCalibration   = 1.0
    var baroMinDropHPa          = 0.04   // drop below this = no measurable baro height

    // ── Ranking scorer weights (0–100 composite) ─────────────────
    var wBaroProfile            = 24.0   // clean drop→recovery around the airborne window
    var wLandingImpact          = 22.0   // landing spike confidence (real touchdown is hard)
    var wImpactPower            = 22.0   // peak acceleration — a real jump carries real force
    var wGyroEnergy             = 4.0    // rotation: WEAK signal (carving spins MORE than jumps)
    var wPostLanding            = 8.0    // ride continues after landing
    var wAccelContrast          = 8.0    // event stands out from the ride baseline
    var wSpeedContext           = 8.0    // fresh, plausible riding speed
    var wSensorStability        = 6.0    // not chaotic / not clipped
    var wSubmersionBracket      = 12.0   // surfaced -> submerged bracket around airtime
    var impactPowerLoG          = 2.0    // maxAccel mapped 0→1 across this …
    var impactPowerHiG          = 5.0    // … to this
    var rankAcceptScore         = 35.0   // cluster winner accepted at/above this.
                                         // Recall-first: the weakest true Surfr jump on
                                         // the labelled logs scores ~38, so 35 keeps full
                                         // recall on both. Precision is raised separately
                                         // by the impact-power scoring + (future) ML filter.
    var penaltyStaleSpeed       = 14.0   // soft: stale/missing speed lowers confidence
    var penaltyLowSpeedContext  = 14.0   // fresh but too slow for confident riding context
    var penaltyNoPostLandingRide = 20.0  // landing not followed by resumed ride motion
    var penaltyLowHeadlineHeight = 35.0  // tiny measured height is weak jump evidence
    var penaltyWeakLongLowHeight = 42.0  // long airtime + low height + weak impact pattern
    var penaltyBaroCapNoInertial = 25.0  // near-cap baro height without inertial support
    var penaltyLongNoScoreBaro   = 16.0  // broad baro height without in-window pressure event
    var penaltyFastLongLowMeasured = 25.0 // fast near-max airtime with modest measured height
    var penaltySlowWeakMeasured  = 15.0  // slow, weak-impact, modest-height artefact
    var useClusteringPipeline   = true   // v11.1 path; false = legacy v11 gate path

    static let `default` = JumpEngineV11Config()
}

// ================================================================
// MARK: - Tiny DSP helpers (V11-scoped to avoid collisions)
// ================================================================
enum DSPV11 {
    static func median(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        var s = a; s.sort(); let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }
    static func median(_ a: ArraySlice<Double>) -> Double { median(Array(a)) }
    static func percentile(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        var s = a; s.sort()
        let q = clamp(p, 0, 1)
        let idx = Int((Double(s.count - 1) * q).rounded())
        return s[min(max(idx, 0), s.count - 1)]
    }
    static func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
    static func std(_ a: [Double]) -> Double {
        guard a.count > 1 else { return 0 }
        let m = mean(a)
        return (a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count)).squareRoot()
    }
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, v)) }
    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return r * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
    static func estimateDt(_ ev: [SurfSensorEventV11]) -> Double {
        guard ev.count >= 6 else { return K11.dt }
        var diffs = [Double]()
        for i in 1..<min(40, ev.count) {
            let d = ev[i].t - ev[i - 1].t
            // Lower bound is 0.5 ms so CMBatchedSensorManager rates (200 Hz = 5 ms,
            // 800 Hz = 1.25 ms) are measured as real, not rejected and silently
            // treated as 50 Hz — which would break every sample-count-derived gate.
            if d > 0.0005, d < 0.5 { diffs.append(d) }
        }
        return diffs.count > 3 ? median(diffs) : K11.dt
    }
}

// ================================================================
// MARK: - 1. JumpEventBuffer — the session event buffer
// ================================================================
/// Stores all normalized motion/GPS/baro events during a live session.
/// Bounded by time pruning so it stays efficient over long sessions, and
/// remembers which time ranges have been processed so the same jump is
/// never analysed twice.
final class JumpEventBufferV11 {
    private(set) var events: [SurfSensorEventV11] = []
    private var processed: [(start: Double, end: Double)] = []

    func append(_ e: SurfSensorEventV11) { events.append(e) }

    var latestTime: Double? { events.last?.t }
    var count: Int { events.count }

    /// All events whose timestamp falls in [startTime, endTime].
    func getEventsBetween(_ startTime: Double, _ endTime: Double) -> [SurfSensorEventV11] {
        guard startTime <= endTime else { return [] }
        // events are appended in time order → binary-search the bounds.
        let lo = lowerBound(startTime)
        var out: [SurfSensorEventV11] = []
        var i = lo
        while i < events.count, events[i].t <= endTime {
            out.append(events[i]); i += 1
        }
        return out
    }

    /// The last `windowSec` of events relative to the most recent sample.
    func getRecentEvents(_ windowSec: Double) -> [SurfSensorEventV11] {
        guard let last = events.last else { return [] }
        return getEventsBetween(last.t - windowSec, last.t)
    }

    func markSegmentAsProcessed(_ startTime: Double, _ endTime: Double) {
        processed.append((startTime, endTime))
    }

    /// True if a candidate overlaps a previously processed segment (dedupe).
    func segmentWasProcessed(_ startTime: Double, _ endTime: Double, tolerance: Double) -> Bool {
        for p in processed {
            // overlap if the takeoff anchors are within tolerance OR ranges intersect
            let intersects = startTime <= p.end + tolerance && endTime >= p.start - tolerance
            if intersects { return true }
        }
        return false
    }

    func pruneOldEvents(_ maxAgeSec: Double) {
        guard let last = events.last else { return }
        let cutoff = last.t - maxAgeSec
        if let firstKeep = events.firstIndex(where: { $0.t >= cutoff }), firstKeep > 0 {
            events.removeFirst(firstKeep)
        }
        processed.removeAll { $0.end < cutoff }
    }

    func clear() { events.removeAll(keepingCapacity: true); processed.removeAll(keepingCapacity: true) }

    // First index with t >= target (events sorted ascending by t).
    private func lowerBound(_ target: Double) -> Int {
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].t < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// ================================================================
// MARK: - 2. JumpCandidateSegmenter — find jump hypotheses
// ================================================================
/// Scans a window of normalized events and proposes candidate segments
/// using a COMBINATION of signals (riding speed + adaptive release spike +
/// gyro energy + low-g airborne phase + landing). A candidate is only the
/// start of the conversation — the physics analyzer and scorer decide.
struct JumpCandidateSegmenterV11 {
    let cfg: JumpEngineV11Config

    private struct SubmersionBracket {
        let takeoffIdx: Int
        let landingIdx: Int
    }

    func findCandidateSegments(_ ev: [SurfSensorEventV11]) -> [JumpCandidateSegmentV11] {
        let n = ev.count
        guard n >= 12 else { return [] }
        let dt = DSPV11.estimateDt(ev)
        let rideStatN = max(8, Int((cfg.rideStatWindowSec / dt).rounded()))
        let maxAS = max(2, Int((cfg.maxAirTimeSec / dt).rounded()))
        let minAS = max(1, Int((cfg.minAirTimeSec / dt).rounded()))
        // Sample-count gates derived from durations so they hold at any stream rate
        // (50 Hz CMMotionManager or 200 Hz CMBatchedSensorManager).
        let lowGConfirmCount = max(1, Int((cfg.lowGConfirmSec / dt).rounded()))
        let settleSamplesNeeded = max(2, Int((cfg.settleSec / dt).rounded()))

        var out: [JumpCandidateSegmentV11] = []
        var i = 2
        while i < n - 2 {
            // ── adaptive release threshold from the preceding ride tail ──
            let lo = max(0, i - rideStatN)
            let rideSlice = ev[lo..<i].map { $0.accelMag }
            let rideMean = DSPV11.median(rideSlice)
            let rideStd  = DSPV11.std(rideSlice)
            let releaseThr = max(cfg.releaseFloorG, rideMean + cfg.releaseSigmaK * max(rideStd, 0.05))

            let isRelease = ev[i].accelMag >= releaseThr && ev[i].rotMag >= cfg.gyroReleaseFloor
            if !isRelease { i += 1; continue }

            // ── candidate take-off at i ──
            let takeoffIdx = i
            var reasons = ["TAKEOFF_IMPULSE_DETECTED"]
            var sawAirborne = false
            var lowGRun = 0
            var landingIdx = -1
            var landingKind: JumpResultV11.LandingKind = .none
            var settleRun = 0, settleIdx = -1
            var minVertG = ev[takeoffIdx].verticalAccelG

            // Landing impact must clear BOTH an absolute floor and the ride
            // statistics, so ordinary chop (which routinely crosses 1.6 g) is
            // not mistaken for a touchdown.
            let impactThr = max(cfg.landingSpikeG, rideMean + cfg.landingImpactSigmaK * max(rideStd, 0.05))
            let landingSearchMinAS = max(minAS, Int((cfg.landingSearchMinSec / dt).rounded()))

            // Scan the airborne envelope (bounded to the max valid airtime) and
            // take the STRONGEST impact spike after a real minimum airtime as the
            // touchdown. Within a real jump the landing impact dominates the chop,
            // so the strongest spike is the most reliable landing marker — and
            // bounding the search stops late post-landing chop from inflating the
            // air time. A calm-settle fallback covers soft (no-impact) landings.
            let maxLandingAS = max(landingSearchMinAS + 1, Int((cfg.maxValidAirtimeSec / dt).rounded()))
            var bestImpactIdx = -1, bestImpactAccel = 0.0
            var j = takeoffIdx + 1
            while j < n && (j - takeoffIdx) <= min(maxAS, maxLandingAS) {
                minVertG = min(minVertG, ev[j].verticalAccelG)

                if ev[j].verticalAccelG < cfg.lowGCeiling {
                    lowGRun += 1
                    if lowGRun >= lowGConfirmCount && !sawAirborne {
                        sawAirborne = true
                        reasons.append("AIRBORNE_PHASE_DETECTED")
                    }
                } else {
                    lowGRun = 0
                }

                if (j - takeoffIdx) >= landingSearchMinAS {
                    // Strongest impact in the bounded window = the touchdown.
                    if ev[j].accelMag >= impactThr && ev[j].accelMag > bestImpactAccel {
                        bestImpactIdx = j; bestImpactAccel = ev[j].accelMag
                    }
                    // Settle fallback (soft landing, no impact spike).
                    if settleIdx < 0 {
                        if abs(ev[j].accelMag - rideMean) < cfg.settleTolG && ev[j].rotMag < cfg.gyroReleaseFloor * 4 {
                            settleRun += 1
                            if settleRun >= settleSamplesNeeded { settleIdx = j - settleRun + 1 }
                        } else {
                            settleRun = 0
                        }
                    }
                }
                j += 1
            }

            if bestImpactIdx >= 0 {
                // Landing = strongest impact before the rider settled.
                landingIdx = bestImpactIdx; landingKind = .hardImpact
                reasons.append("LANDING_IMPACT_DETECTED")
            } else if settleIdx >= 0 {
                landingIdx = settleIdx; landingKind = .settle
                reasons.append("LANDING_SETTLE_DETECTED")
            } else {
                // no landing within the air-time envelope → timeout candidate.
                landingIdx = min(n - 1, takeoffIdx + maxAS)
                landingKind = .timeout
                reasons.append("REJECT_NO_LANDING_IMPACT")
            }
            if !sawAirborne { reasons.append("REJECT_NO_AIRBORNE_PHASE") }

            var segmentTakeoffIdx = takeoffIdx
            var segmentLandingIdx = landingIdx
            var usedSubmersionBracket = false
            if let bracket = submersionBracket(in: ev,
                                               around: takeoffIdx,
                                               proposedLandingIdx: landingIdx) {
                segmentTakeoffIdx = bracket.takeoffIdx
                segmentLandingIdx = bracket.landingIdx
                landingIdx = max(landingIdx, bracket.landingIdx)
                sawAirborne = true
                usedSubmersionBracket = true
                reasons.append("SUBMERSION_AIRTIME_BRACKET")
                if landingKind == .timeout {
                    landingKind = .settle
                    reasons.append("LANDING_SUBMERSION_RETURN")
                }
            }

            let takeoffT = ev[segmentTakeoffIdx].t
            let landingT = ev[segmentLandingIdx].t
            let supporting = JumpCandidateSegmentV11.Supporting(
                speedBefore: nearestSpeed(ev, around: segmentTakeoffIdx),
                speedAfter: nearestSpeed(ev, around: segmentLandingIdx),
                maxAcceleration: ev[segmentTakeoffIdx...segmentLandingIdx].map { $0.accelMag }.max(),
                minVerticalG: minVertG,
                maxRotationRate: ev[segmentTakeoffIdx...segmentLandingIdx].map { $0.rotMag }.max(),
                altitudeDelta: nil,
                estimatedAirTimeSec: landingT - takeoffT
            )

            out.append(JumpCandidateSegmentV11(
                startTime: takeoffT,
                endTime: landingT,
                takeoffTime: takeoffT,
                landingTime: landingT,
                reasonCodes: reasons,
                confidence: usedSubmersionBracket ? 0.85 : (sawAirborne && landingKind != .timeout ? 0.7 : 0.3),
                supporting: supporting,
                sawAirbornePhase: sawAirborne,
                sawLandingImpact: landingKind == .hardImpact,
                landingKind: landingKind,
                lifecycle: []
            ))

            // advance past this landing to avoid re-triggering on the same motion
            i = max(landingIdx + 1, takeoffIdx + minAS)
        }
        return out
    }

    private func submersionBracket(in ev: [SurfSensorEventV11],
                                   around takeoffIdx: Int,
                                   proposedLandingIdx: Int) -> SubmersionBracket? {
        guard ev.indices.contains(takeoffIdx),
              ev.contains(where: { $0.submerged != nil }) else { return nil }

        let releaseT = ev[takeoffIdx].t
        let proposedLandingT = ev[min(max(proposedLandingIdx, 0), ev.count - 1)].t
        let searchStart = releaseT - cfg.submersionTransitionToleranceSec
        let searchEnd = releaseT + cfg.maxValidAirtimeSec + cfg.submersionTransitionToleranceSec

        var lastState: Bool?
        var surfaceStartIdx: Int?
        var best: SubmersionBracket?
        var bestScore = Double.infinity

        for i in ev.indices where ev[i].t >= searchStart && ev[i].t <= searchEnd {
            guard let state = ev[i].submerged else { continue }
            defer { lastState = state }

            if lastState == true && state == false {
                surfaceStartIdx = i
            } else if lastState == false && state == true, let startIdx = surfaceStartIdx {
                let air = ev[i].t - ev[startIdx].t
                guard air >= cfg.minAirTimeSec, air <= cfg.maxValidAirtimeSec else {
                    surfaceStartIdx = nil
                    continue
                }

                let startsNearRelease = abs(ev[startIdx].t - releaseT) <= cfg.submersionTransitionToleranceSec
                let releaseInsideSurfaceRun = releaseT >= ev[startIdx].t - 0.25 && releaseT <= ev[i].t + 0.25
                guard startsNearRelease || releaseInsideSurfaceRun else {
                    surfaceStartIdx = nil
                    continue
                }

                let score = abs(ev[startIdx].t - releaseT) + 0.25 * abs(ev[i].t - proposedLandingT)
                if score < bestScore {
                    bestScore = score
                    best = SubmersionBracket(takeoffIdx: startIdx, landingIdx: i)
                }
                surfaceStartIdx = nil
            }
        }

        return best
    }

    private func nearestSpeed(_ ev: [SurfSensorEventV11], around idx: Int) -> Double? {
        let t = ev[idx].t
        var best: Double? = nil
        var bestDt = Double.infinity
        for e in ev {
            guard let spd = e.gpsSpeed, spd.isFinite, spd >= 0 else { continue }
            if let acc = e.gpsAccuracy, acc > cfg.gpsAccuracyMaxM { continue }
            let d = abs(e.t - t)
            if d < bestDt { bestDt = d; best = spd }
        }
        return bestDt <= 3.0 ? best : nil
    }
}

// ================================================================
// MARK: - 3. JumpStartEndDetector — lifecycle hint pairing
// ================================================================
/// Derives the POTENTIAL_* lifecycle hints for a segment. These are HINTS:
/// they feed the scorer as supporting evidence and are never the final
/// decision on their own.
struct JumpStartEndDetectorV11 {
    let cfg: JumpEngineV11Config

    func lifecycle(for expanded: [SurfSensorEventV11],
                   takeoffTime: Double,
                   landingTime: Double) -> [JumpLifecycleEventV11] {
        guard !expanded.isEmpty else { return [] }
        var events: [JumpLifecycleEventV11] = []

        // POTENTIAL_JUMP_START — the last ride sample before take-off.
        if let preIdx = expanded.lastIndex(where: { $0.t < takeoffTime }) {
            events.append(.init(t: expanded[preIdx].t, kind: .potentialJumpStart,
                                confidence: 0.5, reasonCodes: ["RIDE_PRE_TAKEOFF"]))
        }
        // POTENTIAL_TAKEOFF — at/just after the release spike.
        if let toIdx = expanded.firstIndex(where: { $0.t >= takeoffTime }) {
            events.append(.init(t: expanded[toIdx].t, kind: .potentialTakeoff,
                                confidence: 0.7, reasonCodes: ["RELEASE_SPIKE"]))
        }
        // POTENTIAL_AIRBORNE — deepest free-fall sample within the air phase.
        let airSlice = expanded.filter { $0.t > takeoffTime && $0.t < landingTime }
        if let apex = airSlice.min(by: { $0.verticalAccelG < $1.verticalAccelG }),
           apex.verticalAccelG < cfg.lowGCeiling {
            events.append(.init(t: apex.t, kind: .potentialAirborne,
                                confidence: 0.7, reasonCodes: ["LOW_G_AIRBORNE"]))
        }
        // POTENTIAL_LANDING — at the landing time.
        if let landIdx = expanded.firstIndex(where: { $0.t >= landingTime }) {
            events.append(.init(t: expanded[landIdx].t, kind: .potentialLanding,
                                confidence: 0.6, reasonCodes: ["LANDING"]))
        }
        // POTENTIAL_JUMP_END — first settled ride sample after landing.
        if let endIdx = expanded.lastIndex(where: { $0.t >= landingTime }) {
            events.append(.init(t: expanded[endIdx].t, kind: .potentialJumpEnd,
                                confidence: 0.5, reasonCodes: ["POST_LANDING_RIDE"]))
        }
        return events
    }
}

// ================================================================
// MARK: - BarometerCalibration — local pressure profile (v11.1)
// ================================================================
/// Computes a LOCAL barometric profile around a candidate so height does not
/// depend on a global/sentinel baseline that may be missing. Returns the
/// rolling baseline before take-off, the minimum during the airborne window,
/// the drop, and whether pressure recovered toward baseline after landing
/// (a real jump goes up then comes back down).
enum BarometerCalibrationV11 {
    struct Profile {
        var baselineHPa: Double?
        var minHPa: Double?
        var dropHPa: Double?
        var recovered: Bool
    }

    static func heightProfile(_ ev: [SurfSensorEventV11], t0: Int, tl: Int, cfg: JumpEngineV11Config) -> Profile {
        // Local waterline baseline = high percentile of valid pressure before
        // takeoff, excluding the immediate pre-takeoff sag. Median over a short
        // tail underestimates boosted jumps whose baro starts moving early.
        let tTake = ev[t0].t
        var pre = ev.filter { $0.t >= tTake - cfg.baroBaselinePreSec && $0.t < tTake - cfg.baroBaselineGuardSec }
            .compactMap { validBaro($0.baro) }
        if pre.count < 3 {
            pre = ev.filter { $0.t >= tTake - cfg.baroBaselinePreSec && $0.t < tTake }
                .compactMap { validBaro($0.baro) }
        }
        guard pre.count >= 3 else { return Profile(baselineHPa: nil, minHPa: nil, dropHPa: nil, recovered: false) }
        let baseline = DSPV11.percentile(pre, 0.80)

        // Minimum pressure across a height-only window. This is intentionally
        // wider than the detection landing: watch baro can lag the IMU landing.
        let hi = ev.lastIndex { $0.t <= tTake + cfg.baroHeightSearchSec } ?? min(ev.count - 1, tl + 1)
        let during = ev[t0...max(t0, hi)].compactMap { validBaro($0.baro) }
        guard let minP = during.min() else {
            return Profile(baselineHPa: baseline, minHPa: nil, dropHPa: nil, recovered: false)
        }
        let drop = baseline - minP

        // Recovery: pressure after landing climbs back to within 35% of the drop.
        let minT = ev.first(where: { validBaro($0.baro) == minP })?.t ?? ev[tl].t
        let postSamples = ev.filter { $0.t > minT && $0.t <= minT + 8.0 }
            .compactMap { validBaro($0.baro) }
        let recovered: Bool
        if drop > cfg.baroMinDropHPa, let postMax = postSamples.max() {
            recovered = postMax >= baseline - drop * 0.35
        } else {
            recovered = false
        }
        return Profile(baselineHPa: baseline, minHPa: minP, dropHPa: drop, recovered: recovered)
    }

    static func scoreProfile(_ ev: [SurfSensorEventV11], t0: Int, tl: Int, cfg: JumpEngineV11Config) -> Profile {
        let tTake = ev[t0].t
        let pre = ev.filter { $0.t >= tTake - 6.0 && $0.t < tTake }
            .compactMap { validBaro($0.baro) }
        guard pre.count >= 3 else { return Profile(baselineHPa: nil, minHPa: nil, dropHPa: nil, recovered: false) }
        let baseline = DSPV11.median(pre)

        let hi = min(ev.count - 1, tl + 1)
        let during = ev[t0...hi].compactMap { validBaro($0.baro) }
        guard let minP = during.min() else {
            return Profile(baselineHPa: baseline, minHPa: nil, dropHPa: nil, recovered: false)
        }
        let drop = baseline - minP

        let postSamples = ev.filter { $0.t > ev[tl].t && $0.t <= ev[tl].t + 2.0 }
            .compactMap { validBaro($0.baro) }
        let recovered: Bool
        if drop > cfg.baroMinDropHPa, let postMax = postSamples.max() {
            recovered = postMax >= baseline - drop * 0.35
        } else {
            recovered = false
        }
        return Profile(baselineHPa: baseline, minHPa: minP, dropHPa: drop, recovered: recovered)
    }

    /// Reject sentinel / implausible pressures (sensorOnly logs can carry 0 or
    /// out-of-range placeholders).
    private static func validBaro(_ p: Double?) -> Double? {
        guard let p = p, p > 800, p < 1100 else { return nil }
        return p
    }
}

// ================================================================
// MARK: - InertialHeightEstimator — signed vertical integration (v11.2)
// ================================================================
/// Estimates physical jump height from signed gravity-projected acceleration.
/// This is height-only evidence in v1: it can replace the displayed height when
/// quality is high, but it does not participate in accept/reject scoring.
enum InertialHeightEstimatorV11 {
    struct Estimate {
        var heightMeters: Double
        var quality: Double
        var apexTimeSec: Double?
        var landingTimeSec: Double?
        var biasG: Double
        var waterlineErrorMeters: Double
    }

    static func estimate(_ ev: [SurfSensorEventV11],
                         takeoffIndex t0: Int,
                         landingIndex tl: Int,
                         cfg: JumpEngineV11Config) -> Estimate? {
        guard ev.count >= 8, t0 >= 0, tl > t0, t0 < ev.count else { return nil }

        let landingIdx = selectLandingIndex(ev, t0: t0, tl: tl, cfg: cfg)
        guard landingIdx > t0, landingIdx < ev.count else { return nil }

        let takeoffT = ev[t0].t
        let landingT = ev[landingIdx].t
        let duration = landingT - takeoffT
        guard duration > 0.2 else { return nil }

        let pre = ev.filter { $0.t >= takeoffT - cfg.preJumpContextSec && $0.t < takeoffT - 0.2 }
            .map { $0.signedVerticalLoadG - 1.0 }
        let bias = pre.isEmpty ? 0 : DSPV11.median(pre)

        var v = Array(repeating: 0.0, count: landingIdx - t0 + 1)
        for k in (t0 + 1)...landingIdx {
            let local = k - t0
            let d = ev[k].t - ev[k - 1].t
            guard d > 0, d < 0.5 else {
                v[local] = v[local - 1]
                continue
            }
            let a0 = (ev[k - 1].signedVerticalLoadG - 1.0 - bias) * K11.g
            let a1 = (ev[k].signedVerticalLoadG - 1.0 - bias) * K11.g
            v[local] = v[local - 1] + 0.5 * (a0 + a1) * d
        }

        let vEnd = v.last ?? 0
        if duration > 0 {
            for i in 0..<v.count {
                let t = ev[t0 + i].t - takeoffT
                v[i] -= vEnd * (t / duration)
            }
        }

        var hRaw = Array(repeating: 0.0, count: v.count)
        for i in 1..<v.count {
            let d = ev[t0 + i].t - ev[t0 + i - 1].t
            guard d > 0, d < 0.5 else {
                hRaw[i] = hRaw[i - 1]
                continue
            }
            hRaw[i] = hRaw[i - 1] + 0.5 * (v[i - 1] + v[i]) * d
        }

        let rawEnd = hRaw.last ?? 0
        var h = hRaw
        if duration > 0 {
            for i in 0..<h.count {
                let t = ev[t0 + i].t - takeoffT
                h[i] -= rawEnd * (t / duration)
            }
        }

        var bestAbs = 0.0
        var bestIdx = 0
        for (i, value) in h.enumerated() {
            let a = abs(value)
            if a > bestAbs {
                bestAbs = a
                bestIdx = i
            }
        }

        let rawHeight = hRaw.map { abs($0) }.max() ?? 0
        let landingScore = landingEvidence(ev[landingIdx])
        let minVert = ev[t0...landingIdx].map(\.verticalAccelG).min() ?? 1.0
        let quality = qualityScore(
            height: bestAbs,
            duration: duration,
            preCount: pre.count,
            bias: bias,
            vEnd: vEnd,
            rawEnd: rawEnd,
            rawHeight: rawHeight,
            landingScore: landingScore,
            minVert: minVert,
            cfg: cfg
        )

        return Estimate(
            heightMeters: bestAbs,
            quality: quality,
            apexTimeSec: ev[t0 + bestIdx].t - takeoffT,
            landingTimeSec: landingT,
            biasG: bias,
            waterlineErrorMeters: abs(h.last ?? 0)
        )
    }

    private static func selectLandingIndex(_ ev: [SurfSensorEventV11],
                                           t0: Int,
                                           tl: Int,
                                           cfg: JumpEngineV11Config) -> Int {
        let takeoffT = ev[t0].t
        let originalLandingT = ev[min(max(tl, t0), ev.count - 1)].t
        let originalAir = max(0, originalLandingT - takeoffT)
        let minSearchT = takeoffT + max(cfg.landingSearchMinSec, min(originalAir - 0.25, cfg.maxValidAirtimeSec))
        let maxSearchT = takeoffT + cfg.maxValidAirtimeSec

        guard let lo = ev.firstIndex(where: { $0.t >= minSearchT }) else {
            return min(max(tl, t0 + 1), ev.count - 1)
        }
        let hi = ev.lastIndex(where: { $0.t <= maxSearchT }) ?? (ev.count - 1)
        guard hi >= lo else { return min(max(tl, t0 + 1), ev.count - 1) }

        var best = min(max(tl, lo), hi)
        var bestScore = landingEvidence(ev[best])
        for i in lo...hi {
            let score = landingEvidence(ev[i])
            if score > bestScore {
                bestScore = score
                best = i
            }
        }
        return best
    }

    private static func landingEvidence(_ e: SurfSensorEventV11) -> Double {
        e.accelMag + max(0, e.signedVerticalLoadG - 1.0) * 0.35
    }

    private static func qualityScore(height: Double,
                                     duration: Double,
                                     preCount: Int,
                                     bias: Double,
                                     vEnd: Double,
                                     rawEnd: Double,
                                     rawHeight: Double,
                                     landingScore: Double,
                                     minVert: Double,
                                     cfg: JumpEngineV11Config) -> Double {
        var q = 1.0
        if preCount < 8 { q -= 0.20 }
        q -= DSPV11.clamp(abs(bias) / 0.25, 0, 1) * 0.20
        q -= DSPV11.clamp(abs(vEnd) / 5.0, 0, 1) * 0.25
        q -= DSPV11.clamp(abs(rawEnd) / max(rawHeight * 1.5, 0.2), 0, 1) * 0.20
        if landingScore < cfg.minLandingImpactG {
            q -= 0.25
        } else if landingScore < cfg.landingSpikeG {
            q -= 0.10
        }
        if minVert > cfg.lowGCeiling { q -= 0.20 }
        if duration < cfg.minValidAirtimeSec || duration > cfg.maxValidAirtimeSec + 0.25 { q -= 0.30 }
        if height < 0.2 || height > 8.0 { q -= 0.40 }
        return DSPV11.clamp(q, 0, 1)
    }
}

// ================================================================
// MARK: - HeightFusion — choose/merge baro + inertial height (v11.2)
// ================================================================
enum HeightFusionV11 {
    struct Selection {
        var heightMeters: Double
        var source: JumpResultV11.HeightSource
        var baroQuality: Double
    }

    static func select(baroHeight: Double?,
                       baroDropHPa: Double?,
                       baroRecovered: Bool,
                       inertialHeight: Double?,
                       inertialQuality: Double,
                       speedContextMS: Double?,
                       fallbackHeight: Double,
                       cfg: JumpEngineV11Config) -> Selection {
        let bq = baroQuality(dropHPa: baroDropHPa, recovered: baroRecovered, cfg: cfg)
        let bh = baroHeight.flatMap { validBaroHeight($0) }
        let ih = inertialHeight
            .flatMap { validInertialHeight($0) }
            .map { calibratedInertialHeight($0, speedContextMS: speedContextMS, cfg: cfg) }
        let inertialUsable = ih != nil && inertialQuality >= 0.55
        let baroUsable = bh != nil && bq >= 0.45

        if let ih, let bh, inertialUsable, baroUsable {
            let absDiff = abs(ih - bh)
            let relDiff = absDiff / max(max(ih, bh), 0.5)
            if absDiff <= 0.6 || relDiff <= 0.35 {
                if let speed = speedContextMS, speed < 6.0, bh < ih, inertialQuality >= 0.75 {
                    return Selection(heightMeters: DSPV11.clamp(ih, 0, 8),
                                     source: .inertial,
                                     baroQuality: bq)
                }
                let iw = max(inertialQuality, 0.01)
                let bw = max(bq, 0.01)
                let blended = (ih * iw + bh * bw) / (iw + bw)
                return Selection(heightMeters: DSPV11.clamp(blended, 0, 8),
                                 source: .blended,
                                 baroQuality: bq)
            }

            // Disagreement: trust the better-quality source instead of averaging
            // incompatible evidence into a plausible-looking but wrong number.
            if let speed = speedContextMS, speed < 6.0, bh > ih * 1.45, inertialQuality >= 0.60 {
                return Selection(heightMeters: DSPV11.clamp(ih, 0, 8),
                                 source: .inertial,
                                 baroQuality: bq)
            }
            if let speed = speedContextMS, speed >= 6.0, bh >= 1.5, bq >= inertialQuality - 0.15 {
                return Selection(heightMeters: DSPV11.clamp(bh, 0, 8),
                                 source: .barometric,
                                 baroQuality: bq)
            }
            if inertialQuality >= bq {
                return Selection(heightMeters: DSPV11.clamp(ih, 0, 8),
                                 source: .inertial,
                                 baroQuality: bq)
            }
            return Selection(heightMeters: DSPV11.clamp(bh, 0, 8),
                             source: .barometric,
                             baroQuality: bq)
        }

        if let ih, inertialUsable {
            return Selection(heightMeters: DSPV11.clamp(ih, 0, 8),
                             source: .inertial,
                             baroQuality: bq)
        }
        if let bh, baroUsable {
            return Selection(heightMeters: DSPV11.clamp(bh, 0, 8),
                             source: .barometric,
                             baroQuality: bq)
        }
        if let speed = speedContextMS, speed < 6.0, let ih, inertialQuality >= 0.45 {
            return Selection(heightMeters: DSPV11.clamp(ih, 0, 8),
                             source: .inertial,
                             baroQuality: bq)
        }
        return Selection(heightMeters: fallbackHeight,
                         source: .kinematic,
                         baroQuality: bq)
    }

    private static func validInertialHeight(_ h: Double) -> Double? {
        guard h.isFinite, h >= 0.2, h <= 8.0 else { return nil }
        return h
    }

    private static func validBaroHeight(_ h: Double) -> Double? {
        guard h.isFinite, h >= 0.2, h <= 5.0 else { return nil }
        return h
    }

    private static func calibratedInertialHeight(_ h: Double,
                                                 speedContextMS: Double?,
                                                 cfg: JumpEngineV11Config) -> Double {
        guard let speed = speedContextMS, speed < cfg.inertialSlowSpeedMaxMS else { return h }
        return h * cfg.inertialSlowSpeedCalibration
    }

    private static func baroQuality(dropHPa: Double?,
                                    recovered: Bool,
                                    cfg: JumpEngineV11Config) -> Double {
        guard let drop = dropHPa, drop.isFinite, drop > cfg.baroMinDropHPa else { return 0 }
        let mag = DSPV11.clamp((drop - cfg.baroMinDropHPa) / (0.30 - cfg.baroMinDropHPa), 0, 1)
        var q = 0.45 + 0.35 * mag
        if recovered { q += 0.20 }
        return DSPV11.clamp(q, 0, 1)
    }
}

// ================================================================
// MARK: - 4. JumpPhysicsAnalyzer — full end-to-end segment math
// ================================================================
struct JumpPhysicsAnalyzerV11 {
    let cfg: JumpEngineV11Config

    func analyzeSegment(_ expanded: [SurfSensorEventV11],
                        candidate: JumpCandidateSegmentV11) -> JumpPhysicsResultV11? {
        let n = expanded.count
        guard n >= 6,
              let takeoffT = candidate.takeoffTime,
              let landingT = candidate.landingTime else { return nil }
        let dt = DSPV11.estimateDt(expanded)

        // Locate take-off / landing inside the expanded (pre/post-padded) buffer.
        let t0 = expanded.firstIndex { $0.t >= takeoffT } ?? 0
        let tl = expanded.lastIndex { $0.t <= landingT } ?? (n - 1)
        guard tl > t0 else { return nil }

        let airTimeSec = expanded[tl].t - expanded[t0].t

        // ── Acceleration extremes ──
        let airAccel = expanded[t0...tl].map { $0.accelMag }
        let maxAccel = airAccel.max() ?? 0
        let landingImpactG = expanded[max(t0, tl - 3)...tl].map { $0.accelMag }.max() ?? expanded[tl].accelMag
        let minVertG = expanded[t0...tl].map { $0.verticalAccelG }.min() ?? 1.0
        // Longest sustained run of free-fall (vertical-g below the ceiling) within
        // the air phase — a real jump holds free-fall; chop only dips briefly.
        var airborneSec = 0.0
        var runStart: Double? = nil
        for k in t0...tl {
            if expanded[k].verticalAccelG < cfg.lowGCeiling {
                if runStart == nil { runStart = expanded[k].t }
                airborneSec = max(airborneSec, expanded[k].t - (runStart ?? expanded[k].t))
            } else {
                runStart = nil
            }
        }

        // ── Rotation: integrate per-axis gyro to degrees ──
        var degX = 0.0, degY = 0.0, degZ = 0.0, maxRot = 0.0
        var rotEnergy = 0.0
        for k in (t0 + 1)...tl {
            let d = expanded[k].t - expanded[k - 1].t
            guard d > 0, d < 0.5 else { continue }
            degX += abs(expanded[k].gx) * d * K11.rad2deg
            degY += abs(expanded[k].gy) * d * K11.rad2deg
            degZ += abs(expanded[k].gz) * d * K11.rad2deg
            maxRot = max(maxRot, expanded[k].rotMag)
            rotEnergy += expanded[k].rotationEnergy * d
        }
        // gz≈yaw (spin), gy≈pitch (flip), gx≈roll (barrel)
        let axisMap: [(String, Double)] = [("yaw", degZ), ("pitch", degY), ("roll", degX)]
        let dominant = axisMap.max { $0.1 < $1.1 }!
        let secondMax = axisMap.filter { $0.0 != dominant.0 }.map { $0.1 }.max() ?? 0
        let rotationAxis = (dominant.1 > 0 && secondMax / max(dominant.1, 1e-6) > 0.6) ? "mixed" : dominant.0
        let totalDeg = (degX * degX + degY * degY + degZ * degZ).squareRoot()
        let rotations = Int((totalDeg / 360.0).rounded(.down))

        // ── Apex (integrate gravity-projected vertical accel) ──
        let apex = integrateApex(expanded, t0: t0, tl: tl, dt: dt)

        // ── BarometerCalibration: local-baseline pressure profile (v11.1) ──
        // Height in kiteboarding is NOT ballistic (g·t²/8 disagrees with Surfr:
        // 3.61 s airtime ↔ 2.16 m). The barometer measures actual altitude gain.
        // We take a rolling LOCAL baseline just before take-off, the minimum
        // pressure during the airborne window, and whether pressure recovers
        // toward baseline after landing — drop·p2m is the primary height.
        let baroScore = BarometerCalibrationV11.scoreProfile(expanded, t0: t0, tl: tl, cfg: cfg)
        let baroHeightProfile = BarometerCalibrationV11.heightProfile(expanded, t0: t0, tl: tl, cfg: cfg)
        let baroHeight: Double? = baroHeightProfile.dropHPa.flatMap {
            $0 > cfg.baroMinDropHPa ? $0 * cfg.baroP2M * cfg.baroHeightCalibration : nil
        }
        let altitudeDelta = baroHeight

        // Reference symmetric time-of-flight (reported only): h = g·t²/8.
        let heightFromAirtime = K11.g * airTimeSec * airTimeSec / 8.0

        // Inertial height: signed vertical acceleration + ZUPT. It is height-only
        // evidence in v1 and never changes accept/reject scoring.
        let inertial = InertialHeightEstimatorV11.estimate(expanded, takeoffIndex: t0, landingIndex: tl, cfg: cfg)
        let inertialHeight = inertial?.heightMeters
        let inertialQuality = inertial?.quality ?? 0

        // ── Speed context (fresh only — never a gate) ──
        let fresh = freshSpeed(expanded, t: takeoffT)
        let speedBefore = fresh ?? candidate.supporting.speedBefore ?? nearestSpeed(expanded, t: takeoffT)
        let speedAfter  = freshSpeed(expanded, t: landingT) ?? nearestSpeed(expanded, t: landingT)
        let speedDelta: Double? = (speedBefore != nil && speedAfter != nil) ? speedAfter! - speedBefore! : nil

        // No reliable measured height → conservative rise-time fallback. Airtime
        // is NOT ballistic in kiteboarding, so cap the fallback hard.
        let tRise = DSPV11.clamp(apex ?? (airTimeSec * cfg.ascentFraction),
                                 airTimeSec * cfg.minAscentFraction, airTimeSec * 0.5)
        let fallbackHeight = DSPV11.clamp(cfg.kinematicCalibration * 0.5 * K11.g * tRise * tRise, 0, 4)

        let height = HeightFusionV11.select(
            baroHeight: baroHeight,
            baroDropHPa: baroHeightProfile.dropHPa,
            baroRecovered: baroHeightProfile.recovered,
            inertialHeight: inertialHeight,
            inertialQuality: inertialQuality,
            speedContextMS: speedBefore,
            fallbackHeight: fallbackHeight,
            cfg: cfg
        )

        // ── Accel / gyro energy windows (ranking inputs) ──
        let preLo = expanded.firstIndex { $0.t >= takeoffT - cfg.preJumpContextSec } ?? 0
        let postHi = expanded.lastIndex { $0.t <= landingT + cfg.postJumpContextSec } ?? (n - 1)
        let energyBefore = meanEnergy(expanded, preLo, max(preLo, t0 - 1)) { $0.motionEnergy }
        let energyDuring = meanEnergy(expanded, t0, tl) { $0.motionEnergy }
        let energyAfter  = meanEnergy(expanded, min(tl + 1, postHi), postHi) { $0.motionEnergy }
        let gyroDuring   = meanEnergy(expanded, t0, tl) { $0.rotationEnergy }
        // Post-landing continuation: ride motion should resume, not flatline (a
        // crash) — ratio of after-energy to the ride baseline before.
        let postCont = DSPV11.clamp(energyAfter / max(energyBefore, 0.01), 0, 1.5) / 1.5

        let distance: Double? = speedBefore.map { min(150, $0 * airTimeSec) }
        let distanceGPS = gpsDistance(expanded, takeoffT: takeoffT, landingT: landingT)
        let motionEnergy = expanded[t0...tl].map { $0.motionEnergy }.reduce(0, +)

        var conf = 0.5
        if baroHeight != nil { conf += 0.2 }
        if candidate.sawLandingImpact { conf += 0.15 }
        if fresh != nil { conf += 0.1 }
        conf = DSPV11.clamp(conf, 0, 1)

        return JumpPhysicsResultV11(
            takeoffTime: takeoffT,
            landingTime: landingT,
            airTimeSec: airTimeSec,
            estimatedHeightMeters: height.heightMeters,
            heightFromAirtime: heightFromAirtime,
            heightFromAltitude: baroHeight,
            inertialHeightMeters: inertialHeight,
            inertialQuality: inertialQuality,
            inertialApexTimeSec: inertial?.apexTimeSec,
            inertialLandingTimeSec: inertial?.landingTimeSec,
            speedBeforeTakeoff: speedBefore,
            speedAfterLanding: speedAfter,
            speedDelta: speedDelta,
            distanceMeters: distance,
            distanceGPSMeters: distanceGPS,
            maxAccelerationG: maxAccel,
            landingImpactG: landingImpactG,
            minVerticalG: minVertG,
            maxRotationRate: maxRot,
            airborneSec: airborneSec,
            totalRotationDegrees: totalDeg,
            rotationAxis: rotationAxis,
            rotations: rotations,
            altitudeDeltaMeters: altitudeDelta,
            apexTimeSec: apex,
            motionEnergy: motionEnergy,
            rotationEnergy: rotEnergy,
            heightSource: height.source,
            confidence: conf,
            baroBaselineHPa: baroScore.baselineHPa,
            baroMinHPa: baroScore.minHPa,
            baroDropHPa: baroScore.dropHPa,
            baroRecovered: baroScore.recovered,
            baroHeightMeters: baroHeight,
            baroQuality: height.baroQuality,
            accelEnergyBefore: energyBefore,
            accelEnergyDuring: energyDuring,
            accelEnergyAfter: energyAfter,
            gyroEnergyDuring: gyroDuring,
            postLandingContinuation: postCont,
            speedFresh: fresh != nil,
            speedContextMS: speedBefore
        )
    }

    private func meanEnergy(_ ev: [SurfSensorEventV11], _ lo: Int, _ hi: Int, _ pick: (SurfSensorEventV11) -> Double) -> Double {
        guard hi >= lo, lo >= 0, hi < ev.count else { return 0 }
        var sum = 0.0
        for k in lo...hi { sum += pick(ev[k]) }
        return sum / Double(hi - lo + 1)
    }

    /// Nearest speed that was FRESH (changed recently) near time `t`. Stale or
    /// repeated (ZOH) speed values are ignored — they are not 50 Hz fixes.
    private func freshSpeed(_ ev: [SurfSensorEventV11], t: Double) -> Double? {
        var best: Double? = nil, bestDt = Double.infinity
        for e in ev {
            guard let spd = e.gpsSpeed, spd.isFinite, spd > 0, e.speedFresh else { continue }
            let d = abs(e.t - t)
            if d < bestDt { bestDt = d; best = spd }
        }
        return bestDt <= 3.0 ? best : nil
    }

    private func nearestSpeed(_ ev: [SurfSensorEventV11], t: Double) -> Double? {
        var best: Double? = nil, bestDt = Double.infinity
        for e in ev {
            guard let spd = e.gpsSpeed, spd.isFinite, spd >= 0 else { continue }
            if let acc = e.gpsAccuracy, acc > cfg.gpsAccuracyMaxM { continue }
            let d = abs(e.t - t)
            if d < bestDt { bestDt = d; best = spd }
        }
        return bestDt <= 3.0 ? best : nil
    }

    private func gpsDistance(_ ev: [SurfSensorEventV11], takeoffT: Double, landingT: Double) -> Double? {
        let pts = ev.compactMap { e -> (Double, Double, Double)? in
            guard let la = e.gpsLat, let lo = e.gpsLon, la.isFinite, lo.isFinite else { return nil }
            return (e.t, la, lo)
        }
        guard pts.count >= 2 else { return nil }
        let near0 = pts.min { abs($0.0 - takeoffT) < abs($1.0 - takeoffT) }!
        let near1 = pts.min { abs($0.0 - landingT) < abs($1.0 - landingT) }!
        guard near0.0 != near1.0 else { return nil }
        return (DSPV11.haversine(near0.1, near0.2, near1.1, near1.2) * 10).rounded() / 10
    }

    private func integrateApex(_ ev: [SurfSensorEventV11], t0: Int, tl: Int, dt: Double) -> Double? {
        guard tl > t0 + 1 else { return nil }
        // bias = median vertical (g-1) over quiet pre-jump tail
        var bias = 0.0
        if t0 > 3 {
            bias = DSPV11.median(ev[0..<t0].map { $0.verticalAccelG - 1.0 })
        }
        var v = 0.0, prevV = 0.0, elapsed = 0.0
        for k in (t0 + 1)...tl {
            let d = ev[k].t - ev[k - 1].t
            guard d > 0, d < 0.5 else { continue }
            let aMps2 = (ev[k].verticalAccelG - 1.0 - bias) * K11.g
            prevV = v; v += aMps2 * d; elapsed += d
            if prevV > 0.05, v <= 0.05 {
                let frac = DSPV11.clamp(prevV / (prevV - v + 1e-9), 0, 1)
                return elapsed - d + frac * d
            }
        }
        return nil
    }
}

// ================================================================
// MARK: - 5. CandidateRankingScorer — composite 0–100 ranking (v11.1)
// ================================================================
/// Ranks each candidate by a weighted blend of evidence rather than hard gates.
/// The barometric pressure profile (drop → recovery) is the dominant signal,
/// because it is the only one that physically corresponds to a real altitude
/// gain. Speed is contextual confidence only; stale/missing speed lowers the
/// score but never rejects. The clusterer uses this score to pick the best
/// candidate per temporal cluster.
struct CandidateRankingScorerV11 {
    let cfg: JumpEngineV11Config

    func score(physics p: JumpPhysicsResultV11,
               candidate: JumpCandidateSegmentV11,
               recentEmittedTakeoffs: [Double]) -> JumpQualityScoreV11 {
        var reasons: [String] = []
        var total = 0.0

        // ── Barometric profile (dominant) ──
        // A real jump: pressure drops during the airborne window then recovers.
        if let drop = p.baroDropHPa, drop > cfg.baroMinDropHPa {
            let mag = DSPV11.clamp((drop - cfg.baroMinDropHPa) / (0.30 - cfg.baroMinDropHPa), 0, 1)
            var baroScore = cfg.wBaroProfile * (0.5 + 0.5 * mag)   // present = at least half
            // Recovery is a strong positive but its ABSENCE is only a light
            // penalty: session pressure drift often masks the recovery leg.
            if p.baroRecovered { baroScore = min(cfg.wBaroProfile, baroScore + 4); reasons.append("BARO_DROP_AND_RECOVERY") }
            else { baroScore *= 0.85; reasons.append("BARO_DROP_NO_RECOVERY") }
            total += baroScore
        } else {
            reasons.append("NO_BARO_PROFILE")
        }

        // ── Landing impact confidence ──
        let li = DSPV11.clamp((p.landingImpactG - cfg.landingSpikeG) / (5.0 - cfg.landingSpikeG), 0, 1)
        if p.landingImpactG >= cfg.landingSpikeG { reasons.append("LANDING_IMPACT") }
        total += cfg.wLandingImpact * li

        // ── Impact power: peak acceleration over the segment ──
        // The single strongest real-vs-noise separator on labelled logs — a real
        // jump's take-off/landing spikes dominate ordinary carving chop.
        let ip = DSPV11.clamp((p.maxAccelerationG - cfg.impactPowerLoG) / (cfg.impactPowerHiG - cfg.impactPowerLoG), 0, 1)
        if p.maxAccelerationG >= cfg.impactPowerLoG + 1.0 { reasons.append("IMPACT_POWER") }
        total += cfg.wImpactPower * ip

        // ── Gyro energy (weak/contra signal — carving spins more than jumps) ──
        let ge = DSPV11.clamp(p.gyroEnergyDuring / 6.0, 0, 1)   // (rad/s)² scale
        total += cfg.wGyroEnergy * ge

        // ── Post-landing continuation (ride resumes, not a crash/flatline) ──
        total += cfg.wPostLanding * p.postLandingContinuation
        if p.postLandingContinuation > 0.4 {
            reasons.append("POST_LANDING_RIDE")
        } else {
            total -= cfg.penaltyNoPostLandingRide
            reasons.append("PENALTY_NO_POST_LANDING_RIDE")
        }

        // ── Acceleration contrast (event stands out from the ride baseline) ──
        let contrast = DSPV11.clamp(abs(p.accelEnergyDuring - p.accelEnergyBefore) / max(p.accelEnergyBefore, 0.02), 0, 1)
        total += cfg.wAccelContrast * contrast

        // ── Speed context (fresh only) ──
        if p.speedFresh, let s = p.speedContextMS, s >= cfg.minRidingSpeedMS {
            total += cfg.wSpeedContext
            reasons.append("SPEED_CONTEXT_FRESH")
        } else if p.speedFresh, let s = p.speedContextMS, s < cfg.minRidingSpeedMS {
            total -= cfg.penaltyLowSpeedContext
            reasons.append("PENALTY_LOW_SPEED_CONTEXT")
        } else if !p.speedFresh {
            // Soft penalty — stale/missing speed lowers confidence, never rejects.
            total -= cfg.penaltyStaleSpeed
            reasons.append("SPEED_STALE_OR_MISSING")
        }

        // ── Sensor stability (not clipped / chaotic) ──
        if p.maxRotationRate < 25 && p.maxAccelerationG < 15 {
            total += cfg.wSensorStability
            reasons.append("SENSOR_STABLE")
        }

        // Apple Watch Ultra water state, when available, gives an independent
        // surfaced-to-submerged airtime bracket. Missing water data is neutral.
        if candidate.reasonCodes.contains("SUBMERSION_AIRTIME_BRACKET") {
            total += cfg.wSubmersionBracket
            reasons.append("SUBMERSION_AIRTIME_BRACKET")
        }

        // ── Height confidence ──
        // Kinematic fallback is useful for debug continuity, but it is weaker
        // jump evidence than baro/inertial/blended height and should not carry
        // borderline candidates over the accept line.
        if p.heightSource == .kinematic {
            total -= 18
            reasons.append("PENALTY_KINEMATIC_HEIGHT")
        }
        if p.estimatedHeightMeters < 0.8 {
            let lowHeight = DSPV11.clamp((0.8 - p.estimatedHeightMeters) / 0.8, 0, 1)
            total -= cfg.penaltyLowHeadlineHeight * lowHeight
            reasons.append("PENALTY_LOW_HEIGHT")
        }
        if p.airTimeSec > 4.8,
           p.estimatedHeightMeters < 1.0,
           p.maxAccelerationG < cfg.impactPowerHiG {
            total -= cfg.penaltyWeakLongLowHeight
            reasons.append("PENALTY_WEAK_LONG_LOW_HEIGHT")
        }
        if p.airTimeSec > 5.5,
           p.estimatedHeightMeters < 1.6,
           p.maxAccelerationG < 3.0 {
            total -= cfg.penaltyWeakLongLowHeight * 0.5
            reasons.append("PENALTY_LONG_MODEST_HEIGHT")
        }
        if p.heightSource == .barometric,
           p.estimatedHeightMeters > 4.6,
           p.inertialQuality < 0.5 {
            total -= cfg.penaltyBaroCapNoInertial
            reasons.append("PENALTY_BARO_CAP_NO_INERTIAL")
        }
        if p.heightSource == .barometric,
           (p.baroDropHPa ?? 0) <= cfg.baroMinDropHPa,
           p.airTimeSec > 4.8 {
            total -= cfg.penaltyLongNoScoreBaro
            reasons.append("PENALTY_LONG_NO_SCORE_BARO")
        }
        if let speed = p.speedContextMS,
           speed >= 6.0,
           p.airTimeSec > 5.75,
           p.estimatedHeightMeters < 3.0 {
            total -= cfg.penaltyFastLongLowMeasured
            reasons.append("PENALTY_FAST_LONG_LOW_MEASURED")
        }
        if let speed = p.speedContextMS,
           speed < 6.0,
           p.airTimeSec > 3.5,
           p.estimatedHeightMeters < 2.0,
           p.maxAccelerationG < 3.0 {
            total -= cfg.penaltySlowWeakMeasured
            reasons.append("PENALTY_SLOW_WEAK_MEASURED")
        }

        // ── Airtime extremes ──
        if p.airTimeSec > cfg.maxAirTimeSec * 1.5 {
            total -= cfg.penaltyUnrealisticAirtime; reasons.append("REJECT_UNREALISTIC_AIRTIME")
        }

        // ── Duplicate of an already-emitted jump ──
        if recentEmittedTakeoffs.contains(where: { abs($0 - p.takeoffTime) < cfg.duplicateWindowSec }) {
            total -= cfg.penaltyDuplicate; reasons.append("REJECT_DUPLICATE_SEGMENT")
        }

        // ── HARD airtime filter: a valid jump must be airborne ≥ minValidAirtimeSec.
        // Applied as a hard zero so a too-short candidate can never win its
        // cluster — the clusterer then prefers a ≥2 s candidate if one exists.
        if p.airTimeSec < cfg.minValidAirtimeSec {
            reasons.append("REJECT_AIRTIME_BELOW_MIN")
            total = 0
        }
        if p.airTimeSec > cfg.maxValidAirtimeSec {
            reasons.append("REJECT_AIRTIME_ABOVE_MAX")
            total = 0
        }
        // ── Noise hard filters: a real jump carries force ──
        if p.landingImpactG < cfg.minLandingImpactG {
            reasons.append("REJECT_WEAK_LANDING")
            total = 0
        }
        if p.maxAccelerationG < cfg.minPeakAccelG {
            reasons.append("REJECT_WEAK_IMPACT")
            total = 0
        }
        // ── Noise hard filter: a real jump rotates slowly ──
        let rotDegPerSec = p.airTimeSec > 0 ? p.totalRotationDegrees / p.airTimeSec : 0
        if rotDegPerSec > cfg.maxRotationDegPerAirSec {
            reasons.append("REJECT_FAST_ROTATION")
            total = 0
        }

        total = DSPV11.clamp(total, 0, 100)
        let label: JumpQualityScoreV11.Label
        if total >= cfg.excellentScore { label = .excellent }
        else if total >= cfg.strongScore { label = .strong }
        else if total >= cfg.rankAcceptScore { label = .valid }
        else { label = .weak }

        var c = JumpQualityScoreV11.Components()
        c.landingConfidence = cfg.wLandingImpact * li
        c.rotationQuality = cfg.wGyroEnergy * ge
        c.sensorAgreement = (p.baroDropHPa ?? 0) > cfg.baroMinDropHPa ? cfg.wBaroProfile : 0
        return JumpQualityScoreV11(total: total, components: c, label: label, reasonCodes: reasons)
    }
}

// ================================================================
// MARK: - Raw candidate + clustering (NMS) (v11.1)
// ================================================================
struct JumpRawCandidateV11 {
    var physics: JumpPhysicsResultV11
    var segment: JumpCandidateSegmentV11
    var score: JumpQualityScoreV11
    var takeoffTime: Double { physics.takeoffTime }
}

struct JumpClusterV11 {
    var winner: JumpRawCandidateV11
    var members: [JumpRawCandidateV11]   // all candidates in the cluster (incl. winner)
    var startTime: Double
    var endTime: Double
    var suppressed: [JumpRawCandidateV11] { members.filter { $0.takeoffTime != winner.takeoffTime } }
}

/// Non-maximum suppression over raw candidates: keeps the best representative
/// per temporal cluster (clusterWindowSec). The public score remains the
/// accept/reject gate; the private winner-rank is only a tie-breaker among
/// nearby hypotheses for the same physical event.
struct JumpCandidateClustererV11 {
    let cfg: JumpEngineV11Config

    func cluster(_ candidates: [JumpRawCandidateV11]) -> [JumpClusterV11] {
        guard !candidates.isEmpty else { return [] }
        let sorted = candidates.sorted { $0.score.total > $1.score.total }
        var clusters: [JumpClusterV11] = []

        for c in sorted {
            // Nearest existing winner within the cluster window.
            let nearestIdx = clusters.enumerated()
                .filter { abs($0.element.winner.takeoffTime - c.takeoffTime) < cfg.clusterWindowSec }
                .min { abs($0.element.winner.takeoffTime - c.takeoffTime) < abs($1.element.winner.takeoffTime - c.takeoffTime) }?
                .offset

            if let idx = nearestIdx {
                let gap = abs(clusters[idx].winner.takeoffTime - c.takeoffTime)
                let distinct = c.physics.baroHeightMeters != nil && clusters[idx].winner.physics.baroHeightMeters != nil
                if gap > cfg.clusterMinSeparationSec && distinct {
                    clusters.append(makeCluster(c))   // genuinely separate jump
                } else {
                    clusters[idx].members.append(c)
                    clusters[idx].startTime = min(clusters[idx].startTime, c.takeoffTime)
                    clusters[idx].endTime = max(clusters[idx].endTime, c.physics.landingTime)
                    // Winner = best representative, not necessarily the raw
                    // highest-score spike. This improves timing/height inside a
                    // cluster without changing whether a candidate is accepted.
                    if shouldPromote(c, over: clusters[idx].winner) {
                        clusters[idx].winner = c
                    }
                }
            } else {
                clusters.append(makeCluster(c))
            }
        }
        return clusters.sorted { $0.winner.takeoffTime < $1.winner.takeoffTime }
    }

    private func makeCluster(_ c: JumpRawCandidateV11) -> JumpClusterV11 {
        JumpClusterV11(winner: c, members: [c], startTime: c.takeoffTime, endTime: c.physics.landingTime)
    }

    private func shouldPromote(_ candidate: JumpRawCandidateV11,
                               over current: JumpRawCandidateV11) -> Bool {
        let cRank = winnerRank(candidate)
        let wRank = winnerRank(current)
        if abs(cRank - wRank) > 0.001 { return cRank > wRank }
        if abs(candidate.score.total - current.score.total) > 0.001 {
            return candidate.score.total > current.score.total
        }
        return candidate.takeoffTime < current.takeoffTime
    }

    private func winnerRank(_ c: JumpRawCandidateV11) -> Double {
        let p = c.physics
        var rank = c.score.total

        // Rejected hypotheses should not displace accepted ones inside a
        // cluster. If the whole cluster is weak, relative score still decides.
        if c.score.total < cfg.rankAcceptScore {
            rank -= 80 + (cfg.rankAcceptScore - c.score.total)
        }

        switch p.heightSource {
        case .blended:
            rank += 12
        case .inertial:
            rank += 7 * DSPV11.clamp(p.inertialQuality, 0, 1)
        case .barometric:
            rank += 5 * DSPV11.clamp(p.baroQuality, 0, 1)
        case .kinematic:
            rank -= 12
        }

        // A very low headline height paired with multi-second airtime is often
        // the later impact spike in the same jump. Keep it selectable, but only
        // when its score margin is genuinely decisive.
        if p.estimatedHeightMeters < 1.0 {
            let shortage = DSPV11.clamp((1.0 - p.estimatedHeightMeters) / 1.0, 0, 1)
            rank -= 40 * shortage
            if p.airTimeSec > 2.3 { rank -= 8 * shortage }
        }

        if p.airTimeSec > 4.8, p.estimatedHeightMeters < 1.0 {
            rank -= 10
        }

        return rank
    }
}

// ================================================================
// MARK: - 6. BufferedJumpAnalyzer — the background scheduler
// ================================================================
/// Runs every analysisIntervalSec of session time. Pulls candidate segments
/// from the buffer, waits until each segment's post-landing context is fully
/// buffered, analyses the complete sequence, scores it, and only then emits a
/// final jump. Records a debug entry for every accepted AND rejected segment.
final class BufferedJumpAnalyzerV11 {
    private let cfg: JumpEngineV11Config
    let buffer = JumpEventBufferV11()
    private let segmenter: JumpCandidateSegmenterV11
    private let startEnd: JumpStartEndDetectorV11
    private let physics: JumpPhysicsAnalyzerV11
    private let scorer: CandidateRankingScorerV11
    private let clusterer: JumpCandidateClustererV11

    private var emittedTakeoffs: [Double] = []
    /// Every raw candidate analysed this session (pre-clustering). The clusterer
    /// runs over these; the harness reads them to report candidates-per-jump.
    private(set) var rawCandidates: [JumpRawCandidateV11] = []
    private var emittedClusterKeys: Set<Int> = []
    private(set) var debugSegments: [JumpSegmentDebugV11] = []

    var onJump: ((JumpResultV11) -> Void)?
    var maxSessionSpeedMS: Double = 0

    /// Full-offline mode: every event is kept in the buffer for the whole
    /// session (never pruned) and the segmenter scans the entire buffer from a
    /// moving cursor — find the next take-off event, then the landing after it,
    /// then analyse the complete [take-off … landing+post] segment. Used for
    /// replay / the evaluation harness. Live watch sessions keep the rolling
    /// window (bounded memory).
    var fullOffline = false
    /// Time up to which take-off triggers have already been scanned (cursor).
    private var scanCursorTime: Double = -Double.infinity

    init(config: JumpEngineV11Config) {
        self.cfg = config
        self.segmenter = JumpCandidateSegmenterV11(cfg: config)
        self.startEnd = JumpStartEndDetectorV11(cfg: config)
        self.physics = JumpPhysicsAnalyzerV11(cfg: config)
        self.scorer = CandidateRankingScorerV11(cfg: config)
        self.clusterer = JumpCandidateClustererV11(cfg: config)
    }

    /// Final clusters (winner per temporal group) for the evaluation harness.
    func clusters() -> [JumpClusterV11] { clusterer.cluster(rawCandidates) }

    func append(_ e: SurfSensorEventV11) { buffer.append(e) }

    /// One analyzer pass. `finalFlush` analyses even segments whose full
    /// post-landing context is not yet buffered (session end).
    func tick(now: Double, finalFlush: Bool) {
        // ── Choose the scan window ──
        // Full-offline: scan the WHOLE buffer from the cursor (with enough
        // look-back for the ride/baro baseline) — find the next take-off, then
        // its landing, then the full segment. Rolling (live): just the recent
        // window. The cursor + markSegmentAsProcessed prevent rescanning.
        let scan: [SurfSensorEventV11]
        if fullOffline {
            let lookbackSec = cfg.baroBaselinePreSec + cfg.rideStatWindowSec + 1.0
            scan = buffer.getEventsBetween(scanCursorTime - lookbackSec, buffer.latestTime ?? 0)
        } else {
            // Rolling (live): the scan window MUST outlast a candidate's
            // analysis-readiness delay, otherwise the take-off is evicted from the
            // window before its post-landing context is buffered and the jump is
            // never analysed → nothing is ever emitted. A candidate is ready at
            // landing + postJumpContextSec; worst case landing = take-off +
            // maxValidAirtimeSec, plus one tick of slack before it's picked up.
            // (bufferRetentionSec bounds actual memory; this only widens the scan.)
            let readyHorizon = cfg.maxValidAirtimeSec + cfg.postJumpContextSec
                             + 2 * cfg.analysisIntervalSec
            scan = buffer.getRecentEvents(max(cfg.analysisWindowSec, readyHorizon))
        }
        let candidates = segmenter.findCandidateSegments(scan)

        // ── Collect raw candidates (v11.1: over-detect, cluster later) ──
        for var seg in candidates {
            guard let takeoffT = seg.takeoffTime, let landingT = seg.landingTime else { continue }
            if buffer.segmentWasProcessed(seg.startTime, seg.endTime, tolerance: cfg.duplicateWindowSec) { continue }

            // Real-time budget (≤5 s to display): analyse as soon as the landing's
            // post-context is buffered — do NOT wait a worst-case airtime. The
            // landing is already known, and the pressure apex lies within
            // [take-off, landing], so landing + a short settle is all the baro
            // height search needs. This is the single biggest delay saving.
            let needUntil = landingT + cfg.postJumpContextSec
            if !finalFlush, (buffer.latestTime ?? 0) < needUntil { continue }

            let heightLookback = max(cfg.preJumpContextSec, cfg.baroBaselinePreSec)
            let expanded = buffer.getEventsBetween(takeoffT - heightLookback,
                                                   landingT + cfg.postJumpContextSec)
            guard let p = physics.analyzeSegment(expanded, candidate: seg) else {
                buffer.markSegmentAsProcessed(seg.startTime, seg.endTime)
                continue
            }
            seg.lifecycle = startEnd.lifecycle(for: expanded, takeoffTime: takeoffT, landingTime: landingT)
            seg.supporting.altitudeDelta = p.altitudeDeltaMeters

            let qs = scorer.score(physics: p, candidate: seg, recentEmittedTakeoffs: emittedTakeoffs)
            rawCandidates.append(JumpRawCandidateV11(physics: p, segment: seg, score: qs))
            buffer.markSegmentAsProcessed(seg.startTime, seg.endTime)
            // Advance the cursor past this analysed segment so the next scan does
            // not re-walk it (full-offline only).
            if fullOffline { scanCursorTime = max(scanCursorTime, landingT) }
        }

        // In full-offline mode the clustering keeps changing as the whole session
        // is ingested, so emit ONCE on the final flush over the final clusters.
        // Live (rolling) mode emits closed clusters incrementally each tick.
        if !fullOffline || finalFlush {
            emitClosedClusters(now: now, finalFlush: finalFlush)
        }

        if fullOffline {
            // Never prune; but keep the cursor from lagging too far behind so the
            // scan window stays bounded even when no jump is found for a while.
            // Leave one max-segment of slack so an in-progress jump is not skipped.
            let slack = cfg.maxAirTimeSec + cfg.preJumpContextSec + cfg.postJumpContextSec
            scanCursorTime = max(scanCursorTime, (buffer.latestTime ?? 0) - slack)
        } else {
            buffer.pruneOldEvents(cfg.bufferRetentionSec)
        }
    }

    /// Cluster all raw candidates and emit the winner of each cluster whose
    /// window has fully passed (or on final flush). Records a debug entry per
    /// candidate (winner = accepted, others = rejected/suppressed).
    private func emitClosedClusters(now: Double, finalFlush: Bool) {
        let clusters = clusterer.cluster(rawCandidates)
        for cluster in clusters {
            let key = Int((cluster.winner.takeoffTime * 10).rounded())
            if emittedClusterKeys.contains(key) { continue }
            // Wait a short settle so we see all of this jump's sub-spikes, then
            // emit. Kept small (clusterSettleSec) for the ≤5 s display budget —
            // one jump's sub-spikes are all within its airtime and already buffered.
            if !finalFlush, now - cluster.endTime < cfg.clusterSettleSec { continue }

            let w = cluster.winner
            let accepted = w.score.total >= cfg.rankAcceptScore
            emittedClusterKeys.insert(key)

            // Debug: winner first, then suppressed members.
            debugSegments.append(debug(for: w, decision: accepted ? "accepted" : "rejected",
                                       extra: ["CLUSTER_WINNER", "members=\(cluster.members.count)"]))
            for s in cluster.suppressed {
                debugSegments.append(debug(for: s, decision: "rejected", extra: ["CLUSTER_SUPPRESSED"]))
            }

            if accepted {
                emittedTakeoffs.append(w.takeoffTime)
                onJump?(makeResult(physics: w.physics, score: w.score))
            }
        }
    }

    private func debug(for c: JumpRawCandidateV11, decision: String, extra: [String]) -> JumpSegmentDebugV11 {
        let p = c.physics
        return JumpSegmentDebugV11(
            segmentStart: round3(c.segment.startTime),
            segmentEnd: round3(c.segment.endTime),
            decision: decision,
            score: c.score.total,
            label: c.score.label.rawValue,
            reasonCodes: c.score.reasonCodes + extra,
            metrics: .init(
                airTimeMs: round1(p.airTimeSec * 1000),
                estimatedHeightMeters: round2(p.estimatedHeightMeters),
                heightSource: p.heightSource.rawValue,
                baroHeightMeters: p.baroHeightMeters.map(round2),
                baroQuality: round3(p.baroQuality),
                inertialHeightMeters: p.inertialHeightMeters.map(round2),
                inertialQuality: round3(p.inertialQuality),
                inertialApexTimeSec: p.inertialApexTimeSec.map(round2),
                inertialLandingTimeSec: p.inertialLandingTimeSec.map(round2),
                speedBefore: p.speedContextMS.map(round2),
                speedAfter: p.speedAfterLanding.map(round2),
                maxAccelerationG: round2(p.maxAccelerationG),
                landingImpactG: round2(p.landingImpactG),
                totalRotationDegrees: round1(p.totalRotationDegrees),
                minVerticalG: round2(p.minVerticalG),
                airborneMs: round1(p.airborneSec * 1000),
                maxRotationRate: round2(p.maxRotationRate)
            )
        )
    }

    private func makeResult(physics p: JumpPhysicsResultV11, score qs: JumpQualityScoreV11) -> JumpResultV11 {
        JumpResultV11(
            takeoffTimeSeconds: round2(p.takeoffTime),
            landingTimeSeconds: round2(p.landingTime),
            airTimeSeconds: round2(p.airTimeSec),
            jumpHeightMeters: round2(p.estimatedHeightMeters),
            baroHeightMeters: p.baroHeightMeters.map(round2),
            baroQuality: round3(p.baroQuality),
            kinematicHeightMeters: round2(p.heightFromAirtime),
            inertialHeightMeters: p.inertialHeightMeters.map(round2),
            inertialQuality: round3(p.inertialQuality),
            inertialApexTimeSeconds: p.inertialApexTimeSec.map(round2),
            inertialLandingTimeSeconds: p.inertialLandingTimeSec.map(round2),
            apexTimeSeconds: p.apexTimeSec.map(round2),
            rotations: p.rotations,
            totalRotationDegrees: round1(p.totalRotationDegrees),
            rotationAxis: p.rotationAxis,
            speedBeforeTakeoff: p.speedBeforeTakeoff.map(round2),
            speedAfterLanding: p.speedAfterLanding.map(round2),
            jumpDistanceMeters: p.distanceMeters.map(round1),
            jumpDistanceGPSMeters: p.distanceGPSMeters,
            maxAccelerationG: round2(p.maxAccelerationG),
            landingImpactG: round2(p.landingImpactG),
            maxRotationRate: round2(p.maxRotationRate),
            altitudeDeltaMeters: p.altitudeDeltaMeters.map(round2),
            maxSessionSpeedKnots: round1(maxSessionSpeedMS * K11.ms2kn),
            maxSessionSpeedKmh: round1(maxSessionSpeedMS * K11.ms2kmh),
            confidence: round3(qs.total / 100.0),
            score: qs.total,
            label: qs.label.rawValue,
            reasonCodes: qs.reasonCodes,
            landingKind: mapLanding(p),
            heightSource: p.heightSource
        )
    }

    private func mapLanding(_ p: JumpPhysicsResultV11) -> JumpResultV11.LandingKind {
        if p.landingImpactG >= cfg.landingSpikeG { return .hardImpact }
        return .settle
    }

    func reset() {
        buffer.clear()
        emittedTakeoffs.removeAll(keepingCapacity: true)
        rawCandidates.removeAll(keepingCapacity: true)
        emittedClusterKeys.removeAll(keepingCapacity: true)
        debugSegments.removeAll(keepingCapacity: true)
        scanCursorTime = -Double.infinity
        maxSessionSpeedMS = 0
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}

// ================================================================
// MARK: - 7. KitesurfSessionV11 — streaming front-end
//  Normalizes each incoming sample into the buffer and drives the
//  background analyzer on a sample-time schedule (every 3–5 s).
// ================================================================
final class KitesurfSessionV11 {

    enum State { case idle, riding, airborne, analyzing }

    private let cfg: JumpEngineV11Config
    private let analyzer: BufferedJumpAnalyzerV11
    private(set) var state: State = .idle

    private var lastAnalysisT: Double = -Double.infinity
    private var speedTop3: [Double] = []
    // Speed freshness: track the last value-CHANGE, not every (ZOH-repeated) read.
    private var lastSpeedValue: Double?
    private var lastSpeedChangeT: Double = -Double.infinity

    var onJumpDetected: ((JumpResultV11) -> Void)?
    var onStateChange: ((State) -> Void)?

    /// Exposed for the comparison runner / debug export.
    var debugSegments: [JumpSegmentDebugV11] { analyzer.debugSegments }
    /// Exposed for the evaluation harness (candidates-per-jump, forensics).
    var rawCandidates: [JumpRawCandidateV11] { analyzer.rawCandidates }
    var clusters: [JumpClusterV11] { analyzer.clusters() }

    /// Full-offline buffering: keep every event for the whole session and scan
    /// the complete buffer for take-off→landing segments. Enabled for replay /
    /// the evaluation harness (synchronousAnalysis); live keeps the rolling window.
    private let offlineMode: Bool

    init(detectorConfig: JumpEngineV11Config = .default,
         refractorySec: Double = 1.0,
         synchronousAnalysis: Bool = false) {
        var c = detectorConfig
        c.duplicateWindowSec = max(c.duplicateWindowSec, refractorySec)
        self.cfg = c
        self.offlineMode = synchronousAnalysis
        self.analyzer = BufferedJumpAnalyzerV11(config: c)
        self.analyzer.fullOffline = synchronousAnalysis
        self.analyzer.onJump = { [weak self] r in self?.onJumpDetected?(r) }
    }

    func start() {
        analyzer.reset()
        lastAnalysisT = -Double.infinity
        speedTop3.removeAll()
        lastSpeedValue = nil
        lastSpeedChangeT = -Double.infinity
        transition(to: .riding)
    }

    func stop() {
        // Final flush: analyse anything still pending in the buffer.
        analyzer.tick(now: analyzer.buffer.latestTime ?? 0, finalFlush: true)
        transition(to: .idle)
    }

    func onSample(_ s: SensorSampleV11) {
        // Robust session max speed (median of top-3).
        if let spd = s.gpsSpeedMS, spd.isFinite, spd > 0 {
            speedTop3.append(spd); speedTop3.sort(by: >)
            if speedTop3.count > 3 { speedTop3.removeLast() }
            analyzer.maxSessionSpeedMS = speedTop3.reduce(0, +) / Double(speedTop3.count)
        }

        // Speed freshness: a value that changed is a fresh fix; a repeated value
        // is the held (ZOH) reading and must not count as a new 50 Hz sample.
        if let spd = s.gpsSpeedMS, spd.isFinite {
            if lastSpeedValue == nil || abs(spd - (lastSpeedValue ?? -1)) > 1e-6 {
                lastSpeedValue = spd
                lastSpeedChangeT = s.t
            }
        }
        var event = SurfSensorEventV11.normalize(s)
        event.speedAgeSec = s.t - lastSpeedChangeT
        event.speedFresh = (s.gpsSpeedMS != nil) && event.speedAgeSec <= cfg.speedStaleAfterSec
        analyzer.append(event)

        // Background scheduler — sample-time driven (≈ wall-clock in the live app).
        if lastAnalysisT == -Double.infinity { lastAnalysisT = event.t }
        if event.t - lastAnalysisT >= cfg.analysisIntervalSec {
            lastAnalysisT = event.t
            analyzer.tick(now: event.t, finalFlush: false)
        }
    }

    private func transition(to s: State) {
        guard s != state else { return }
        state = s
        onStateChange?(s)
    }
}
