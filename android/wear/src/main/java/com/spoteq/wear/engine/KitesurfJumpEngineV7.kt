package com.spoteq.wear.engine

import com.spoteq.wear.model.JumpHeightSetting
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToLong

// ================================================================
// V7 Offline Detector (sensor-grounded, adaptive hybrid).
// Faithful port of KitesurfJumpEngineV7 from KitesurfJumpEngine.swift.
// Self-contained: derives its own pre-jump baseline + ride stats
// from the captured buffer (first ~25% = pre-takeoff tail).
// ================================================================
class KitesurfJumpEngineV7(private val cfg: Config = Config()) {

    data class Config(
        // Baro pipeline
        var baroMedianHalfWindow: Int = 7,
        var baroLowPassAlpha1: Double = 0.30,
        var baroLowPassAlpha2: Double = 0.15,
        // Baro significance
        var baroNoiseFloorHPa: Double = 0.03,
        var baroTrustLoHPa: Double = 0.06,
        var baroTrustHiHPa: Double = 0.18,
        // Event detection (adaptive, kite-aware)
        var releaseSigmaK: Double = 1.5,
        var releaseFloorG: Double = 1.70,
        var releaseGyroMinRad: Double = 2.0,
        var landingContactG: Double = 1.15,
        var landingContactGyro: Double = 2.0,
        var landingSpikeG: Double = 1.40,
        var landingSpikeGyro: Double = 1.0,
        var settleTolG: Double = 0.35,
        var settleSamplesNeeded: Int = 12,
        var minAirTimeSec: Double = 2.0,
        var hardLandingMinAirTimeSec: Double = 2.0,
        var settleMinAirTimeSec: Double = 3.80,
        var settleMinBaroDropHPa: Double = 0.06,
        var maxAirTimeSec: Double = 6.5,
        var minJumpHeightMeters: Double = JumpHeightSetting.DEFAULT_METERS,
        var timeoutRecoveryMinBaroDropHPa: Double = 0.35,
        var timeoutRecoveryMinPeakGyro: Double = 4.0,
        var timeoutRecoveryMinTakeoffG: Double = 2.0,
        var timeoutRecoveryMinHeightMeters: Double = 3.0,
        var timeoutRecoveryMinBurstSamples: Int = 14,
        // Gyro
        var gyroQualityThreshold: Double = 8.0,
        var gyroIsDegPerSec: Boolean? = false,
        // Live sensor-only behaviour
        var requireBaroBaselineBeforeTakeoff: Boolean = true,
        var baselineWarmupSec: Double = 8.0,
        // Kinematic calibration
        var kinematicCalibration: Double = 1.0,
        var enableIMUBiasCorrection: Boolean = true,
        // Kite-aware height (asymmetric arc)
        var airtimeCeilingTolerance: Double = 1.25,
        var maxPlausibleHeightM: Double = 50.0,
        var symmetricAscentFraction: Double = 0.143,
        var displayedAirtimeScale: Double = 0.73,
    )

    /** Public entry: analyse a captured jump buffer. */
    fun process(
        rawSamples: List<SensorSample>,
        takeoffHint: Int? = null,
        landingHint: Int? = null,
        landingKindHint: JumpResult.LandingKind? = null,
        maxSessionSpeedMS: Double,
    ): JumpResult? {
        val (samples, indexMap) = dedupeByTime(rawSamples)
        val t0Hint: Int? = takeoffHint?.let {
            if (it >= 0 && it < indexMap.size) indexMap[it].takeIf { v -> v >= 0 } else null
        }
        val tlHint: Int? = landingHint?.let {
            if (it >= 0 && it < indexMap.size) indexMap[it].takeIf { v -> v >= 0 } else null
        }
        val n = samples.size
        if (n < 12) return null
        val dt = estimateDt(samples)

        // BARO PIPELINE (median -> LP1 -> LP2). May be flat/absent.
        val haveBaro = samples.any { it.baro != null }
        val baroRaw = samples.map { it.baro ?: Double.NaN }
        val baroSmooth: List<Double> = if (haveBaro) {
            val filled = fillForward(baroRaw)
            val m = DSP.medianFilter(filled, cfg.baroMedianHalfWindow)
            val p1 = DSP.lowPass(m, cfg.baroLowPassAlpha1)
            DSP.lowPass(p1, cfg.baroLowPassAlpha2)
        } else {
            List(n) { 0.0 }
        }

        // ACCEL / GYRO magnitudes
        val accMag = samples.map { it.accelMagG }
        val gyroScale = resolveGyroScale(samples)
        val gyroMag = samples.map { it.gyroMag * gyroScale }

        // RIDE BASELINE (pre-takeoff tail = first 25%)
        val baseWindow = maxOf(4, n / 4)
        val rideMeanA = DSP.median(accMag.subList(0, baseWindow))
        val rideStdA = DSP.std(accMag.subList(0, baseWindow))
        val baselineP = if (haveBaro) DSP.median(baroSmooth.subList(0, baseWindow)) else 0.0

        // TAKEOFF: adaptive release spike + airborne confirmation
        val releaseThr = maxOf(cfg.releaseFloorG, rideMeanA + cfg.releaseSigmaK * maxOf(rideStdA, 0.05))
        var t0 = -1
        if (t0Hint != null && t0Hint > 1 && t0Hint < n - 4) {
            t0 = t0Hint
        } else {
            var i = 2
            while (i < n - 4) {
                if (accMag[i] >= releaseThr) {
                    val gyroAhead = gyroMag.subList(i, minOf(n - 1, i + 6) + 1).maxOrNull() ?: 0.0
                    if (gyroAhead >= cfg.releaseGyroMinRad ||
                        (haveBaro && willBaroDrop(baroSmooth, i, baselineP))
                    ) {
                        t0 = i; break
                    }
                }
                i++
            }
        }
        if (t0 == -1) return null

        // LANDING: contact OR hard impact OR baro recovery OR settle
        val minAS = (cfg.minAirTimeSec / dt).toInt()
        val maxAS = (cfg.maxAirTimeSec / dt).toInt()
        val hardMinAS = maxOf(minAS, (cfg.hardLandingMinAirTimeSec / dt).toInt())
        val settleMinAS = maxOf(minAS, (cfg.settleMinAirTimeSec / dt).toInt())
        var tl = -1
        var landingKind = JumpResult.LandingKind.TIMEOUT
        var jumpMinP = if (haveBaro) baselineP else 0.0

        if (tlHint != null && tlHint > t0 && tlHint < n && (tlHint - t0) >= minAS && (tlHint - t0) <= maxAS) {
            tl = tlHint
            landingKind = landingKindHint ?: JumpResult.LandingKind.CONTACT
            if (haveBaro) {
                for (k in (t0 + 1)..tl) jumpMinP = minOf(jumpMinP, baroSmooth[k])
            }
        } else {
            var softLandingIndex = -1
            var softLandingKind = JumpResult.LandingKind.TIMEOUT
            var settleRun = 0
            var i = t0 + 1
            while (i < n && (i - t0) <= maxAS) {
                if (haveBaro) jumpMinP = minOf(jumpMinP, baroSmooth[i])
                val air = (i - t0).toDouble() * dt

                if (air >= cfg.minAirTimeSec) {
                    // (a) first water/board contact
                    if (accMag[i] >= cfg.landingContactG && gyroMag[i] >= cfg.landingContactGyro) {
                        tl = i; landingKind = JumpResult.LandingKind.CONTACT; break
                    }
                    // (b) hard impact
                    if ((i - t0) >= hardMinAS && accMag[i] >= cfg.landingSpikeG && gyroMag[i] >= cfg.landingSpikeGyro) {
                        tl = i; landingKind = JumpResult.LandingKind.HARD_IMPACT; break
                    }
                    // (c) baro recovery
                    if ((i - t0) >= hardMinAS && haveBaro) {
                        val drop = baselineP - jumpMinP
                        if (drop > cfg.baroNoiseFloorHPa) {
                            val recover = maxOf(drop * 0.08, cfg.baroNoiseFloorHPa)
                            if (baroSmooth[i] >= baselineP - recover && softLandingIndex == -1) {
                                softLandingIndex = i
                                softLandingKind = JumpResult.LandingKind.BARO_RECOVERY
                            }
                        }
                    }
                    // (d) settle after a real pressure dip
                    val settleBaroOK = haveBaro && (baselineP - jumpMinP) >= cfg.settleMinBaroDropHPa
                    if (settleBaroOK &&
                        (i - t0) >= settleMinAS &&
                        abs(accMag[i] - rideMeanA) < cfg.settleTolG &&
                        gyroMag[i] < cfg.gyroQualityThreshold
                    ) {
                        settleRun += 1
                        if (settleRun >= cfg.settleSamplesNeeded && (i - t0) > minAS && softLandingIndex == -1) {
                            softLandingIndex = i
                            softLandingKind = JumpResult.LandingKind.SETTLE
                        }
                    } else {
                        settleRun = 0
                    }
                }
                i++
            }
            if (tl == -1 && softLandingIndex != -1) {
                tl = softLandingIndex
                landingKind = softLandingKind
            }
        }
        if (tl == -1) { tl = minOf(n - 1, t0 + maxAS); landingKind = JumpResult.LandingKind.TIMEOUT }
        if (tl <= t0) return null

        val airTimeSec = (tl - t0).toDouble() * dt

        // GPS metrics (computed before height gate)
        val jumpDistSpeedTime = distanceSpeedTime(samples, t0, airTimeSec)
        val jumpDistGPS = distanceGPS(samples, t0, tl)

        // BAROMETRIC HEIGHT (may be ~0)
        val dP = if (haveBaro) maxOf(0.0, baselineP - jumpMinP) else 0.0
        val baroH = if (dP > cfg.baroNoiseFloorHPa) dP * K.p2m else 0.0

        // KINEMATIC HEIGHTS (kite-aware, asymmetric arc)
        val symCeilingH = K.g * airTimeSec * airTimeSec / 8.0
        var tRise = airTimeSec * cfg.symmetricAscentFraction
        if (haveBaro && dP >= cfg.baroTrustHiHPa) {
            var minIdx = t0
            var mp = Double.MAX_VALUE
            for (k in t0..tl) {
                if (baroSmooth[k] < mp) { mp = baroSmooth[k]; minIdx = k }
            }
            val tr = (minIdx - t0).toDouble() * dt
            if (tr > 0.1 && tr < airTimeSec - 0.05) tRise = tr
        }
        val riseH = cfg.kinematicCalibration * 0.5 * K.g * tRise * tRise

        // PHYSICAL CONSISTENCY GATE
        val airtimeCeiling = symCeilingH * cfg.airtimeCeilingTolerance
        val baroConsistent = dP >= cfg.baroTrustHiHPa && baroH > 0 && baroH <= airtimeCeiling

        // HEIGHT SELECTION
        val heightM: Double
        val source: JumpResult.HeightSource
        if (baroConsistent) {
            val baroTrust = DSP.clamp(
                (dP - cfg.baroTrustLoHPa) / (cfg.baroTrustHiHPa - cfg.baroTrustLoHPa), 0.0, 1.0
            )
            val baroClamped = minOf(baroH, airtimeCeiling)
            heightM = baroTrust * baroClamped + (1 - baroTrust) * riseH
            source = if (baroTrust >= 0.85) JumpResult.HeightSource.BAROMETRIC
            else if (baroTrust <= 0.15) JumpResult.HeightSource.KINEMATIC
            else JumpResult.HeightSource.BLENDED
        } else {
            heightM = riseH
            source = JumpResult.HeightSource.KINEMATIC
        }
        val fusedH = minOf(heightM, cfg.maxPlausibleHeightM)

        // HEIGHT GATE
        if (fusedH < cfg.minJumpHeightMeters) return null

        // APEX (integrate gravity-projected vertical accel)
        val apex = integrateApex(samples, t0, tl, dt).first

        // ROTATIONS (gyro integral over the air phase)
        var totalRad = 0.0
        for (k in (t0 + 1)..tl) totalRad += gyroMag[k] * dt
        val rotations = floor(totalRad / K.twoPi).toInt()

        // GYRO QUALITY (for confidence)
        val gyroQ = gyroMag.map { maxOf(0.0, 1 - it / (cfg.gyroQualityThreshold * 2.5)) }
        val avgGyroQ = DSP.mean(gyroQ.subList(t0, tl + 1))
        val peakGyro = gyroMag.subList(t0, tl + 1).maxOrNull() ?: 0.0
        val peakTakeoffG = accMag.subList(maxOf(0, t0 - 2), minOf(n - 1, t0 + 4) + 1).maxOrNull() ?: 0.0
        var timeoutBurstRun = 0
        var timeoutMaxBurstRun = 0
        for (k in t0..tl) {
            if (accMag[k] >= releaseThr && gyroMag[k] >= cfg.releaseGyroMinRad) {
                timeoutBurstRun += 1
                timeoutMaxBurstRun = maxOf(timeoutMaxBurstRun, timeoutBurstRun)
            } else {
                timeoutBurstRun = 0
            }
        }

        if (landingKind == JumpResult.LandingKind.TIMEOUT) {
            val baroTimeoutRecovered =
                dP >= cfg.timeoutRecoveryMinBaroDropHPa &&
                    fusedH >= cfg.timeoutRecoveryMinHeightMeters &&
                    peakGyro >= cfg.timeoutRecoveryMinPeakGyro &&
                    peakTakeoffG >= cfg.timeoutRecoveryMinTakeoffG
            val inertialTimeoutRecovered =
                dP < cfg.baroNoiseFloorHPa &&
                    fusedH >= cfg.timeoutRecoveryMinHeightMeters &&
                    peakGyro >= cfg.timeoutRecoveryMinPeakGyro &&
                    peakTakeoffG >= cfg.timeoutRecoveryMinTakeoffG &&
                    timeoutMaxBurstRun >= cfg.timeoutRecoveryMinBurstSamples
            if (!baroTimeoutRecovered && !inertialTimeoutRecovered) return null
        }

        // CONFIDENCE (physics-linked)
        var conf = 0.55
        if (baroConsistent && abs(baroH - riseH) / maxOf(baroH, riseH, 0.1) < 0.4) conf += 0.20
        if (peakTakeoffG >= releaseThr * 1.3) conf += 0.15 else if (peakTakeoffG >= releaseThr) conf += 0.08
        conf += 0.10 // Sensor-only path; GPS never gates confidence.
        if (airTimeSec >= 1.0) conf += 0.05
        if (landingKind == JumpResult.LandingKind.TIMEOUT) conf -= 0.20
        if (peakGyro > cfg.gyroQualityThreshold * 2.5) conf -= 0.15
        if (haveBaro && baroH > 0 && !baroConsistent) conf -= 0.15
        conf -= (1 - avgGyroQ) * 0.10
        conf = DSP.clamp(conf, 0.0, 1.0)

        fun r2(v: Double) = (v * 100).roundToLong() / 100.0
        fun r1(v: Double) = (v * 10).roundToLong() / 10.0

        return JumpResult(
            jumpHeightMeters = r2(DSP.clamp(fusedH, 0.0, 25.0)),
            baroHeightMeters = r2(baroH),
            kinematicHeightMeters = r2(riseH),
            airTimeSeconds = r2(airTimeSec),
            displayedAirTimeSeconds = r2(airTimeSec * cfg.displayedAirtimeScale),
            apexTimeSeconds = apex?.let { r2(it) },
            rotations = rotations,
            jumpDistanceMeters = jumpDistSpeedTime,
            jumpDistanceGPSMeters = jumpDistGPS,
            maxSessionSpeedKnots = r1(maxSessionSpeedMS * K.ms2kn),
            maxSessionSpeedKmh = r1(maxSessionSpeedMS * K.ms2kmh),
            confidence = (conf * 1000).roundToLong() / 1000.0,
            landingKind = landingKind,
            heightSource = source,
            takeoffTimeSeconds = samples[t0].t,
            landingTimeSeconds = samples[tl].t,
            deltaPressureHPa = (dP * 10000).roundToLong() / 10000.0,
            peakTakeoffG = r2(peakTakeoffG),
            peakGyro = r2(peakGyro),
            avgGyroQuality = (avgGyroQ * 1000).roundToLong() / 1000.0,
            takeoffIndex = t0,
            landingIndex = tl,
        )
    }

    // Apex via gravity-projected vertical-accel integration
    private fun integrateApex(s: List<SensorSample>, t0: Int, tl: Int, dt: Double): Pair<Double?, Double> {
        val vert = s.map { smp ->
            val (gx, gy, gz) = DSP.normalize3(smp.gravX, smp.gravY, smp.gravZ)
            -DSP.dot3(smp.ax, smp.ay, smp.az, gx, gy, gz)
        }
        var bias = 0.0
        if (cfg.enableIMUBiasCorrection && t0 > 3) bias = DSP.median(vert.subList(0, t0))
        var v = 0.0
        var prevV: Double
        var elapsed = 0.0
        var peakV = 0.0
        var apex: Double? = null
        for (k in (t0 + 1)..tl) {
            val aMps2 = (vert[k] - bias) * K.g
            prevV = v
            v += aMps2 * dt
            elapsed += dt
            peakV = maxOf(peakV, v)
            if (apex == null && prevV > 0.05 && v <= 0.05) {
                val frac = DSP.clamp(prevV / (prevV - v + 1e-9), 0.0, 1.0)
                apex = elapsed - dt + frac * dt
            }
        }
        return Pair(apex, peakV)
    }

    // Distance: GPS speed x air time (best for short jumps)
    private fun distanceSpeedTime(s: List<SensorSample>, t0: Int, airTimeSec: Double): Double? {
        val tT = s[t0].t
        var best: Double? = null
        var bestDt = Double.POSITIVE_INFINITY
        for (smp in s) {
            val spd = smp.gpsSpeedMS ?: continue
            if (!spd.isFinite()) continue
            val d = abs(smp.t - tT)
            if (d < bestDt) { bestDt = d; best = spd }
        }
        val spd = best ?: return null
        if (bestDt > 3.0) return null
        return minOf(150.0, (spd * airTimeSec * 10).roundToLong() / 10.0)
    }

    // Distance: GPS position haversine (limited by 1 Hz)
    private fun distanceGPS(s: List<SensorSample>, t0: Int, tl: Int): Double? {
        data class P(val i: Int, val t: Double, val lat: Double, val lon: Double)
        val pts = s.mapIndexedNotNull { idx, x ->
            val la = x.gpsLat ?: return@mapIndexedNotNull null
            val lo = x.gpsLon ?: return@mapIndexedNotNull null
            if (!la.isFinite() || !lo.isFinite()) return@mapIndexedNotNull null
            P(idx, x.t, la, lo)
        }
        if (pts.size < 2) return null
        val tT = s[t0].t
        val tL = s[tl].t
        val nearT = pts.minByOrNull { abs(it.t - tT) }!!
        var nearL = pts.minByOrNull { abs(it.t - tL) }!!
        if (nearT.i == nearL.i) {
            val alt = pts.filter { it.i != nearT.i }.minByOrNull { abs(it.t - tL) } ?: return null
            nearL = alt
        }
        return (GpsUtil.haversine(nearT.lat, nearT.lon, nearL.lat, nearL.lon) * 10).roundToLong() / 10.0
    }

    // Helpers
    private fun willBaroDrop(baro: List<Double>, i: Int, baseline: Double): Boolean {
        val end = minOf(baro.size - 1, i + (2.0 / K.dt).toInt())
        if (end <= i) return false
        val mn = baro.subList(i, end + 1).minOrNull() ?: baseline
        return (baseline - mn) > cfg.baroNoiseFloorHPa
    }

    /** Forward-fill NaNs, then back-fill any leading NaNs. */
    private fun fillForward(a: List<Double>): List<Double> {
        val out = a.toMutableList()
        var last = a.firstOrNull { !it.isNaN() } ?: 1013.25
        for (k in out.indices) {
            if (out[k].isNaN()) out[k] = last else last = out[k]
        }
        return out
    }

    private fun resolveGyroScale(s: List<SensorSample>): Double {
        cfg.gyroIsDegPerSec?.let { return if (it) K.deg2rad else 1.0 }
        val mags = s.map { it.gyroMag }
        return if (DSP.median(mags) > 10) K.deg2rad else 1.0
    }

    private fun estimateDt(s: List<SensorSample>): Double {
        if (s.size < 6) return K.dt
        val diffs = ArrayList<Double>()
        for (i in 1 until minOf(40, s.size)) {
            val d = s[i].t - s[i - 1].t
            if (d > 0.005 && d < 0.5) diffs.add(d)
        }
        return if (diffs.size > 3) DSP.median(diffs) else K.dt
    }

    companion object {
        /** Drop samples whose timestamp does not advance; returns cleaned series + indexMap. */
        fun dedupeByTime(s: List<SensorSample>): Pair<List<SensorSample>, IntArray> {
            val out = ArrayList<SensorSample>(s.size)
            val indexMap = IntArray(s.size) { -1 }
            var lastT = Double.NEGATIVE_INFINITY
            for (i in s.indices) {
                if (s[i].t > lastT) { indexMap[i] = out.size; out.add(s[i]); lastT = s[i].t }
                else indexMap[i] = out.size - 1
            }
            return Pair(out, indexMap)
        }
    }
}
