// //
// //  JumpDetector.swift
// //  iSurf-Watch
// //
// //  Barometer-first jump detection — simple & accurate.
// //
// //  ═══════════════════════════════════════════════════════════════
// //  ALGORITHM v4 — Barometer-Primary, 4 States, 6 Parameters
// //  ═══════════════════════════════════════════════════════════════
// //
// //  States:  IDLE → RIDING → AIRBORNE → COOLDOWN
// //
// //  Detection pipeline:
// //    1. IDLE:     waiting for GPS speed ≥ minSpeed → RIDING
// //    2. RIDING:   watching for takeoff spike (accel ≥ takeoffG)
// //                 then low-g confirmation → AIRBORNE
// //    3. AIRBORNE: tracking pressure curve + accel
// //                 landing impact (accel ≥ landingG) OR
// //                 accel returns to ~1g for sustained period → finalize
// //    4. COOLDOWN: pause before next detection
// //
// //  Height formula (barometer):
// //    h = ΔP × 8.3 m/hPa  (physics constant at sea level)
// //    where ΔP = baselinePressure − minPressure during jump
// //    Fallback (no baro): h = g·t²/8  (kinematic, symmetric arc)
// //
// //  Confidence (simple):
// //    Start at 50. Add points for:
// //      +20 barometer confirmed height > 0.3m
// //      +15 clean takeoff spike
// //      +10 ride-away (speed still > 2 m/s after landing)
// //      +5  airtime > 1s
// //      −20 no speed (stationary)
// //      −15 chaotic gyro (possible toss)
// //
// //  Only 6 user-tunable parameters:
// //    minSpeed, takeoffG, landingG, minAirtime, maxAirtime, cooldown
// //
// //  ═══════════════════════════════════════════════════════════════

// import Foundation
// #if os(watchOS)
// import WatchKit
// #endif
// import os

// class JumpDetector {

//     // MARK: - State Machine

//     enum JumpState: String, CustomStringConvertible {
//         case idle     = "IDLE"
//         case riding   = "RIDING"
//         case airborne = "AIRBORNE"
//         case cooldown = "COOLDOWN"

//         var description: String { rawValue }

//         var emoji: String {
//             switch self {
//             case .idle:     return "⏸️"
//             case .riding:   return "🏄"
//             case .airborne: return "✈️"
//             case .cooldown: return "⏳"
//             }
//         }
//     }

//     private(set) var state: JumpState = .idle

//     /// UI callback for state changes
//     var onStateChanged: ((JumpState) -> Void)?

//     // MARK: - Constants

//     /// Barometric height factor: metres per hPa at sea level (~8.3 m/hPa)
//     private let baroFactor: Double = 8.3

//     /// Low-g ceiling — below this counts as "in the air".
//     private let lowGCeiling: Double = 0.40

//     /// How many low-g samples needed to confirm airborne (at 50Hz ≈ 60ms)
//     private let lowGConfirmSamples: Int = 3

//     /// How many consecutive samples must exceed `takeoffG` to count as a takeoff.
//     /// At 50Hz, 2 samples ≈ 40ms — long enough to reject brief hand-wave impulses
//     /// (which last 1 sample) while not rejecting legitimate sharp pop-ups.
//     private let takeoffConfirmSamples: Int = 2

//     /// Minimum ratio of vertical to total accel for a takeoff candidate.
//     /// Horizontal hand-waves produce high magnitude but low vertical component,
//     /// so this filters them out.
//     private let takeoffVerticalRatio: Double = 0.6

//     /// Speed below which we consider the rider stationary
//     private let stationarySpeed: Double = 1.0  // m/s

//     // MARK: - Thresholds (from DetectionMode)

//     private var mode: DetectionMode = .standard

//     /// Dev mode: skip GPS speed gate for toss-testing
//     private var devMode: Bool { JumpDetectionConfig.shared.devMode }

//     /// Session logger reference for per-sample logging
//     private let logger = SessionLogger.shared

//     // MARK: - GPS Context
//     // os_unfair_lock is ~10x faster than NSLock for short critical sections.
//     // At 50 Hz reads this matters.
//     private var gpsLock = os_unfair_lock()
//     private var _speed: Double = 0
//     private var _lat: Double = 0
//     private var _lon: Double = 0

//     private var speed: Double {
//         get { os_unfair_lock_lock(&gpsLock); defer { os_unfair_lock_unlock(&gpsLock) }; return _speed }
//         set { os_unfair_lock_lock(&gpsLock); defer { os_unfair_lock_unlock(&gpsLock) }; _speed = newValue }
//     }

//     // MARK: - Jump Tracking

//     private var takeoffTime: Date?
//     private var landingTime: Date?
//     private var takeoffSpeed: Double = 0
//     private var jumpSamples: [IMUSample] = []
//     private var lowGCount: Int = 0
//     /// Consecutive-samples counter for sustained takeoff spike detection.
//     private var takeoffSpikeCount: Int = 0
//     /// Peak vertical-accel observed during the candidate spike (in g).
//     private var takeoffPeakVerticalG: Double = 0

//     // Barometer
//     private var baselinePressure: Double = 0     // rolling average while riding (filtered)
//     private var minPressure: Double = 0          // lowest during airborne (filtered)
//     private var hasBaro: Bool = false

//     // ── Pressure filter pipeline (v5-inspired) ──
//     // Pressure arrives ~1Hz from CMAltimeter but is read 50×/s; we only run
//     // the filter on actual *new* values to avoid duplicate work and biasing
//     // the LP states with replicated samples.
//     private var lastRawPressure: Double = 0
//     /// Median ring buffer (size 7) — strips spikes from board/bar vibration.
//     private var pressureMedianBuffer: [Double] = []
//     private let pressureMedianSize = 7
//     /// Two-stage IIR low-pass for a smooth pressure curve (α₁=0.30, α₂=0.15).
//     private var pressureLP1: Double = 0
//     private var pressureLP2: Double = 0
//     /// Latest filtered pressure (output of the median→LP1→LP2 chain).
//     private var filteredPressure: Double = 0

//     // ── IMU bias correction (v5-inspired) ──
//     // Sliding 2-second buffer of vertical-accel (in g) sampled while RIDING.
//     // At takeoff we capture median(buffer)−1.0 as the steady-state offset and
//     // subtract it during airborne integration so MEMS drift doesn't pollute
//     // the apex estimate.
//     private var verticalAccelBuffer: [Double] = []
//     private let verticalAccelBufferSize = 100  // 2s × 50Hz
//     private var imuBiasG: Double = 0           // in g

//     // ── Apex detection ──
//     // Numeric integration of (verticalAccelG − 1.0 − bias)·g during airborne.
//     // Sign convention: positive = upward.
//     private var verticalVelocity: Double = 0   // m/s
//     private var prevVerticalVelocity: Double = 0
//     private var apexAirtime: Double?           // seconds from takeoff
//     private var lastAirborneSampleTime: Date?

//     // Cooldown
//     private var cooldownStart: Date?

//     // Debug
//     private var sampleCount: Int = 0
//     private var lastSampleTime: Date?

//     // ── Performance: throttle CSV logging ──
//     // Log every Nth sample during calm states (IDLE/RIDING without pending takeoff).
//     // During active detection (pending takeoff, AIRBORNE) log every sample.
//     private let logEveryN: Int = 5  // 50Hz → 10Hz for calm periods

//     // MARK: - Callbacks

//     var onJumpDetected: ((Jump) -> Void)?

//     // MARK: - Public API

//     func reset(mode: DetectionMode = .standard) {
//         self.mode = mode
//         state = .idle
//         onStateChanged?(state)

//         takeoffTime = nil
//         landingTime = nil
//         takeoffSpeed = 0
//         jumpSamples.removeAll()
//         lowGCount = 0
//         takeoffSpikeCount = 0
//         takeoffPeakVerticalG = 0
//         baselinePressure = 0
//         minPressure = 0
//         hasBaro = false
//         lastRawPressure = 0
//         pressureMedianBuffer.removeAll(keepingCapacity: true)
//         pressureLP1 = 0
//         pressureLP2 = 0
//         filteredPressure = 0
//         verticalAccelBuffer.removeAll(keepingCapacity: true)
//         imuBiasG = 0
//         verticalVelocity = 0
//         prevVerticalVelocity = 0
//         apexAirtime = nil
//         lastAirborneSampleTime = nil
//         cooldownStart = nil
//         sampleCount = 0
//         lastSampleTime = nil

//         os_unfair_lock_lock(&gpsLock)
//         _speed = 0; _lat = 0; _lon = 0
//         os_unfair_lock_unlock(&gpsLock)

//         print("🦘 JumpDetector v4 reset — \(mode.displayName)  minSpd=\(Int(mode.minSpeed * 3.6))km/h  tkoff=\(mode.takeoffG)g  land=\(mode.landingG)g  air=\(mode.minAirtime)-\(mode.maxAirtime)s  cd=\(mode.cooldown)s  dev=\(devMode)")
//     }

//     func updateGPS(speed: Double, altitude: Double, latitude: Double, longitude: Double, course: Double = -1, timestamp: Date) {
//         os_unfair_lock_lock(&gpsLock)
//         _speed = max(0, speed)
//         _lat = latitude
//         _lon = longitude
//         os_unfair_lock_unlock(&gpsLock)

//         // Transition from idle to riding when we detect movement
//         if state == .idle && speed >= mode.minSpeed {
//             transitionTo(.riding)
//         }
//     }

//     func processSample(_ sample: IMUSample) {
//         sampleCount += 1
//         let accel = sample.accelerationMagnitude
//         let now = sample.timestamp
//         lastSampleTime = now

//         // ── Barometer pipeline: median → LP₁ → LP₂ (only on new raw values) ──
//         // Pressure is reported by CMAltimeter at ~1Hz but processSample runs
//         // at 50Hz, so most calls reuse the previous value. Filtering only on
//         // changes prevents replicated samples from biasing the IIR state.
//         if let pRaw = sample.pressure, pRaw > 0, pRaw != lastRawPressure {
//             filteredPressure = filterPressure(pRaw)
//             lastRawPressure = pRaw
//         }

//         // ── Track baseline only while riding/idle (not airborne) ──
//         // Tracking during the dip would partially flatten it.
//         if filteredPressure > 0, state == .idle || state == .riding {
//             if baselinePressure == 0 {
//                 baselinePressure = filteredPressure
//             } else {
//                 // EMA α=0.07 on the already-smoothed signal: tracks slow
//                 // weather/altitude drift while preserving the takeoff dip.
//                 baselinePressure = 0.93 * baselinePressure + 0.07 * filteredPressure
//             }
//         }

//         // ── Sliding vertical-accel buffer for IMU-bias estimation ──
//         // Captured during RIDING so that at takeoff we have a fresh 2s
//         // baseline for the apex integrator (subtracts MEMS offset).
//         if state == .riding {
//             verticalAccelBuffer.append(verticalAccelG(of: sample))
//             if verticalAccelBuffer.count > verticalAccelBufferSize {
//                 verticalAccelBuffer.removeFirst()
//             }
//         }

//         // ── Per-sample CSV log ──
//         // Always log at full sensor rate (50Hz) when state != IDLE, so
//         // post-mortem analysis has the complete riding→takeoff→airborne→
//         // landing trace. In IDLE we throttle to 10Hz to limit log size.
//         if state != .idle || sampleCount % logEveryN == 0 {
//             logger.logSample(
//                 sample: sample,
//                 speed: speed,
//                 baselinePressure: baselinePressure,
//                 lowGCount: lowGCount,
//                 state: state.rawValue
//             )
//         }

//         // Heartbeat log (reduced frequency to avoid string formatting cost)
//         if sampleCount % 1000 == 0 {
//             print("📊 [\(state)] #\(sampleCount) a=\(String(format:"%.2f",accel))g spd=\(String(format:"%.0f",speed*3.6))km/h")
//         }

//         switch state {
//         case .idle:     handleIdle(sample: sample, accel: accel)
//         case .riding:   handleRiding(sample: sample, accel: accel)
//         case .airborne: handleAirborne(sample: sample, accel: accel)
//         case .cooldown: handleCooldown(sample: sample)
//         }
//     }

//     // ═══════════════════════════════════════════════════════════════
//     // MARK: - IDLE
//     // ═══════════════════════════════════════════════════════════════

//     private func handleIdle(sample: IMUSample, accel: Double) {
//         if devMode || speed >= mode.minSpeed {
//             logger.logEvent("IDLE→RIDING (dev=\(devMode) spd=\(String(format:"%.1f",speed*3.6))km/h)", state: "IDLE", speed: speed)
//             transitionTo(.riding)
//         }
//     }

//     // ═══════════════════════════════════════════════════════════════
//     // MARK: - RIDING — looking for takeoff
//     // ═══════════════════════════════════════════════════════════════

//     private func handleRiding(sample: IMUSample, accel: Double) {
//         // Drop back to idle if we slow down (skip in dev mode)
//         if !devMode && speed < stationarySpeed {
//             logger.logEvent("RIDING→IDLE (slow spd=\(String(format:"%.1f",speed*3.6)))", state: "RIDING", speed: speed)
//             transitionTo(.idle)
//             return
//         }

//         // ── Sustained-spike takeoff detection ──
//         // A real kitesurf takeoff produces accel ≥ takeoffG sustained over
//         // ≥2 samples (≅40ms at 50Hz). Hand-waves and abrupt arm motion produce
//         // single-sample impulses that we reject. We do NOT require vertical
//         // dominance because real kitesurf forces are predominantly horizontal.
//         let spikeCandidate = accel >= mode.takeoffG

//         if takeoffTime == nil {
//             if spikeCandidate {
//                 takeoffSpikeCount += 1
//                 takeoffPeakVerticalG = max(takeoffPeakVerticalG, verticalAccelG(of: sample))
//                 if takeoffSpikeCount >= takeoffConfirmSamples {
//                     // Confirmed sustained takeoff — promote to candidate
//                     takeoffTime = sample.timestamp
//                     takeoffSpeed = speed
//                     jumpSamples = [sample]
//                     lowGCount = 0
//                     minPressure = baselinePressure
//                     hasBaro = false

//                     // Capture IMU bias from the steady-state RIDING window.
//                     if verticalAccelBuffer.count >= 50 {
//                         let sorted = verticalAccelBuffer.sorted()
//                         let mid = sorted.count / 2
//                         let median = sorted.count % 2 == 0
//                             ? (sorted[mid - 1] + sorted[mid]) / 2.0
//                             : sorted[mid]
//                         imuBiasG = median - 1.0
//                     } else {
//                         imuBiasG = 0
//                     }

//                     verticalVelocity = 0
//                     prevVerticalVelocity = 0
//                     apexAirtime = nil
//                     lastAirborneSampleTime = nil

//                     logger.logSample(sample: sample, speed: speed, baselinePressure: baselinePressure, lowGCount: lowGCount, state: "RIDING", event: "TAKEOFF_SPIKE a=\(String(format:"%.2f",accel))g vG=\(String(format:"%.2f",takeoffPeakVerticalG)) bias=\(String(format:"%.3f",imuBiasG))g")
//                     print("🚀 Takeoff spike! a=\(String(format:"%.2f",accel))g vG=\(String(format:"%.2f",takeoffPeakVerticalG))  spd=\(String(format:"%.0f",speed*3.6))km/h  bias=\(String(format:"%.3f",imuBiasG))g")
//                 }
//             } else {
//                 // Reset on any non-spike sample (strict contiguous counter).
//                 if takeoffSpikeCount > 0 {
//                     takeoffSpikeCount = 0
//                     takeoffPeakVerticalG = 0
//                 }
//             }
//             return
//         }

//         // If we have a confirmed takeoff candidate, watch for low-g confirmation.
//         // We accept EITHER convention for "low-g":
//         //   • raw user-accel magnitude < ceiling          (older synthetic logs
//         //     where airborne is encoded as userAccel ≈ 0)
//         //   • gravity-aware verticalAccelG < ceiling      (real CMDeviceMotion
//         //     where free-fall reports userAccel ≈ +1g UP, so the magnitude
//         //     stays near 1g but verticalAccelG correctly drops to 0)
//         // Either signal alone is sufficient evidence of free-fall.
//         // Strict contiguous counter: any sample above the ceiling resets it.
//         let vertG = verticalAccelG(of: sample)
//         if accel < lowGCeiling || vertG < lowGCeiling {
//             lowGCount += 1
//         } else {
//             lowGCount = 0
//         }

//         jumpSamples.append(sample)

//         // Log every sample during takeoff confirmation
//         logger.logSample(sample: sample, speed: speed, baselinePressure: baselinePressure, lowGCount: lowGCount, state: "RIDING", event: "lowG=\(lowGCount)/\(lowGConfirmSamples) a=\(String(format:"%.2f",accel))")

//         // Confirmed airborne
//         if lowGCount >= lowGConfirmSamples {
//             logger.logEvent("RIDING→AIRBORNE (lowG×\(lowGCount))", state: "RIDING", speed: speed)
//             transitionTo(.airborne)
//             print("✈️ AIRBORNE confirmed (lowG×\(lowGCount))")
//             return
//         }

//         // Timeout — false takeoff
//         if let t0 = takeoffTime, sample.timestamp.timeIntervalSince(t0) > 0.5 {
//             logger.logEvent("FALSE_TAKEOFF (no low-g in 0.5s)", state: "RIDING", speed: speed)
//             print("❌ False takeoff (no low-g)")
//             takeoffTime = nil
//             jumpSamples.removeAll()
//             lowGCount = 0
//             takeoffSpikeCount = 0
//             takeoffPeakVerticalG = 0
//         }
//     }

//     // ═══════════════════════════════════════════════════════════════
//     // MARK: - AIRBORNE — tracking pressure curve + waiting for landing
//     // ═══════════════════════════════════════════════════════════════

//     private func handleAirborne(sample: IMUSample, accel: Double) {
//         guard let t0 = takeoffTime else { transitionTo(.riding); return }
//         let airtime = sample.timestamp.timeIntervalSince(t0)

//         jumpSamples.append(sample)

//         // Track barometer minimum on the *filtered* pressure so that
//         // single-sample spikes from board impact / strap rattle don't
//         // produce a fake "very high jump".
//         if filteredPressure > 0 {
//             if minPressure == 0 || filteredPressure < minPressure {
//                 minPressure = filteredPressure
//             }
//             hasBaro = true
//         }

//         // ── Apex detection: integrate (verticalAccel − 1.0 − bias)·g ──
//         // Apex = the moment vertical velocity crosses from positive to
//         // non-positive. We use linear interpolation between samples for
//         // sub-tick precision.
//         if let prev = lastAirborneSampleTime {
//             let dt = sample.timestamp.timeIntervalSince(prev)
//             if dt > 0 && dt < 0.1 {
//                 let vG = verticalAccelG(of: sample)            // gravity-corrected, in g
//                 let aMps2 = (vG - 1.0 - imuBiasG) * 9.81       // upward = positive, m/s²
//                 prevVerticalVelocity = verticalVelocity
//                 verticalVelocity += aMps2 * dt

//                 if apexAirtime == nil
//                     && prevVerticalVelocity > 0.05
//                     && verticalVelocity <= 0.05 {
//                     let denom = prevVerticalVelocity - verticalVelocity + 1e-9
//                     let frac = max(0.0, min(1.0, prevVerticalVelocity / denom))
//                     apexAirtime = (airtime - dt) + frac * dt
//                 }
//             }
//         }
//         lastAirborneSampleTime = sample.timestamp

//         // ── Detect landing ──
//         // Hard landing: accel spike ≥ landingG
//         if accel >= mode.landingG && airtime >= mode.minAirtime {
//             landingTime = sample.timestamp
//             logger.logSample(sample: sample, speed: speed, baselinePressure: baselinePressure, lowGCount: lowGCount, state: "AIRBORNE", event: "HARD_LAND a=\(String(format:"%.2f",accel))g air=\(String(format:"%.2f",airtime))s")
//             finalize(airtime: airtime)
//             return
//         }

//         // Threshold-crossing landing (v5-inspired):
//         // Once we're past minAirtime, declare landing when filtered pressure
//         // climbs back within max(8% × current drop, 0.03 hPa) of baseline.
//         // This handles soft landings (kite glides) where there is no impact
//         // spike but the rider clearly returns to riding altitude.
//         if airtime >= mode.minAirtime, hasBaro,
//            baselinePressure > 0, minPressure > 0 {
//             let currentDrop = baselinePressure - minPressure
//             if currentDrop > 0 {
//                 let recoveryThreshold = max(currentDrop * 0.08, 0.03)
//                 if filteredPressure >= baselinePressure - recoveryThreshold {
//                     landingTime = sample.timestamp
//                     logger.logSample(sample: sample, speed: speed, baselinePressure: baselinePressure, lowGCount: lowGCount, state: "AIRBORNE", event: "BARO_LAND drop=\(String(format:"%.3f",currentDrop)) air=\(String(format:"%.2f",airtime))s")
//                     print("🛬 Pressure-recovery landing (drop=\(String(format:"%.3f",currentDrop)) hPa)")
//                     finalize(airtime: airtime)
//                     return
//                 }
//             }
//         }

//         // Soft landing: vertical accel back to ~1g (±0.3) for several samples.
//         // Uses world-frame vertical projection (userAccel · ĝ + |g|) instead of
//         // the raw 3-axis magnitude, so a watch tilted mid-rotation — where
//         // gravity redistributes across axes but |a|≈1g — doesn't trigger a
//         // premature landing.
//         if airtime >= mode.minAirtime {
//             let recent = jumpSamples.suffix(8)
//             let normalCount = recent.filter { abs(verticalAccelG(of: $0) - 1.0) < 0.3 }.count
//             if normalCount >= 6 {
//                 landingTime = sample.timestamp
//                 logger.logSample(sample: sample, speed: speed, baselinePressure: baselinePressure, lowGCount: lowGCount, state: "AIRBORNE", event: "SOFT_LAND norm=\(normalCount)/8 air=\(String(format:"%.2f",airtime))s")
//                 print("🛬 Soft landing (accel normalized)")
//                 finalize(airtime: airtime)
//                 return
//             }
//         }

//         // Timeout
//         if airtime > mode.maxAirtime {
//             logger.logEvent("AIRBORNE_TIMEOUT air=\(String(format:"%.1f",airtime))s", state: "AIRBORNE", speed: speed)
//             print("⚠️ Airtime timeout (\(String(format:"%.1f",airtime))s > \(mode.maxAirtime)s)")
//             resetToRiding()
//         }
//     }

//     // ═══════════════════════════════════════════════════════════════
//     // MARK: - FINALIZE — compute height + confidence
//     // ═══════════════════════════════════════════════════════════════

//     private func finalize(airtime: Double) {
//         guard let t0 = takeoffTime else { resetToRiding(); return }

//         // ── Height ──
//         let baroHeight = computeBaroHeight()
//         let kinematicHeight = computeKinematicHeight(airtime: airtime)

//         // Prefer barometer if available and gave a reasonable reading
//         let height: Double
//         if hasBaro && baroHeight > 0.2 {
//             height = baroHeight
//         } else {
//             height = kinematicHeight
//         }

//         // Clamp to reasonable range
//         let clampedHeight = max(0.3, min(25.0, height))

//         // ── Confidence ──
//         let confidence = computeConfidence(
//             airtime: airtime,
//             baroHeight: baroHeight,
//             hasBaro: hasBaro
//         )

//         // ── Distance ──
//         let jumpDist = min(150.0, takeoffSpeed * airtime)

//         // ── Rotations ──
//         let rotations = countRotations(samples: jumpSamples)

//         // Build jump
//         var jump = Jump(sessionId: "", startTime: t0)
//         jump.endTime = landingTime ?? Date()
//         jump.height = clampedHeight
//         jump.airtime = airtime
//         jump.jumpDistance = jumpDist
//         jump.rotations = rotations
//         jump.confidence = confidence
//         jump.imuSamples = jumpSamples
//         jump.apexTime = apexAirtime

//         let accepted = confidence >= 50

//         let apexStr = apexAirtime.map { String(format: "%.2f", $0) } ?? "-"
//         let result = "\(accepted ? "ACCEPTED" : "REJECTED") h=\(String(format:"%.2f",clampedHeight))m(\(hasBaro ? "baro" : "kin")) air=\(String(format:"%.2f",airtime))s apex=\(apexStr)s conf=\(Int(confidence)) dist=\(String(format:"%.0f",jumpDist))m rot=\(rotations)"
//         logger.logEvent("JUMP_\(result)", state: "FINALIZE", speed: speed)

//         print("""
//         \(accepted ? "🎉" : "🗑") JUMP \(accepted ? "ACCEPTED" : "REJECTED") \
//         h=\(String(format:"%.2f",clampedHeight))m (\(hasBaro ? "baro" : "kin"))  \
//         air=\(String(format:"%.2f",airtime))s  \
//         conf=\(Int(confidence))  \
//         dist=\(String(format:"%.0f",jumpDist))m  rot=\(rotations)
//         """)

//         if accepted {
//             #if os(watchOS)
//             WKInterfaceDevice.current().play(confidence >= 75 ? .success : .notification)
//             #endif
//             onJumpDetected?(jump)
//         }

//         enterCooldown()
//     }

//     // ═══════════════════════════════════════════════════════════════
//     // MARK: - Height Estimation
//     // ═══════════════════════════════════════════════════════════════

//     /// Barometer: h = ΔP × 8.3 m/hPa
//     private func computeBaroHeight() -> Double {
//         guard hasBaro, baselinePressure > 0, minPressure > 0 else { return 0 }
//         let deltaP = baselinePressure - minPressure
//         guard deltaP > 0 else { return 0 }
//         return deltaP * baroFactor
//     }

//     /// Kinematic fallback: h = k · g·t²/8  (assumes symmetric parabolic arc).
//     /// `k` is the user-tunable calibration factor (default 1.12) which
//     /// compensates for the typical underestimation seen in real jumps where
//     /// the peak is asymmetric (boost on takeoff, weighted landing).
//     private func computeKinematicHeight(airtime: Double) -> Double {
//         let g = 9.81
//         return mode.kinematicCalibration * g * airtime * airtime / 8.0
//     }

//     /// Total vertical (world-axis) acceleration of a sample, expressed in g.
//     /// At rest this returns ~1.0; in free-fall it returns ~0.0; on hard
//     /// landing it returns >1.0. Robust to device rotation because we project
//     /// `userAcceleration` onto the gravity unit vector before adding |g|.
//     private func verticalAccelG(of sample: IMUSample) -> Double {
//         guard let g = sample.gravity else {
//             return sample.accelerationMagnitude
//         }
//         let gMag = sqrt(g.x * g.x + g.y * g.y + g.z * g.z)
//         guard gMag > 0.01 else {
//             return sample.accelerationMagnitude
//         }
//         let dot = (sample.accelerationX * g.x +
//                    sample.accelerationY * g.y +
//                    sample.accelerationZ * g.z) / gMag
//         return abs(dot + gMag)
//     }

//     /// 3-stage pressure filter: median(7) → IIR α=0.30 → IIR α=0.15.
//     /// Median strips single-sample spikes from board impact / strap
//     /// rattle that would otherwise produce phantom altitude swings;
//     /// the cascaded IIRs deliver a smooth pressure curve. Called only
//     /// when a *new* raw value arrives (~1Hz from CMAltimeter), so cost
//     /// is negligible (≤ 7 sorted comparisons + 2 multiplies per second).
//     private func filterPressure(_ raw: Double) -> Double {
//         pressureMedianBuffer.append(raw)
//         if pressureMedianBuffer.count > pressureMedianSize {
//             pressureMedianBuffer.removeFirst()
//         }
//         let sorted = pressureMedianBuffer.sorted()
//         let medianValue: Double
//         let n = sorted.count
//         if n == 0 {
//             medianValue = raw
//         } else if n % 2 == 0 {
//             medianValue = (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
//         } else {
//             medianValue = sorted[n / 2]
//         }

//         // First IIR
//         if pressureLP1 == 0 { pressureLP1 = medianValue }
//         else { pressureLP1 = 0.30 * medianValue + 0.70 * pressureLP1 }

//         // Second IIR
//         if pressureLP2 == 0 { pressureLP2 = pressureLP1 }
//         else { pressureLP2 = 0.15 * pressureLP1 + 0.85 * pressureLP2 }

//         return pressureLP2
//     }

//     // ═══════════════════════════════════════════════════════════════
//     // MARK: - Confidence
//     // ═══════════════════════════════════════════════════════════════

//     private func computeConfidence(airtime: Double, baroHeight: Double, hasBaro: Bool) -> Double {
//         var conf: Double = 50

//         // +20: barometer confirms real height
//         if hasBaro && baroHeight > 0.3 {
//             conf += 20
//         }

//         // +15: clean takeoff (accel spike was well above threshold)
//         let peakTakeoff = jumpSamples.prefix(10).map { $0.accelerationMagnitude }.max() ?? 0
//         if peakTakeoff >= mode.takeoffG * 1.3 {
//             conf += 15
//         } else if peakTakeoff >= mode.takeoffG {
//             conf += 8
//         }

//         // +10: still moving after landing (ride-away)
//         if speed >= stationarySpeed * 2 {
//             conf += 10
//         }

//         // +5: decent airtime
//         if airtime >= 1.0 {
//             conf += 5
//         }

//         // −20: was stationary at takeoff (skip in dev mode)
//         if !devMode && takeoffSpeed < stationarySpeed {
//             conf -= 20
//         }

//         // −15: chaotic gyro (possible watch toss) — skip in dev mode
//         if !devMode && jumpSamples.count >= 10 {
//             let gyros = jumpSamples.map { $0.rotationMagnitude }
//             let avgGyro = gyros.reduce(0, +) / Double(gyros.count)
//             let maxGyro = gyros.max() ?? 0
//             // A tossed watch spins wildly with high average AND high max
//             if avgGyro > 8.0 && maxGyro > 15.0 {
//                 conf -= 15
//             }
//         }

//         return max(0, min(100, conf))
//     }

//     // ═══════════════════════════════════════════════════════════════
//     // MARK: - Rotation Detection
//     // ═══════════════════════════════════════════════════════════════

//     /// Count full rotations (2π rad) by integrating the 3-axis gyro magnitude
//     /// over the airborne samples. Using `rotationMagnitude` √(ωx²+ωy²+ωz²)
//     /// captures spins (yaw), flips (pitch), and barrel rolls (roll), not just
//     /// the Z-axis spins the previous implementation tracked.
//     private func countRotations(samples: [IMUSample]) -> Int {
//         guard samples.count > 1 else { return 0 }
//         var totalRad: Double = 0
//         for i in 1..<samples.count {
//             let dt = samples[i].timestamp.timeIntervalSince(samples[i-1].timestamp)
//             totalRad += samples[i].rotationMagnitude * dt
//         }
//         return Int(totalRad / (2 * .pi))
//     }

//     // ═══════════════════════════════════════════════════════════════
//     // MARK: - State Transitions
//     // ═══════════════════════════════════════════════════════════════

//     private func transitionTo(_ newState: JumpState) {
//         let old = state
//         state = newState
//         if old != newState {
//             logger.logEvent("\(old.rawValue)→\(newState.rawValue)", state: newState.rawValue, speed: speed)
//             onStateChanged?(newState)
//         }
//     }

//     // ═══════════════════════════════════════════════════════════════
//     // MARK: - COOLDOWN
//     // ═══════════════════════════════════════════════════════════════

//     private func handleCooldown(sample: IMUSample) {
//         guard let cs = cooldownStart else { transitionTo(.riding); return }
//         if sample.timestamp.timeIntervalSince(cs) >= mode.cooldown {
//             transitionTo(speed >= mode.minSpeed ? .riding : .idle)
//             print("✅ Cooldown done")
//         }
//     }

//     private func enterCooldown() {
//         // Use the most recent sample timestamp (not wall-clock) so replay
//         // sessions advance the cooldown timer correctly when the synthetic
//         // sample stream is in the past or future relative to `Date()`.
//         cooldownStart = lastSampleTime ?? Date()
//         transitionTo(.cooldown)
//         clearJumpState()
//     }

//     private func resetToRiding() {
//         transitionTo(speed >= stationarySpeed ? .riding : .idle)
//         clearJumpState()
//     }

//     private func clearJumpState() {
//         takeoffTime = nil
//         landingTime = nil
//         takeoffSpeed = 0
//         jumpSamples.removeAll()
//         lowGCount = 0
//         hasBaro = false
//     }
// }
//
//  JumpDetector.swift
//  iSurf-Watch
//
//  ═══════════════════════════════════════════════════════════════
//  V7 ADAPTER — drop-in replacement for the v4 barometer-primary
//  detector. Same PUBLIC API; the brain is now KitesurfJumpEngineV7.
//  ═══════════════════════════════════════════════════════════════
//
//  WHY THIS FILE EXISTS
//  --------------------
//  The old JumpDetector was a 4-state FSM that computed height itself
//  (barometer-primary). Real 50 Hz watch logs proved the v7 approach
//  is far more accurate (sensor-grounded adaptive hybrid: kinematic ⇄
//  baro, adaptive release threshold, gyro-confirmed take-off, three
//  landing models). v7 lives in `KitesurfJumpEngine.swift` as two
//  classes:
//      • KitesurfSession        — streaming FSM that TRIGGERS analysis
//      • KitesurfJumpEngineV7   — offline analyser that does the math
//
//  This adapter keeps the EXACT external surface the rest of the watch
//  app already calls, so nothing else has to change:
//      • init()
//      • var state: JumpState        (.idle/.riding/.airborne/.cooldown)
//      • var onStateChanged: ((JumpState) -> Void)?
//      • var onJumpDetected:  ((Jump) -> Void)?
//      • func reset(mode: DetectionMode = .standard)
//      • func updateGPS(speed:altitude:latitude:longitude:course:timestamp:)
//      • func processSample(_ sample: IMUSample)
//
//  Internally it converts each `IMUSample` (+ the latest GPS fix) into
//  a v7 `SensorSample`, feeds `KitesurfSession`, and maps the v7
//  `JumpResult` back into your existing `Jump` model.
//
//  ═══════════════════════════════════════════════════════════════
//  ⚠️ ASSUMPTIONS — VERIFY THESE AGAINST THE REAL MAC TYPES
//  ═══════════════════════════════════════════════════════════════
//  I did NOT have the source of IMUSample / Jump / DetectionMode /
//  SessionLogger / JumpDetectionConfig. Every assumption below is
//  drawn from how the OLD JumpDetector.swift used them, so they should
//  match — but please confirm. Each is tagged `// ASSUMPTION:` inline
//  and gathered here for a quick audit:
//
//  IMUSample — assumed members (all used by the old code):
//    .timestamp                : Date
//    .accelerationX/Y/Z        : Double   (userAcceleration, g, gravity removed)
//    .accelerationMagnitude    : Double   (g)
//    .rotationMagnitude        : Double   (rad/s, |ω|)
//    .pressure                 : Double?  (hPa)            — optional
//    .gravity                  : (some Vector3?)           — optional, has .x/.y/.z (g)
//    ── NOT proven to exist, NEEDED by v7 for rotations/apex axis ──
//    .rotationX/Y/Z            : Double?  gyro per-axis (rad/s)
//        If your IMUSample does NOT expose per-axis gyro, see
//        `makeSensorSample` — we fall back to magnitude-only and v7
//        still works (rotations come from |ω|, apex from gravity-proj
//        of linear accel). Per-axis gyro is only a nice-to-have.
//
//  Jump — assumed to be a mutable struct/class with:
//    init(sessionId: String, startTime: Date)
//    var endTime: Date
//    var height, airtime, jumpDistance, confidence: Double
//    var rotations: Int
//    var imuSamples: [IMUSample]
//    var apexTime: Double?
//        confidence UNITS: the old code emitted 0…100 and accepted ≥50.
//        v7 emits 0…1. This adapter SCALES v7 conf ×100 so downstream
//        code that reads `jump.confidence` keeps the same 0…100 scale.
//        If your UI already expects 0…1, set `CONFIDENCE_AS_PERCENT=false`.
//
//  DetectionMode — assumed to expose (old code read all of these):
//    .standard (default case), .displayName: String,
//    .minSpeed, .takeoffG, .landingG, .minAirtime, .maxAirtime,
//    .cooldown, .kinematicCalibration : Double
//        We map these onto KitesurfJumpEngineV7.Config + KitesurfSession
//        tunables so your existing DetectionMode presets still steer v7.
//
//  SessionLogger.shared / JumpDetectionConfig.shared — kept OPTIONAL.
//    Logging calls are wrapped so this file compiles even if their
//    signatures differ; see `Log` helper at the bottom. If you want the
//    old CSV trace back, wire `Log.sample`/`Log.event` to your logger.
//
//  HOW TO INSTALL ON THE MAC
//  -------------------------
//    1. Drop BOTH files into the watch target:
//         • KitesurfJumpEngine.swift   (the v7 brain — unchanged)
//         • JumpDetector.swift         (this adapter — replaces old one)
//    2. Build. Fix any `// ASSUMPTION:` that the compiler flags
//       (field name mismatches are the only likely errors).
//    3. The rest of the app keeps calling JumpDetector exactly as before.
//
//  ═══════════════════════════════════════════════════════════════

import Foundation
#if os(watchOS)
import WatchKit
#endif
import os

final class JumpDetector {

    // MARK: - Tuning toggles (adapter-level)

    /// v7 emits confidence 0…1. The old detector emitted 0…100 and the
    /// rest of the app likely still reads `jump.confidence` on that scale.
    /// Keep true to preserve behaviour; set false if your UI wants 0…1.
    private let CONFIDENCE_AS_PERCENT = true

    /// v7 already gates internally on confidence ≥ 0.40 before firing.
    /// This is an ADDITIONAL gate the adapter applies, matching the old
    /// "accept ≥ 50/100" rule. Set to 0 to defer entirely to v7.
    private let acceptConfidence01: Double = 0.40

    // MARK: - Public State Machine (UNCHANGED surface)

    enum JumpState: String, CustomStringConvertible {
        case idle     = "IDLE"
        case riding   = "RIDING"
        case airborne = "AIRBORNE"
        case cooldown = "COOLDOWN"

        var description: String { rawValue }

        var emoji: String {
            switch self {
            case .idle:     return "⏸️"
            case .riding:   return "🏄"
            case .airborne: return "✈️"
            case .cooldown: return "⏳"
            }
        }
    }

    private(set) var state: JumpState = .idle

    /// UI callback for state changes (UNCHANGED).
    var onStateChanged: ((JumpState) -> Void)?

    /// Jump callback (UNCHANGED — emits your existing `Jump` model).
    var onJumpDetected: ((Jump) -> Void)?

    // MARK: - v7 engine

    private var session: KitesurfSession!
    private var mode: DetectionMode = .standard

    /// Session id stamped onto produced `Jump`s. The old code passed "".
    /// Set this from your workout controller if you have a real id.
    var sessionId: String = ""

    /// When true the underlying v7 session analyses jumps INLINE and delivers
    /// callbacks synchronously. Used by the offline JumpReplay harness; the
    /// live app keeps this false. MUST be set before `reset(mode:)`.
    var synchronousAnalysis = false

    /// Dev mode mirrors the old detector: skips the GPS speed (arming) gate so
    /// jumps can be toss-tested without riding.
    private var devMode: Bool { JumpDetectionConfig.shared.devMode }

    /// Speed below which the rider is considered stopped (disarm hysteresis).
    private let stationarySpeed: Double = 1.0   // m/s

    // MARK: - GPS context (one-shot, mirrors old updateGPS behaviour)
    // The old detector kept the latest GPS fix and read it lazily. v7
    // wants GPS attached to each SensorSample, so we hold the latest fix
    // here and stamp it onto the next IMU sample, then clear it (one-shot)
    // exactly like the v7 usage example does.
    private var pendingSpeedMS: Double?
    private var pendingLat: Double?
    private var pendingLon: Double?
    private var pendingAccM: Double?

    // os_unfair_lock guards the one-shot pending GPS fix + latest speed, which
    // are written on the CoreLocation thread and read/cleared on the motion
    // thread inside processSample. os_unfair_lock guards `state` mutations,
    // which arrive from the location, motion and analysis threads.
    private var gpsLock = os_unfair_lock()
    private var stateLock = os_unfair_lock()
    /// Latest smoothed GPS speed (m/s), retained for the arming + stationary
    /// gates (NOT cleared each sample, unlike the one-shot pending fields).
    private var latestSpeedMS: Double = 0

    // MARK: - Monotonic time base
    // v7 wants MONOTONIC seconds since session start (not wall-clock).
    // We derive it from the first sample's timestamp.
    private var t0Wall: Date?

    /// Per-sample counter used to throttle CSV logging during IDLE.
    private var sampleCount: Int = 0

    // MARK: - Init

    init() {
        buildSession(for: .standard)
    }

    // MARK: - Public API (UNCHANGED signatures)

    func reset(mode: DetectionMode = .standard) {
        self.mode = mode
        buildSession(for: mode)

        os_unfair_lock_lock(&gpsLock)
        pendingSpeedMS = nil; pendingLat = nil; pendingLon = nil; pendingAccM = nil
        latestSpeedMS = 0
        os_unfair_lock_unlock(&gpsLock)
        t0Wall = nil
        sampleCount = 0

        setState(.idle)
        session.start()       // v7 starts in its own .riding; we surface .idle
                              // until first movement keeps the old UX, see setState mapping.
        // Immediately reflect "ready/riding" if you prefer the old behaviour
        // of showing RIDING only after minSpeed. We keep IDLE here and let
        // GPS/first spike drive transitions, matching old semantics.

        Log.event("JumpDetector(v7) reset — \(mode.displayNameSafe) "
            + "minSpd=\(Int(mode.minSpeedSafe * 3.6))km/h tkoff=\(mode.takeoffGSafe)g "
            + "land=\(mode.landingGSafe)g air=\(mode.minAirtimeSafe)-\(mode.maxAirtimeSafe)s "
            + "cd=\(mode.cooldownSafe)s")
    }

    func updateGPS(speed: Double,
                   altitude: Double,
                   latitude: Double,
                   longitude: Double,
                   course: Double = -1,
                   timestamp: Date) {
        let v = max(0, speed)
        os_unfair_lock_lock(&gpsLock)
        pendingSpeedMS = v
        pendingLat = latitude
        pendingLon = longitude
        pendingAccM = nil   // ASSUMPTION: old code had no horizontalAccuracy here.
        latestSpeedMS = v
        os_unfair_lock_unlock(&gpsLock)

        // ── Arming gate (mirrors the old IDLE↔RIDING speed gate) ──
        // v7's FSM is always "riding"; the adapter surfaces IDLE until the
        // rider is moving ≥ minSpeed, and drops back to IDLE when stopped.
        // Only applies while not airborne/analysing (state .idle/.riding).
        if state == .idle || state == .riding {
            if devMode || v >= mode.minSpeedSafe {
                setState(.riding)
            } else if v < stationarySpeed {
                setState(.idle)
            }
        }
    }

    func processSample(_ sample: IMUSample) {
        sampleCount += 1
        // Establish the monotonic base on the first sample.
        if t0Wall == nil { t0Wall = sample.timestamp }

        let s = makeSensorSample(sample)   // reads + clears the one-shot GPS fix
        session.onSample(s)

        // ── Per-sample CSV trace (restored from the v4 detector) ──
        // Full rate while active; throttled to ~10 Hz during IDLE to bound
        // log size. v7's internals stay private, so baseline/lowG are 0.
        if state != .idle || sampleCount % 5 == 0 {
            SessionLogger.shared.logSample(
                sample: sample,
                speed: latestSpeedMS,
                baselinePressure: 0,
                lowGCount: 0,
                state: state.rawValue
            )
        }
    }

    // MARK: - Build / wire the v7 session

    private func buildSession(for mode: DetectionMode) {
        var cfg = KitesurfJumpEngineV7.Config.default

        // ── Map your DetectionMode presets onto v7 config ──
        // These are the v7 levers that correspond to the old 6 params.
        cfg.releaseFloorG       = mode.takeoffGSafe          // take-off spike floor
        cfg.landingSpikeG       = mode.landingGSafe          // hard-landing impact
        cfg.minAirTimeSec       = mode.minAirtimeSafe
        cfg.maxAirTimeSec       = mode.maxAirtimeSafe
        cfg.kinematicCalibration = mode.kinematicCalibrationSafe
        // minSpeed → handled by the adapter's arming gate (updateGPS).
        // cooldown → v7 refractory window between consecutive jumps.
        session = KitesurfSession(detectorConfig: cfg,
                                  refractorySec: mode.cooldownSafe,
                                  synchronousAnalysis: synchronousAnalysis)

        session.onStateChange = { [weak self] st in
            self?.mapV7State(st)
        }
        session.onJumpDetected = { [weak self] result in
            self?.emitJump(from: result)
        }
        session.onSpeedUpdate = { _ in
            // Old detector had no speed callback; nothing to forward.
            // Hook your speed dial here if desired.
        }
    }

    // MARK: - v7 → adapter state mapping

    private func mapV7State(_ st: KitesurfSession.State) {
        switch st {
        case .idle:
            setState(.idle)
        case .riding:
            // Respect the arming gate: show IDLE when the rider is not moving.
            setState((devMode || latestSpeedMS >= mode.minSpeedSafe) ? .riding : .idle)
        case .airborne:
            setState(.airborne)
        case .analyzing:
            setState(.airborne)   // still "in the air" from the UX view
        }
    }

    private func setState(_ new: JumpState) {
        os_unfair_lock_lock(&stateLock)
        guard new != state else { os_unfair_lock_unlock(&stateLock); return }
        state = new
        os_unfair_lock_unlock(&stateLock)
        onStateChanged?(new)
        Log.event("state→\(new.rawValue)")
    }

    // MARK: - IMUSample → v7 SensorSample

    private func makeSensorSample(_ s: IMUSample) -> SensorSample {
        // Monotonic seconds since the first sample.
        let t = s.timestamp.timeIntervalSince(t0Wall ?? s.timestamp)

        // Gravity vector (g). ASSUMPTION: s.gravity is optional with .x/.y/.z.
        let gravX = s.gravitySafe?.x ?? 0
        let gravY = s.gravitySafe?.y ?? 0
        let gravZ = s.gravitySafe?.z ?? -1   // default "up" if gravity missing

        // IMUSample exposes per-axis gyro (rotationX/Y/Z, rad/s); pass it through
        // so v7 can use it. gM is also provided as the precomputed magnitude.
        // Read + clear the one-shot GPS fix atomically (written on the location
        // thread, consumed here on the motion thread).
        os_unfair_lock_lock(&gpsLock)
        let spd = pendingSpeedMS, lat = pendingLat, lon = pendingLon, acc = pendingAccM
        pendingSpeedMS = nil; pendingLat = nil; pendingLon = nil; pendingAccM = nil
        os_unfair_lock_unlock(&gpsLock)

        return SensorSample(
            t:  t,
            ax: s.accelerationX, ay: s.accelerationY, az: s.accelerationZ,
            aM: s.accelerationMagnitude,
            gx: s.rotationX, gy: s.rotationY, gz: s.rotationZ,
            gM: s.rotationMagnitude,
            gravX: gravX, gravY: gravY, gravZ: gravZ,
            baro: s.pressureSafe,
            gpsSpeedMS: spd,
            gpsLat: lat,
            gpsLon: lon,
            gpsAccuracyM: acc
        )
    }

    // MARK: - v7 JumpResult → your Jump model

    private func emitJump(from r: JumpResult) {
        // Adapter-level accept gate (mirrors old conf≥50 rule). v7 already
        // gated at 0.40 before calling us, so this is usually a no-op.
        guard r.confidence >= acceptConfidence01 else {
            Log.event("JUMP rejected by adapter (conf=\(String(format: "%.2f", r.confidence)))")
            return
        }

        // Arming gate: reject stationary "jumps" (watch handling / toss) unless
        // dev mode. v7 reports the robust session max speed in knots.
        if !devMode {
            let minKnots = mode.minSpeedSafe * 1.94384   // m/s → knots
            if r.maxSessionSpeedKnots < minKnots {
                Log.event("JUMP rejected: maxSpeed \(r.maxSessionSpeedKnots)kn < minSpeed \(String(format: "%.1f", minKnots))kn")
                return
            }
        }

        // Reconstruct the wall-clock window from air time (v7 returns no raw
        // buffer, so we anchor the end at "now" and back-date the start).
        let end = Date()
        let start = end.addingTimeInterval(-r.airTimeSeconds)
        var jump = Jump(sessionId: sessionId, startTime: start)
        jump.endTime      = end
        jump.height       = r.jumpHeightMeters
        jump.airtime      = r.airTimeSeconds
        jump.jumpDistance = r.jumpDistanceMeters ?? r.jumpDistanceGPSMeters ?? 0
        jump.rotations    = r.rotations
        jump.apexTime     = r.apexTimeSeconds
        jump.confidence   = CONFIDENCE_AS_PERCENT ? r.confidence * 100.0 : r.confidence
        // imuSamples: v7 does not return the raw buffer; leave empty unless you
        // want to retain it. If your downstream needs the trace, capture it in
        // processSample into a ring and attach here.
        jump.imuSamples   = []

        #if os(watchOS)
        let strong = (CONFIDENCE_AS_PERCENT ? jump.confidence : jump.confidence * 100) >= 75
        WKInterfaceDevice.current().play(strong ? .success : .notification)
        #endif

        Log.event("JUMP ACCEPTED h=\(r.jumpHeightMeters)m air=\(r.airTimeSeconds)s "
            + "rot=\(r.rotations) conf=\(jump.confidence) src=\(r.heightSource.rawValue) "
            + "land=\(r.landingKind.rawValue)")

        onJumpDetected?(jump)
    }
}

// ════════════════════════════════════════════════════════════════
// MARK: - Logging shim (optional, no hard dependency)
// ════════════════════════════════════════════════════════════════
// The old detector logged to SessionLogger.shared. To keep this file
// self-contained and compilable without that type, logging routes
// through this shim. Replace the bodies to call your real logger.
private enum Log {
    static func event(_ msg: @autoclosure () -> String) {
        let m = msg()
        #if DEBUG
        print("🦘 \(m)")
        #endif
        // Restore the CSV event trace consumed by diagnostics + cloud upload.
        SessionLogger.shared.logEvent(m)
    }
}

// ════════════════════════════════════════════════════════════════
// MARK: - Safe accessors for assumed external types
// ════════════════════════════════════════════════════════════════
// These computed properties isolate every ASSUMPTION about the Mac's
// types in ONE place. If the compiler complains about a field name,
// fix it HERE and the rest of the adapter stays untouched.
//
// IMPORTANT: if a field already exists with EXACTLY the assumed name and
// type, the *Safe shim is redundant but harmless. If a name differs,
// edit the shim to point at the real member.

private extension IMUSample {
    /// Optional barometric pressure in hPa. ASSUMPTION: `pressure: Double?`.
    var pressureSafe: Double? { self.pressure }

    /// Optional gravity vector (g) with .x/.y/.z. ASSUMPTION: `gravity`.
    /// If your gravity is non-optional, change `?` accordingly.
    var gravitySafe: (x: Double, y: Double, z: Double)? {
        guard let g = self.gravity else { return nil }
        return (g.x, g.y, g.z)
    }
}

private extension DetectionMode {
    var displayNameSafe: String          { self.displayName }
    var minSpeedSafe: Double             { self.minSpeed }
    var takeoffGSafe: Double             { self.takeoffG }
    var landingGSafe: Double             { self.landingG }
    var minAirtimeSafe: Double           { self.minAirtime }
    var maxAirtimeSafe: Double           { self.maxAirtime }
    var cooldownSafe: Double             { self.cooldown }
    var kinematicCalibrationSafe: Double { self.kinematicCalibration }
}
