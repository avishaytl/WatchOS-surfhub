import Foundation

enum FormatDetector {
    /// Decide CoreMotion vs Android based on gravity-vector magnitude.
    /// - CoreMotion stores gravity in m/s² (|g| ≈ 9.8)
    /// - Android (and the realistic logs) store gravity in g-units (|g| ≈ 1)
    static func detect(_ rows: [RawRow]) -> SensorFormat {
        let sample = rows.prefix(200)
        guard !sample.isEmpty else { return .coreMotion }
        var sumMag = 0.0
        for r in sample {
            let m = sqrt(r.gravX*r.gravX + r.gravY*r.gravY + r.gravZ*r.gravZ)
            sumMag += m
        }
        let mean = sumMag / Double(sample.count)
        // Bisect at 3.0 — well separated from both 1.0 and 9.8
        return mean < 3.0 ? .android : .coreMotion
    }
}
