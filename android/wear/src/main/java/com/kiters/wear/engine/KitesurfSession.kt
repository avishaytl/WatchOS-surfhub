package com.kiters.wear.engine

import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sqrt

// ================================================================
// Real-Time Session Manager (streaming trigger).
// Faithful port of KitesurfSession from KitesurfJumpEngine.swift.
//
// The FSM only TRIGGERS analysis; the V7 detector does the math.
// All timing is in SECONDS, derived from the actual sample rate.
//
// Threading: when `synchronousAnalysis` is true, analysis runs inline
// (used by the offline replay/test harness). Otherwise it is handed to
// `backgroundExecutor`, with the result applied via `mainExecutor`
// (the Android layer supplies coroutine-dispatcher-backed executors).
// ================================================================
class KitesurfSession(
    detectorConfig: KitesurfJumpEngineV7.Config = KitesurfJumpEngineV7.Config(),
    refractorySec: Double = 1.0,
    private val synchronousAnalysis: Boolean = false,
    private val backgroundExecutor: (() -> Unit) -> Unit = { it() },
    private val mainExecutor: (() -> Unit) -> Unit = { it() },
) {

    enum class State { IDLE, RIDING, AIRBORNE, ANALYZING }

    // Time-based tunables (seconds / Hz-independent)
    private val preTailSec = 2.0
    private val postLandingSec = 1.0
    private val rollingSec = 6.0
    private val baselineWarmupSec = 8.0

    private val takeoffReleaseFloorG = detectorConfig.releaseFloorG
    private val releaseSigmaK = detectorConfig.releaseSigmaK
    private val minAirSec = detectorConfig.minAirTimeSec
    private val maxAirborneSec = detectorConfig.maxAirTimeSec
    private val refractorySec = maxOf(0.0, refractorySec)
    private val detectorLandingSpikeG = detectorConfig.landingSpikeG
    private val detectorNoiseFloorHPa = detectorConfig.baroNoiseFloorHPa

    // Derived from measured rate
    private var dt = K.dt
    private var hz = K.sampleRate
    private var rateLocked = false
    private val rateSamples = ArrayList<Double>()
    private var lastT: Double? = null

    private fun samples(sec: Double): Int = maxOf(1, (sec * hz).roundToInt())

    // State
    var state: State = State.IDLE
        private set
    private var rollingBuffer = CircularBuffer<SensorSample>((6.0 * K.sampleRate).roundToInt())
    private var jumpBuffer = ArrayList<SensorSample>()
    private val detector = KitesurfJumpEngineV7(detectorConfig)
    private var isAnalyzing = false

    // Adaptive ride statistics (for release threshold)
    private val rideWindow = ArrayList<Double>()
    private val rideWindowSec = 1.5

    // Adaptive baro baseline (slow EMA; frozen during a jump)
    private var sessionBaselineP = 0.0
    private var baselineWarmCount = 0
    private var baselineReady = false
    private var baselineFrozen = false
    private val baselineEMA = 0.01

    private var jumpMinPressure = Double.MAX_VALUE
    private var baselineAtTakeoff = 0.0
    private var takeoffT = 0.0
    private var takeoffIndexInBuffer = -1
    private var maxSessionSpeedMS = 0.0
    private val speedTop3 = ArrayList<Double>()
    private var refractoryUntil = Double.NEGATIVE_INFINITY
    private var postCountdown = 0
    private var settleRun = 0

    // Output
    var onJumpDetected: ((JumpResult) -> Unit)? = null
    var onSpeedUpdate: ((knots: Double) -> Unit)? = null
    var onStateChange: ((State) -> Unit)? = null

    // Lifecycle
    fun start() {
        rollingBuffer.clear()
        jumpBuffer.clear()
        rideWindow.clear()
        sessionBaselineP = 0.0; baselineWarmCount = 0
        baselineReady = false; baselineFrozen = false
        jumpMinPressure = Double.MAX_VALUE
        maxSessionSpeedMS = 0.0; speedTop3.clear()
        refractoryUntil = Double.NEGATIVE_INFINITY; isAnalyzing = false
        rateLocked = false; rateSamples.clear(); lastT = null; dt = K.dt; hz = K.sampleRate
        transition(State.RIDING)
    }

    fun stop() = transition(State.IDLE)

    // Sample ingestion
    fun onSample(s: SensorSample) {
        lockRate(s.t)

        // (1) GPS speed — robust max (median of top-3), independent of state.
        val spd = s.gpsSpeedMS
        if (spd != null && spd.isFinite() && spd > 0) {
            updateMaxSpeed(spd)
            onSpeedUpdate?.invoke(maxSessionSpeedMS * K.ms2kn)
        }

        // (2) Adaptive baro baseline — slow EMA, frozen during a jump.
        val p = s.baro
        if (p != null && p > 0 && !baselineFrozen) {
            if (!baselineReady) {
                sessionBaselineP = if (baselineWarmCount == 0) p else (sessionBaselineP + p) / 2
                baselineWarmCount += 1
                if (baselineWarmCount.toDouble() >= baselineWarmupSec * hz) baselineReady = true
            } else {
                sessionBaselineP = (1 - baselineEMA) * sessionBaselineP + baselineEMA * p
            }
        }

        // (3) FSM
        when (state) {
            State.IDLE -> {}

            State.RIDING -> {
                rollingBuffer.push(s)
                pushRide(s.accelMagG)
                if (s.t < refractoryUntil || !(baselineReady || s.baro == null)) return
                if (isReleaseSpike(s)) {
                    jumpBuffer = ArrayList(rollingBuffer.last(samples(preTailSec)))
                    takeoffIndexInBuffer = jumpBuffer.size - 1
                    takeoffT = s.t
                    baselineAtTakeoff = sessionBaselineP
                    jumpMinPressure = s.baro ?: sessionBaselineP
                    baselineFrozen = true
                    settleRun = 0
                    transition(State.AIRBORNE)
                }
            }

            State.AIRBORNE -> {
                rollingBuffer.push(s)
                jumpBuffer.add(s)
                s.baro?.let { jumpMinPressure = minOf(jumpMinPressure, it) }
                val air = s.t - takeoffT
                if (air > maxAirborneSec) { beginAnalyzing(); return }
                if (air >= minAirSec && landingDetected(s, air)) { beginAnalyzing(); return }
            }

            State.ANALYZING -> {
                rollingBuffer.push(s)
                jumpBuffer.add(s)
                postCountdown -= 1
                if (postCountdown <= 0 && !isAnalyzing) runDetector()
            }
        }
    }

    // Trigger helpers
    private fun beginAnalyzing() {
        postCountdown = samples(postLandingSec)
        transition(State.ANALYZING)
    }

    /** Adaptive release spike: rides with the chop (mu+K*sigma) but never below a floor. */
    private fun isReleaseSpike(s: SensorSample): Boolean {
        val a = s.accelMagG
        if (a < takeoffReleaseFloorG) return false
        if (rideWindow.size <= 10) return a >= takeoffReleaseFloorG
        val mu = DSP.median(rideWindow)
        val sd = std(rideWindow, DSP.mean(rideWindow))
        val thr = maxOf(takeoffReleaseFloorG, mu + releaseSigmaK * maxOf(sd, 0.05))
        // Require gyro energy too — a real launch spins the wrist; a knock does not.
        return a >= thr && s.gyroMag >= 1.5
    }

    /** Landing: hard impact OR (significant) baro recovery OR sustained settle. */
    private fun landingDetected(s: SensorSample, air: Double): Boolean {
        if (s.accelMagG >= detectorLandingSpikeG) return true
        val p = s.baro
        if (p != null) {
            val drop = baselineAtTakeoff - jumpMinPressure
            if (drop > detectorNoiseFloorHPa) {
                val recover = maxOf(drop * 0.08, detectorNoiseFloorHPa)
                if (p >= baselineAtTakeoff - recover) return true
            }
        }
        val rideMean = if (rideWindow.isEmpty()) 0.1 else DSP.median(rideWindow)
        if (abs(s.accelMagG - rideMean) < 0.35 && s.gyroMag < 8.0) {
            settleRun += 1
            if (settleRun >= 6) return true
        } else {
            settleRun = 0
        }
        return false
    }

    // Offline analysis
    private fun runDetector() {
        isAnalyzing = true
        val buffer = ArrayList(jumpBuffer)          // value copy -> thread-safe
        val hint = takeoffIndexInBuffer
        val peakSpeed = maxSessionSpeedMS

        val finish: (JumpResult?) -> Unit = { result ->
            if (result != null && result.confidence >= 0.40) onJumpDetected?.invoke(result)
            jumpBuffer.clear()
            takeoffIndexInBuffer = -1
            jumpMinPressure = Double.MAX_VALUE
            baselineFrozen = false
            settleRun = 0
            isAnalyzing = false
            refractoryUntil = (lastT ?: 0.0) + refractorySec
            transition(State.RIDING)
        }

        if (synchronousAnalysis) {
            val result = detector.process(buffer, if (hint >= 0) hint else null, peakSpeed)
            finish(result)
            return
        }

        backgroundExecutor {
            val result = detector.process(buffer, if (hint >= 0) hint else null, peakSpeed)
            mainExecutor { finish(result) }
        }
    }

    // Small utilities
    private fun lockRate(t: Double) {
        if (rateLocked) { lastT = t; return }
        val prev = lastT
        if (prev != null) {
            val d = t - prev
            if (d > 0.005 && d < 0.5) rateSamples.add(d)
            if (rateSamples.size >= 20) {
                val m = DSP.median(rateSamples)
                if (m > 0) { dt = m; hz = 1.0 / m }
                rateLocked = true
                val want = (rollingSec * hz).roundToInt()
                if (want != rollingBuffer.capacity) rollingBuffer = CircularBuffer(want)
            }
        }
        lastT = t
    }

    private fun updateMaxSpeed(spd: Double) {
        speedTop3.add(spd)
        speedTop3.sortDescending()
        if (speedTop3.size > 3) speedTop3.removeAt(speedTop3.size - 1)
        maxSessionSpeedMS = speedTop3.sum() / speedTop3.size
    }

    private fun pushRide(a: Double) {
        rideWindow.add(a)
        val cap = maxOf(10, (rideWindowSec * hz).roundToInt())
        if (rideWindow.size > cap) {
            val remove = rideWindow.size - cap
            repeat(remove) { rideWindow.removeAt(0) }
        }
    }

    private fun std(a: List<Double>, m: Double): Double {
        if (a.size <= 1) return 0.0
        return sqrt(a.sumOf { (it - m) * (it - m) } / a.size)
    }

    private fun transition(s: State) {
        state = s
        onStateChange?.invoke(s)
    }
}
