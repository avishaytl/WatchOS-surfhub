import Foundation

enum WatchAuthError: LocalizedError {
    case invalidCredentials
    case emailNotConfirmed
    case notSignedIn
    case sessionExpired
    case networkError
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:      return L("account.error_invalid_credentials")
        case .emailNotConfirmed:       return L("account.error_email_not_confirmed")
        case .notSignedIn:             return "Not signed in"
        case .sessionExpired:          return "Session expired, please sign in again"
        case .networkError:            return "Network error, please try again"
        case .serverMessage(let msg):  return msg
        }
    }
}

enum WatchAuth {
    private static let baseURL: String = {
        Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
            ?? "https://vvowvcdylztsqpzifdqc.supabase.co"
    }()
    private static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2b3d2Y2R5bHp0c3FwemlmZHFjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MTc1NDcsImV4cCI6MjA5MDk5MzU0N30.jPBYr6f9fTABLHAD1rY_b1HP8xI0cDEQPJczxjCKsSY"

    @discardableResult
    static func signInWithEmail(_ email: String, _ password: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/auth/v1/token?grant_type=password") else {
            throw WatchAuthError.networkError
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey,            forHTTPHeaderField: "apikey")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password])

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw mapError(data: data, status: code) }
        return try await storeAndReturn(data)
    }

    @discardableResult
    static func signInWithGoogle(idToken: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/auth/v1/token?grant_type=id_token") else {
            throw WatchAuthError.networkError
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey,            forHTTPHeaderField: "apikey")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["provider": "google", "id_token": idToken])

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw mapError(data: data, status: code) }
        return try await storeAndReturn(data)
    }

    static func signOut() async {
        if let pairing = try? await WatchPairingStore.shared.validPairing(),
           let url = URL(string: "\(baseURL)/auth/v1/logout") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(anonKey,                         forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(pairing.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: req)
        }
        await WatchPairingStore.shared.clear()
    }

    // MARK: - Private

    /// Maps a Supabase error response to the appropriate WatchAuthError,
    /// preserving the actual server message so the user sees what went wrong.
    private static func mapError(data: Data, status: Int) -> WatchAuthError {
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let serverMsg = json["msg"] as? String
                     ?? json["message"] as? String
                     ?? json["error_description"] as? String
        let errorCode = json["error_code"] as? String ?? ""
        let hint      = json["hint"] as? String

        if status == 401 {
            let detail = serverMsg ?? "Invalid API key"
            let full   = hint.map { "\(detail) — \($0)" } ?? detail
            return .serverMessage("[\(status)] \(full)")
        }
        if errorCode == "email_not_confirmed" {
            return .emailNotConfirmed
        }
        if let msg = serverMsg {
            return .serverMessage("[\(status)] \(msg)")
        }
        return .invalidCredentials
    }

    private static func storeAndReturn(_ data: Data) async throws -> String {
        guard
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access  = json["access_token"]  as? String,
            let refresh = json["refresh_token"] as? String,
            let expires = json["expires_at"]    as? TimeInterval,
            let user    = json["user"]           as? [String: Any],
            let uid     = user["id"]             as? String,
            let email   = user["email"]          as? String
        else { throw WatchAuthError.networkError }

        let pairing = WatchPairing(accessToken: access, refreshToken: refresh,
                                   expiresAt: expires, userId: uid, email: email)
        await WatchPairingStore.shared.apply(pairing)
        return uid
    }
}
