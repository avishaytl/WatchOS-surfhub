import Foundation
import Security

struct WatchPairing {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval
    let userId: String
    let email: String

    var accountLabel: String {
        email.isEmpty ? L("account.connected_title") : email
    }
}

actor WatchPairingStore {
    static let shared = WatchPairingStore()
    private init() {}

    private static let baseURL: String = {
        Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
            ?? "https://vvowvcdylztsqpzifdqc.supabase.co"
    }()
    private static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2b3d2Y2R5bHp0c3FwemlmZHFjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MTc1NDcsImV4cCI6MjA5MDk5MzU0N30.jPBYr6f9fTABLHAD1rY_b1HP8xI0cDEQPJczxjCKsSY"

    var isPaired: Bool { (try? loadFromKeychain()) != nil }

    func apply(_ pairing: WatchPairing) {
        keychainWrite(pairing.accessToken,        key: "kw.access")
        keychainWrite(pairing.refreshToken,       key: "kw.refresh")
        keychainWrite(String(pairing.expiresAt),  key: "kw.expires")
        keychainWrite(pairing.userId,             key: "kw.uid")
        keychainWrite(pairing.email,              key: "kw.email")
    }

    func validPairing() async throws -> WatchPairing {
        guard let pairing = try? loadFromKeychain() else { throw WatchAuthError.notSignedIn }
        if pairing.expiresAt - Date().timeIntervalSince1970 < 120 {
            return try await doRefresh(pairing.refreshToken)
        }
        return pairing
    }

    func clear() {
        for key in ["kw.access", "kw.refresh", "kw.expires", "kw.uid", "kw.email"] {
            keychainDelete(key)
        }
    }

    // MARK: - Private

    private func loadFromKeychain() throws -> WatchPairing {
        guard
            let access      = keychainRead("kw.access"), !access.isEmpty,
            let refresh     = keychainRead("kw.refresh"),
            let expiresStr  = keychainRead("kw.expires"), let expires = Double(expiresStr),
            let uid         = keychainRead("kw.uid")
        else { throw WatchAuthError.notSignedIn }
        let email = keychainRead("kw.email") ?? ""
        return WatchPairing(accessToken: access, refreshToken: refresh,
                            expiresAt: expires, userId: uid, email: email)
    }

    private func doRefresh(_ refreshToken: String) async throws -> WatchPairing {
        guard let url = URL(string: "\(Self.baseURL)/auth/v1/token?grant_type=refresh_token") else {
            throw WatchAuthError.networkError
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.anonKey,        forHTTPHeaderField: "apikey")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { clear(); throw WatchAuthError.sessionExpired }
        guard (200..<300).contains(code) else { throw WatchAuthError.networkError }
        let pairing = try parseResponse(data)
        apply(pairing)
        return pairing
    }

    private func parseResponse(_ data: Data) throws -> WatchPairing {
        guard
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access  = json["access_token"]  as? String,
            let refresh = json["refresh_token"] as? String,
            let expires = json["expires_at"]    as? TimeInterval,
            let user    = json["user"]           as? [String: Any],
            let uid     = user["id"]             as? String
        else { throw WatchAuthError.networkError }
        let email = (user["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.emailFromJWT(access)
            ?? ""
        return WatchPairing(accessToken: access, refreshToken: refresh,
                            expiresAt: expires, userId: uid, email: email)
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String,
              !email.isEmpty else {
            return nil
        }
        return email
    }

    // MARK: - Keychain helpers

    private func keychainWrite(_ value: String, key: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: key]
        SecItemDelete(query as CFDictionary)
        let attrs: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData:   data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private func keychainRead(_ key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainDelete(_ key: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: key]
        SecItemDelete(query as CFDictionary)
    }
}
