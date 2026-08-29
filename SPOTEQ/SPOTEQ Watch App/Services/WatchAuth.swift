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
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2b3d2Y2R5bHp0c3FwemlmZHFjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MTc1NDcsImV4cCI6MjA5MDk5MzU0N30.jPBYr6f9fTABLHAD1rY_b1HP8xI0cDEQPJczxjCKsSY"

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

    struct PairingRequest {
        let code: String
        let qrPayload: String
        let expiresAt: Date
    }

    enum PairingPoll {
        case pending
        case approved(uid: String, email: String)
        case expired
        case failed(String)
    }

    static func requestPairing(deviceName: String?, deviceModel: String?) async throws -> PairingRequest {
        guard let url = URL(string: "\(baseURL)/functions/v1/watch-link") else {
            throw WatchAuthError.networkError
        }

        var body: [String: Any] = ["action": "request"]
        if let deviceName, !deviceName.isEmpty {
            body["deviceName"] = deviceName
        }
        if let deviceModel, !deviceModel.isEmpty {
            body["deviceModel"] = deviceModel
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String,
              let qrPayload = stringValue(json, "qrPayload", "qr_payload")
        else {
            throw mapError(data: data, status: status)
        }

        let expiresAtString = stringValue(json, "expiresAt", "expires_at")
        let expiresAt = expiresAtString
            .flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? Date().addingTimeInterval(300)
        return PairingRequest(code: code, qrPayload: qrPayload, expiresAt: expiresAt)
    }

    static func pollPairing(code: String) async -> PairingPoll {
        guard let url = URL(string: "\(baseURL)/functions/v1/watch-link") else {
            return .failed(WatchAuthError.networkError.localizedDescription)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "poll", "code": code])

        guard let (data, response) = try? await URLSession.shared.data(for: req) else {
            return .pending
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 410 {
            return .expired
        }
        if !(200..<300).contains(status) {
            return .failed(pairingErrorMessage(data: data, status: status))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .pending
        }

        if (json["status"] as? String) != "approved" {
            return .pending
        }

        guard
            let access = stringValue(json, "accessToken", "access_token"),
            let refresh = stringValue(json, "refreshToken", "refresh_token"),
            let uid = stringValue(json, "uid", "userId", "user_id")
        else {
            return .failed(WatchAuthError.networkError.localizedDescription)
        }

        let expiresAt = unixTimeValue(json, "expiresAt", "expires_at")
            ?? Date().timeIntervalSince1970 + 3600
        let email = resolvedEmail(from: json, accessToken: access)
        let pairing = WatchPairing(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiresAt,
            userId: uid,
            email: email
        )
        await WatchPairingStore.shared.apply(pairing)
        return .approved(uid: uid, email: email)
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

    private static func pairingErrorMessage(data: Data, status: Int) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let message = json["error"] as? String
            ?? json["msg"] as? String
            ?? json["message"] as? String
            ?? json["error_description"] as? String
        return message.map { "[\(status)] \($0)" } ?? "[\(status)] Pairing failed"
    }

    private static func stringValue(_ json: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func resolvedEmail(from json: [String: Any], accessToken: String) -> String {
        if let email = stringValue(json, "email") {
            return email
        }
        if let user = json["user"] as? [String: Any],
           let email = stringValue(user, "email") {
            return email
        }
        return emailFromJWT(accessToken) ?? ""
    }

    private static func emailFromJWT(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - payload.count % 4) % 4
        if padding > 0 {
            payload += String(repeating: "=", count: padding)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return stringValue(json, "email")
    }

    private static func unixTimeValue(_ json: [String: Any], _ keys: String...) -> TimeInterval? {
        for key in keys {
            if let value = json[key] as? TimeInterval {
                return value
            }
            if let value = json[key] as? Int {
                return TimeInterval(value)
            }
            if let value = json[key] as? String, let double = TimeInterval(value) {
                return double
            }
        }
        return nil
    }

    private static func storeAndReturn(_ data: Data) async throws -> String {
        guard
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access  = json["access_token"]  as? String,
            let refresh = json["refresh_token"] as? String,
            let expires = json["expires_at"]    as? TimeInterval,
            let user    = json["user"]           as? [String: Any],
            let uid     = user["id"]             as? String
        else { throw WatchAuthError.networkError }

        let email = user["email"] as? String ?? ""
        let resolvedEmail = email.isEmpty ? (emailFromJWT(access) ?? "") : email
        let pairing = WatchPairing(accessToken: access, refreshToken: refresh,
                                   expiresAt: expires, userId: uid, email: resolvedEmail)
        await WatchPairingStore.shared.apply(pairing)
        return uid
    }
}
