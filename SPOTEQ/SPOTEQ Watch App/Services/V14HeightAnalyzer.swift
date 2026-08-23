//
//  V14HeightAnalyzer.swift
//  SPOTEQ Watch App
//
//  Pure measurement-quality layer for V14. Takes data the engine's IMU state
//  machine already collected (baseline diagnostics, in-flight relative
//  samples) and produces quality/confidence metadata. Never decides whether
//  a jump happened — JumpEngineV14's state machine (takeoff/airborne/
//  landingConfirm) is the sole source of truth for that. See
//  SPOTEQ/docs/V14_RELATIVE_HEIGHT_UPGRADE_PLAN.md for the design rationale.
//
//  No Apple altitude APIs here — this operates purely on (t, value) samples
//  the adapter already extracted, so it stays platform-free and testable
//  offline via JumpReplay.
//

import Foundation

/// Pre-takeoff baseline quality, computed from the same window
/// `JumpEngineV14.medianBaseline` reads. Diagnostic only — an unstable
/// baseline degrades `heightConfidence`, it never deletes the jump.
public struct V14BaselineQuality {
    public let sampleCount: Int
    public let varianceM: Double
    public let maxGapSec: Double
    public let isStable: Bool
    /// 0...1, blends variance and sample coverage.
    public let quality: Double
}

/// Apex quality inside the confirmed flight window.
public struct V14ApexQuality {
    public let timestamp: TimeInterval?
    public let altitudeM: Double?
    /// 0...1 — persistence of the peak plus distance from the flight edges.
    public let confidence: Double
    public let sampleCount: Int
}

public enum V14HeightAnalyzer {
    /// `medianBaseline` already gates candidate-open on `minBaselineSamples`;
    /// this only adds quality metadata on top of a baseline that may or may
    /// not exist.
    public static func baselineQuality(sampleCount: Int,
                                       varianceM: Double,
                                       maxGapSec: Double,
                                       minSamples: Int,
                                       stabilityVarianceM: Double,
                                       maxAllowedGapSec: Double) -> V14BaselineQuality {
        guard sampleCount > 0 else {
            return V14BaselineQuality(sampleCount: 0, varianceM: 0, maxGapSec: 0,
                                      isStable: false, quality: 0)
        }
        let isStable = sampleCount >= minSamples
            && varianceM <= stabilityVarianceM
            && maxGapSec <= maxAllowedGapSec
        let varianceScore = stabilityVarianceM > 0
            ? max(0, 1 - varianceM / stabilityVarianceM)
            : (varianceM <= 0 ? 1 : 0)
        let coverageScore = min(1, Double(sampleCount) / Double(max(minSamples, 1)))
        let gapScore = maxAllowedGapSec > 0
            ? max(0, 1 - maxGapSec / maxAllowedGapSec)
            : (maxGapSec <= 0 ? 1 : 0)
        let quality = min(max((varianceScore + coverageScore + gapScore) / 3, 0), 1)
        return V14BaselineQuality(sampleCount: sampleCount, varianceM: varianceM,
                                  maxGapSec: maxGapSec, isStable: isStable, quality: quality)
    }

    /// `samples` is the full-resolution relative-altitude trail during the
    /// flight (`Flight.relFlightSamples`), not just the tracked maximum —
    /// persistence needs neighbours around the peak.
    public static func apexQuality(samples: [(t: TimeInterval, v: Double)],
                                   flightStart: TimeInterval,
                                   flightEnd: TimeInterval,
                                   persistenceToleranceM: Double = 0.3) -> V14ApexQuality {
        guard !samples.isEmpty else {
            return V14ApexQuality(timestamp: nil, altitudeM: nil, confidence: 0, sampleCount: 0)
        }
        let peak = samples.max { $0.v < $1.v }!
        let flightSpan = max(flightEnd - flightStart, 0.001)
        let edgeDistance = min(peak.t - flightStart, flightEnd - peak.t) / (flightSpan / 2)
        let edgeScore = min(max(edgeDistance, 0), 1)

        let nearby = samples.filter { abs($0.v - peak.v) <= persistenceToleranceM }
        let persistenceScore = Double(nearby.count) / Double(samples.count)

        let coverageScore = min(1, Double(samples.count) / 5.0)

        let confidence = min(max(0.3 * edgeScore + 0.4 * persistenceScore + 0.3 * coverageScore, 0), 1)
        return V14ApexQuality(timestamp: peak.t, altitudeM: peak.v,
                              confidence: confidence, sampleCount: samples.count)
    }

    /// Combines baseline + apex + source rank into a single 0...1
    /// height-measurement confidence, independent of `detectionConfidence`.
    public static func heightConfidence(source: V14HeightSource,
                                        baseline: V14BaselineQuality,
                                        apex: V14ApexQuality) -> Double {
        switch source {
        case .unavailable:
            return 0
        case .ballistic:
            // Timing-only — no pressure channel measured a rise.
            return 0.2
        case .relativeAltitude:
            return min(max(0.5 * baseline.quality + 0.5 * apex.confidence, 0), 1)
        case .absoluteAltitude:
            // Absolute is diagnostic-first-choice fallback only when
            // relative failed — cap below relative's own achievable ceiling.
            return min(max(0.4 * baseline.quality + 0.3 * apex.confidence + 0.1, 0), 0.75)
        case .imuIntegrated:
            // A real measured profile (not timing-only like ballistic), but
            // model-based and only attempted on an already-calm flight — no
            // baseline/apex quality signal of its own to blend in, so this is
            // a fixed band: above ballistic, below either pressure channel.
            return 0.35
        }
    }

    /// Double integration of the flight's raw vertical-load samples,
    /// boundary-corrected so the profile returns to zero at the last sample
    /// (the flight's own touchdown edge) — see JumpEngineV14's
    /// `imuIntegrationMaxGyroRadS` gate for why the caller only invokes this
    /// on a calm (non-rotating) flight: fast wrist rotation makes the fused
    /// gravity vector lag, corrupting the vertical-load signal integrated
    /// here.
    ///
    /// `accelSamples` must be time-ordered net vertical acceleration in m/s²
    /// (positive = upward), spanning takeoff to touchdown. Trapezoidal
    /// integration twice (accel → velocity → height), assuming v=0 and h=0
    /// at the first sample; the unknown initial vertical velocity is solved
    /// from the single available boundary condition — the rider returns to
    /// the water at touchdown, so corrected height at the last sample must
    /// be ~0. Returns the max of the corrected height profile (the apex), or
    /// nil if there aren't enough samples to integrate meaningfully.
    public static func imuIntegratedApexHeightM(
        accelSamples: [(t: TimeInterval, aUpMS2: Double)],
        minSamples: Int
    ) -> Double? {
        guard accelSamples.count >= minSamples else { return nil }
        let t0 = accelSamples[0].t
        guard accelSamples.last!.t > t0 else { return nil }

        var velocity = 0.0
        var height = 0.0
        var heightProfile: [(t: TimeInterval, h: Double)] = [(t0, 0.0)]
        for i in 1..<accelSamples.count {
            let dt = accelSamples[i].t - accelSamples[i - 1].t
            guard dt > 0, dt < 1.0 else { continue }
            let aAvg = (accelSamples[i].aUpMS2 + accelSamples[i - 1].aUpMS2) / 2.0
            let newVelocity = velocity + aAvg * dt
            height += (velocity + newVelocity) / 2.0 * dt
            velocity = newVelocity
            heightProfile.append((accelSamples[i].t, height))
        }

        guard let last = heightProfile.last, last.t > t0 else { return nil }
        let totalT = last.t - t0
        let v0 = -last.h / totalT
        let apexH = heightProfile.map { $0.h + v0 * ($0.t - t0) }.max()
        guard let apexH, apexH.isFinite else { return nil }
        return apexH
    }
}
