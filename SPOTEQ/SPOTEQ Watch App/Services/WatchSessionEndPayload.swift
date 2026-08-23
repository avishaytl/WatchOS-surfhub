import Foundation

/// The complete watch-ingest lifecycle payload for `type=end`.
///
/// Keeping construction in a Foundation-only value makes the wire contract
/// directly testable without HealthKit or network access. The diagnostic
/// calib-log/.kslog upload uses a different path and is intentionally untouched.
public struct WatchSessionEndPayload {
    public let sessId: Int
    public let durMin: Int
    public let jmax: Double
    public let jcnt: Int
    public let airS: Double
    public let spdKmh: Int
    public let distKm: Double
    public let windKts: Int?
    public let dir: String?
    public let avgKmh: Double?
    public let stars: Int
    public let calories: Int?
    public let maxHr: Int?
    public let track: [[Int]]
    public let jData: [[String: Int]]

    public init(
        sessId: Int,
        durMin: Int,
        jmax: Double,
        jcnt: Int,
        airS: Double,
        spdKmh: Int,
        distKm: Double,
        windKts: Int? = nil,
        dir: String? = nil,
        avgKmh: Double? = nil,
        stars: Int = 3,
        calories: Int? = nil,
        maxHr: Int? = nil,
        track: [[Int]],
        jData: [[String: Int]]
    ) {
        self.sessId = sessId
        self.durMin = durMin
        self.jmax = jmax
        self.jcnt = jcnt
        self.airS = airS
        self.spdKmh = spdKmh
        self.distKm = distKm
        self.windKts = windKts
        self.dir = dir
        self.avgKmh = avgKmh
        self.stars = stars
        self.calories = calories
        self.maxHr = maxHr
        self.track = track
        self.jData = jData
    }

    /// JSON-shaped object encoded by the existing KLOG lifecycle envelope.
    /// Health fields are omitted unless they contain a real positive integer.
    public func object() -> [String: Any] {
        var body: [String: Any] = [
            "type": "end",
            "sessId": sessId,
            "durMin": durMin,
            "jmax": jmax,
            "jcnt": jcnt,
            "airS": airS,
            "spdKmh": spdKmh,
            "distKm": distKm,
            "stars": stars,
            "track": track,
            "jData": jData,
        ]
        if let windKts { body["windKts"] = windKts }
        if let dir { body["dir"] = dir }
        if let avgKmh { body["avgKmh"] = avgKmh }
        if let calories, calories > 0 { body["calories"] = calories }
        if let maxHr, maxHr > 0 { body["maxHr"] = maxHr }
        return body
    }

    public func encodedKLOG() -> Data {
        BinaryLogEnvelope.encode(object: object())
    }
}
