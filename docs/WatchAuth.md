//
//  WatchAuth.swift
//  SurfHubWatch
//
//  The watch's OWN authentication — a LOGIN-ONLY flow (no sign-up; accounts are
//  created in the phone app). The rider signs in here with the same Email or
//  Google account; the watch gets its own Supabase session for the same UID and
//  stores it via WatchPairingStore. After this, WatchSessionUploader works.
//
//  This talks DIRECTLY to Supabase GoTrue (the auth REST API) — no supabase-swift
//  SDK dependency required, though you may swap in supabase-swift if preferred.
//  Endpoints (base = SUPABASE_URL):
//
//    Email/password:
//      POST {base}/auth/v1/token?grant_type=password
//      apikey: {anonKey}
//      { "email": "...", "password": "..." }
//      → { access_token, refresh_token, expires_at, user: { id } }
//
//    Google (ID-token, same as the phone's signInWithIdToken):
//      POST {base}/auth/v1/token?grant_type=id_token
//      apikey: {anonKey}
//      { "provider": "google", "id_token": "<google id token>" }
//      → same shape
//
//  Config (Info.plist, injected per build — NEVER hardcode the anon key in git):
//      SUPABASE_URL        e.g. https://vvowvcdylztsqpzifdqc.supabase.co
//      SUPABASE_ANON_KEY   the public anon key (safe to ship in the binary)
//      GOOGLE_IOS_CLIENT_ID  for the Google Sign-In SDK on watchOS (if used)
//
//  See surfhub-watch/WATCH_AUTH.md for the complete spec + Google setup.
//

import Foundation

// MARK: - Config

struct WatchAuthConfig {
    let supabaseUrl: URL
    let anonKey: String

    static func fromBundle(_ bundle: Bundle = .main) -> WatchAuthConfig? {
        guard
            let urlString = bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let url = URL(string: urlString),
            let anon = bundle.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            !anon.isEmpty
        else { return nil }
        return WatchAuthConfig(supabaseUrl: url, anonKey: anon)
    }

    var ingestUrl: URL { supabaseUrl.appendingPathComponent("functions/v1/watch-ingest") }
}

// MARK: - Errors

enum WatchAuthError: Error, LocalizedError {
    case notConfigured
    case invalidCredentials
    case server(status: Int, message: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:       return "Auth is not configured (missing SUPABASE_URL / SUPABASE_ANON_KEY)."
        case .invalidCredentials:  return "Wrong email or password."
        case .server(let s, let m): return "Sign-in error \(s): \(m)"
        case .badResponse:         return "The server returned an unexpected response."
        }
    }
}

// MARK: - Auth

enum WatchAuth {

    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_at: TimeInterval?
        let expires_in: Double?
        let error_description: String?
        let msg: String?
        struct User: Decodable { let id: String? }
        let user: User?
    }

    /// Sign in with email + password. On success the session is stored and the
    /// function returns the rider's UID.
    @discardableResult
    static func signInWithEmail(_ email: String, _ password: String) async throws -> String {
        guard let cfg = WatchAuthConfig.fromBundle() else { throw WatchAuthError.notConfigured }
        let body: [String: Any] = [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            "password": password,
        ]
        return try await exchange(cfg: cfg, grant: "password", body: body)
    }

    /// Sign in with a Google ID token obtained from the Google Sign-In SDK on
    /// the watch (or a paired-phone-assisted Google flow). Mirrors the phone's
    /// supabase.auth.signInWithIdToken({ provider:'google', token }).
    @discardableResult
    static func signInWithGoogle(idToken: String) async throws -> String {
        guard let cfg = WatchAuthConfig.fromBundle() else { throw WatchAuthError.notConfigured }
        let body: [String: Any] = ["provider": "google", "id_token": idToken]
        return try await exchange(cfg: cfg, grant: "id_token", body: body)
    }

    // MARK: QR pairing (§2.6) — the WATCH displays a QR, the PHONE scans it.

    /// The pairing code + QR payload the watch shows on screen.
    struct PairingRequest {
        let code: String
        let qrPayload: String     // render this as a QR (e.g. surfhub://watch-pair?code=…)
        let expiresAt: Date
    }

    /// Result of one poll while waiting for the phone to approve.
    enum PairingPoll {
        case pending                 // keep polling
        case approved(uid: String)   // session stored; stop polling
        case expired                 // code gone — show a fresh QR
        case error(String)           // phone session died — re-approve on phone
    }

    /// (1) Ask the server for a one-time pairing code and QR payload to DISPLAY.
    /// No Authorization header — the watch has no session yet. Pass device
    /// name/model so the phone can show "Connect <model>?".
    static func requestPairing(deviceName: String?, deviceModel: String?) async throws -> PairingRequest {
        guard let cfg = WatchAuthConfig.fromBundle() else { throw WatchAuthError.notConfigured }

        var req = URLRequest(url: cfg.supabaseUrl.appendingPathComponent("functions/v1/watch-link"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cfg.anonKey, forHTTPHeaderField: "apikey")   // NO Authorization header
        var body: [String: Any] = ["action": "request"]
        if let deviceName  { body["deviceName"]  = deviceName }
        if let deviceModel { body["deviceModel"] = deviceModel }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        struct R: Decodable { let code: String?; let qrPayload: String?; let expiresAt: String? }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let d = try? JSONDecoder().decode(R.self, from: data)
        guard status == 200, let code = d?.code, let qr = d?.qrPayload else {
            throw WatchAuthError.server(status: status, message: "could not start pairing")
        }
        let exp = d?.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? Date().addingTimeInterval(300)
        return PairingRequest(code: code, qrPayload: qr, expiresAt: exp)
    }

    /// (2) Poll once. On `.approved` the session is already stored (call
    /// WatchPairingStore.shared.validPairing() / proceed to recording). Drive this
    /// from a ~2 s timer in the pairing screen until approved or expired.
    static func pollPairing(code: String) async -> PairingPoll {
        guard let cfg = WatchAuthConfig.fromBundle() else { return .error("not configured") }

        var req = URLRequest(url: cfg.supabaseUrl.appendingPathComponent("functions/v1/watch-link"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cfg.anonKey, forHTTPHeaderField: "apikey")   // NO Authorization header
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "poll", "code": code])

        struct R: Decodable {
            let status: String?
            let accessToken: String?; let refreshToken: String?; let expiresAt: TimeInterval?
            let uid: String?; let ingestUrl: String?; let supabaseUrl: String?; let anonKey: String?
            let error: String?
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return .pending }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let d = try? JSONDecoder().decode(R.self, from: data)

        if status == 404 || status == 410 { return .expired }
        if status == 401 { return .error(d?.error ?? "re-approve on the phone") }
        if d?.status == "approved",
           let access = d?.accessToken, let refresh = d?.refreshToken, let uid = d?.uid {
            let session = WatchPairing(
                accessToken: access,
                refreshToken: refresh,
                expiresAt: d?.expiresAt ?? (Date().timeIntervalSince1970 + 3600),
                ingestUrl: d?.ingestUrl.flatMap(URL.init(string:)) ?? cfg.ingestUrl,
                uid: uid,
                supabaseUrl: d?.supabaseUrl.flatMap(URL.init(string:)) ?? cfg.supabaseUrl,
                anonKey: d?.anonKey ?? cfg.anonKey
            )
            await WatchPairingStore.shared.apply(session)
            return .approved(uid: uid)
        }
        return .pending
    }

    /// Sign the rider out: revoke the session server-side (best effort) and clear
    /// the local store so the UI returns to the login screen.
    static func signOut() async {
        if let pairing = await WatchPairingStore.shared.validPairing(),
           let cfg = WatchAuthConfig.fromBundle() {
            var req = URLRequest(url: cfg.supabaseUrl.appendingPathComponent("auth/v1/logout"))
            req.httpMethod = "POST"
            req.setValue(cfg.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(pairing.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: req)
        }
        await WatchPairingStore.shared.clear()
    }

    // MARK: Internal

    private static func exchange(cfg: WatchAuthConfig, grant: String, body: [String: Any]) async throws -> String {
        var comps = URLComponents(url: cfg.supabaseUrl.appendingPathComponent("auth/v1/token"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: grant)]

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cfg.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(cfg.anonKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)

        if status == 400 || status == 401 {
            throw WatchAuthError.invalidCredentials
        }
        guard status == 200,
              let access = decoded?.access_token,
              let refresh = decoded?.refresh_token,
              let uid = decoded?.user?.id
        else {
            throw WatchAuthError.server(status: status,
                                        message: decoded?.error_description ?? decoded?.msg ?? "sign-in failed")
        }

        let expiresAt = decoded?.expires_at
            ?? (Date().timeIntervalSince1970 + (decoded?.expires_in ?? 3600))

        let session = WatchPairing(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiresAt,
            ingestUrl: cfg.ingestUrl,
            uid: uid,
            supabaseUrl: cfg.supabaseUrl,
            anonKey: cfg.anonKey
        )
        await WatchPairingStore.shared.apply(session)
        return uid
    }
}
