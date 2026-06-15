package com.kiters.wear.engine

import com.kiters.wear.model.DetectionMode
import com.kiters.wear.model.ImuSample
import com.kiters.wear.model.JumpDetectionConfig
import com.kiters.wear.model.Jump

// ================================================================
// V7 ADAPTER — drop-in replacement for the old v4 detector.
// Faithful port of JumpDetector.swift. Same external surface:
//   reset(mode), updateGps(...), processSample(sample),
//   onStateChanged, onJumpDetected, JumpState.
// Internally converts each ImuSample (+ latest GPS fix) into a v7
// SensorSample, feeds KitesurfSession, and maps JumpResult -> Jump.
// ================================================================
class JumpDetector(
    private val synchronousAnalysis: Boolean = false,
    private val backgroundExecutor: (() -> Unit) -> Unit = { it() },
    private val mainExecutor: (() -> Unit) -> Unit = { it() },
) {

    // v7 emits confidence 0..1; the rest of the app reads 0..100.
    private val confidenceAsPercent = true
    // Relaxed in dev/Toss-Test mode so a hand-toss still registers.
    private val acceptConfidence01: Double get() = if (devMode) 0.20 else 0.40

    // IMU fallback when the GPS speed gate fails (no/weak GPS): accept a jump
    // anyway if it has a clearly real airtime AND a rotation or high confidence.
    private val fallbackMinAirtimeSec = 1.5
    private val fallbackMinConfidence = 0.75

    enum class JumpState(val rawValue: String) {
        IDLE("IDLE"),
        RIDING("RIDING"),
        AIRBORNE("AIRBORNE"),
        COOLDOWN("COOLDOWN"),
    }

    var state: JumpState = JumpState.IDLE
        private set

    var onStateChanged: ((JumpState) -> Unit)? = null
    var onJumpDetected: ((Jump) -> Unit)? = null
    /** Wired by the Android layer to fire a vibration (strong=success, else notification). */
    var onHaptic: ((strong: Boolean) -> Unit)? = null

    /** Session id stamped onto produced jumps. */
    var sessionId: String = ""

    private lateinit var session: KitesurfSession
    private var mode: DetectionMode = DetectionMode.STANDARD

    private val devMode: Boolean get() = JumpDetectionConfig.shared.devMode
    private val stationarySpeed = 1.0   // m/s

    // GPS context (one-shot, mirrors old updateGPS behaviour)
    private var pendingSpeedMS: Double? = null
    private var pendingLat: Double? = null
    private var pendingLon: Double? = null
    private var pendingAccM: Double? = null
    private var latestSpeedMS: Double = 0.0

    private val gpsLock = Any()
    private val stateLock = Any()

    private var t0Wall: Double? = null
    private var sampleCount: Int = 0

    init {
        buildSession(DetectionMode.STANDARD)
    }

    fun reset(mode: DetectionMode = DetectionMode.STANDARD) {
        this.mode = mode
        buildSession(mode)

        synchronized(gpsLock) {
            pendingSpeedMS = null; pendingLat = null; pendingLon = null; pendingAccM = null
            latestSpeedMS = 0.0
        }
        t0Wall = null
        sampleCount = 0

        setState(JumpState.IDLE)
        session.start()
    }

    fun updateGps(
        speed: Double,
        altitude: Double,
        latitude: Double,
        longitude: Double,
        course: Double = -1.0,
        timestamp: Double,
    ) {
        val v = maxOf(0.0, speed)
        synchronized(gpsLock) {
            pendingSpeedMS = v
            pendingLat = latitude
            pendingLon = longitude
            pendingAccM = null
            latestSpeedMS = v
        }

        // Arming gate (mirrors the old IDLE<->RIDING speed gate).
        if (state == JumpState.IDLE || state == JumpState.RIDING) {
            if (devMode || v >= mode.minSpeed) setState(JumpState.RIDING)
            else if (v < stationarySpeed) setState(JumpState.IDLE)
        }
    }

    fun processSample(sample: ImuSample) {
        sampleCount += 1
        if (t0Wall == null) t0Wall = sample.timestamp
        val s = makeSensorSample(sample)
        session.onSample(s)
    }

    // Build / wire the v7 session
    private fun buildSession(mode: DetectionMode) {
        val cfg = KitesurfJumpEngineV7.Config().apply {
            releaseFloorG = mode.takeoffG
            landingSpikeG = mode.landingG
            minAirTimeSec = mode.minAirtime
            maxAirTimeSec = mode.maxAirtime
            kinematicCalibration = mode.kinematicCalibration

            // Toss-Test (dev) mode: relax the gates so tossing the watch in your
            // hand registers as a jump (short airtime, low height, gentle launch
            // and catch). The GPS speed gate is already bypassed for devMode in
            // the adapter's arming logic. Testing only.
            if (JumpDetectionConfig.shared.devMode) {
                releaseFloorG = 1.30
                minAirTimeSec = 0.25
                hardLandingMinAirTimeSec = 0.25
                minJumpHeightMeters = 0.20
                landingContactGyro = 0.8
                landingSpikeGyro = 0.5
            }
        }
        session = KitesurfSession(
            detectorConfig = cfg,
            refractorySec = mode.cooldown,
            synchronousAnalysis = synchronousAnalysis,
            backgroundExecutor = backgroundExecutor,
            mainExecutor = mainExecutor,
        ).apply {
            onStateChange = { mapV7State(it) }
            onJumpDetected = { emitJump(it) }
            onSpeedUpdate = { }
        }
    }

    private fun mapV7State(st: KitesurfSession.State) {
        when (st) {
            KitesurfSession.State.IDLE -> setState(JumpState.IDLE)
            KitesurfSession.State.RIDING ->
                setState(if (devMode || latestSpeedMS >= mode.minSpeed) JumpState.RIDING else JumpState.IDLE)
            KitesurfSession.State.AIRBORNE -> setState(JumpState.AIRBORNE)
            KitesurfSession.State.ANALYZING -> setState(JumpState.AIRBORNE)
        }
    }

    private fun setState(new: JumpState) {
        synchronized(stateLock) {
            if (new == state) return
            state = new
        }
        onStateChanged?.invoke(new)
    }

    private fun makeSensorSample(s: ImuSample): SensorSample {
        val t = s.timestamp - (t0Wall ?: s.timestamp)
        val grav = s.gravity
        val gravX = grav?.x ?: 0.0
        val gravY = grav?.y ?: 0.0
        val gravZ = grav?.z ?: -1.0

        val spd: Double?
        val lat: Double?
        val lon: Double?
        val acc: Double?
        synchronized(gpsLock) {
            spd = pendingSpeedMS; lat = pendingLat; lon = pendingLon; acc = pendingAccM
            pendingSpeedMS = null; pendingLat = null; pendingLon = null; pendingAccM = null
        }

        return SensorSample(
            t = t,
            ax = s.accelerationX, ay = s.accelerationY, az = s.accelerationZ,
            aM = s.accelerationMagnitude,
            gx = s.rotationX, gy = s.rotationY, gz = s.rotationZ,
            gM = s.rotationMagnitude,
            gravX = gravX, gravY = gravY, gravZ = gravZ,
            baro = s.pressure,
            gpsSpeedMS = spd,
            gpsLat = lat,
            gpsLon = lon,
            gpsAccuracyM = acc,
        )
    }

    private fun emitJump(r: JumpResult) {
        if (r.confidence < acceptConfidence01) return

        if (!devMode) {
            val minKnots = mode.minSpeed * 1.94384
            if (r.maxSessionSpeedKnots < minKnots) {
                // GPS speed gate failed (no/weak GPS, or not riding fast enough).
                // FALLBACK: still accept if the IMU shows a clearly real jump —
                // a genuine airtime AND either a rotation or high confidence.
                // Bumps/handling (short airtime, no spin, low confidence) stay rejected.
                val clearImuJump = r.airTimeSeconds >= fallbackMinAirtimeSec &&
                    (r.rotations >= 1 || r.confidence >= fallbackMinConfidence)
                if (!clearImuJump) return
            }
        }

        val end = System.currentTimeMillis()
        val start = end - (r.airTimeSeconds * 1000).toLong()
        val confidence = if (confidenceAsPercent) r.confidence * 100.0 else r.confidence

        val jump = Jump(
            sessionId = sessionId,
            startTimeMs = start,
            endTimeMs = end,
            height = r.jumpHeightMeters,
            airtime = r.displayedAirTimeSeconds,
            jumpDistance = r.jumpDistanceMeters ?: r.jumpDistanceGPSMeters ?: 0.0,
            rotations = r.rotations,
            confidence = confidence,
            apexTime = r.apexTimeSeconds,
        )

        val strong = (if (confidenceAsPercent) confidence else confidence * 100) >= 75
        onHaptic?.invoke(strong)
        onJumpDetected?.invoke(jump)
    }
}
