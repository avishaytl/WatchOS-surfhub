import Foundation

// Response types
struct StartResponse {
    let sessId: Int
    let spot: String
    let poiKind: String
}

struct RecordResponse {
    let broken: [String]
}

struct EndResponse {
    let broken: [String]
}

enum UploaderError: LocalizedError {
    case notAuthenticated
    case networkError(String)
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:          return "Not signed in — please log in again."
        case .networkError(let msg):     return "Network error: \(msg)"
        case .serverError(let s, let m): return "Server error \(s): \(m)"
        }
    }
}

/// HTTP client for the four watch-ingest lifecycle calls.
/// Every method fetches the current JWT from WatchPairingStore (auto-refreshing
/// if needed) and POSTs to watch-ingest with the correct body shape.
final class WatchSessionUploader {
    static let shared = WatchSessionUploader()

    private let ingestURL = URL(string: "https://vvowvcdylztsqpzifdqc.supabase.co/functions/v1/watch-ingest")!
    private let anonKey   = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2b3d2Y2R5bHp0c3FwemlmZHFjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MTc1NDcsImV4cCI6MjA5MDk5MzU0N30.jPBYr6f9fTABLHAD1rY_b1HP8xI0cDEQPJczxjCKsSY"

    // MARK: - start

    /// Opens a live session. Call once after the first GPS fix.
    /// Returns sessId (keep it for all subsequent calls), spot name, and POI kind.
    func start(lat: Double, lng: Double, startedAt: Date = Date()) async throws -> StartResponse {
        let iso = ISO8601DateFormatter().string(from: startedAt)
        let body: [String: Any] = ["type": "start", "lat": lat, "lng": lng, "startedAt": iso]
        let json = try await post(body)
        guard let sessId = json["sessId"] as? Int else {
            throw UploaderError.networkError("Missing sessId in start response")
        }
        return StartResponse(
            sessId:  sessId,
            spot:    json["spot"]    as? String ?? "",
            poiKind: json["poiKind"] as? String ?? ""
        )
    }

    // MARK: - ping

    /// Position heartbeat — call every ~10 s while riding.
    func ping(sessId: Int, lat: Double, lng: Double, jmax: Double? = nil, jcnt: Int? = nil) async throws {
        var body: [String: Any] = ["type": "ping", "sessId": sessId, "lat": lat, "lng": lng]
        if let jmax { body["jmax"] = jmax }
        if let jcnt { body["jcnt"] = jcnt }
        _ = try await post(body)
    }

    // MARK: - record

    /// Call when a session-best metric improves. Pass only the metric(s) that improved.
    /// The server decides if it also beats the all-time personal best.
    @discardableResult
    func record(sessId: Int, jumpM: Double? = nil, airS: Double? = nil,
                speedKmh: Double? = nil, distKm: Double? = nil) async throws -> RecordResponse {
        var body: [String: Any] = ["type": "record", "sessId": sessId]
        if let jumpM    { body["jumpM"]    = jumpM    }
        if let airS     { body["airS"]     = airS     }
        if let speedKmh { body["speedKmh"] = speedKmh }
        if let distKm   { body["distKm"]   = distKm   }
        let json = try await post(body)
        return RecordResponse(broken: json["broken"] as? [String] ?? [])
    }

    // MARK: - end

    /// Finalises the session. Provide full metrics, compact jData, and track.
    @discardableResult
    func end(sessId: Int,
             durMin: Int, jmax: Double, jcnt: Int, airS: Double,
             spdKmh: Int, distKm: Double,
             windKts: Int? = nil, dir: String? = nil, avgKmh: Double? = nil,
             stars: Int = 3,
             track: [[Int]], jData: [[String: Int]]) async throws -> EndResponse {
        var body: [String: Any] = [
            "type":   "end",
            "sessId": sessId,
            "durMin": durMin,
            "jmax":   jmax,
            "jcnt":   jcnt,
            "airS":   airS,
            "spdKmh": spdKmh,
            "distKm": distKm,
            "stars":  stars,
            "track":  track,
            "jData":  jData,
        ]
        if let windKts { body["windKts"] = windKts }
        if let dir     { body["dir"]     = dir     }
        if let avgKmh  { body["avgKmh"]  = avgKmh  }
        let json = try await post(body)
        return EndResponse(broken: json["broken"] as? [String] ?? [])
    }

    // MARK: - Private

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        guard let pairing = try? await WatchPairingStore.shared.validPairing() else {
            throw UploaderError.notAuthenticated
        }
        var req = URLRequest(url: ingestURL)
        req.httpMethod = "POST"
        req.setValue("application/json",              forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey,                         forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(pairing.accessToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 {
            await WatchPairingStore.shared.clear()
            throw UploaderError.notAuthenticated
        }
        guard (200..<300).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
            throw UploaderError.serverError(status, msg)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
