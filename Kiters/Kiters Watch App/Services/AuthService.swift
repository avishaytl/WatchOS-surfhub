//
//  AuthService.swift
//  Kiters Watch App
//
//  Supabase email OTP authentication.
//

import Foundation

enum AuthState: Equatable {
    case signedOut
    case pendingOTP(email: String)
    case signedIn(email: String)
    case loading
    case error(message: String)
}

final class AuthService: ObservableObject {
    @Published var state: AuthState = .signedOut

    // The project's Supabase base URL (same project as CloudSyncService).
    private static let baseURL = "https://vvowvcdylztsqpzifdqc.supabase.co"

    // Anon key from Supabase Dashboard → Settings → API → "anon public".
    // Injected via Config.xcconfig → Info.plist at build time.
    private static let anonKey: String = {
        Bundle.main.object(forInfoDictionaryKey: "ISURF_SUPABASE_ANON_KEY") as? String ?? ""
    }()

    private let defaults = UserDefaults.standard

    var isSignedIn: Bool {
        guard case .signedIn = state else { return false }
        return true
    }

    var currentEmail: String {
        guard case .signedIn(let email) = state else { return "" }
        return email
    }

    init() {
        let token = defaults.string(forKey: "authAccessToken") ?? ""
        let email = defaults.string(forKey: "authEmail") ?? ""
        if !token.isEmpty && !email.isEmpty {
            state = .signedIn(email: email)
        }
    }

    func resetError() {
        if case .error = state { state = .signedOut }
    }

    // MARK: - API

    func sendOTP(email: String) async {
        await set(.loading)
        guard let url = URL(string: "\(Self.baseURL)/auth/v1/otp") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "create_user": true])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            await set((200..<300).contains(code) ? .pendingOTP(email: email) : .error(message: "Failed to send code (\(code))"))
        } catch {
            await set(.error(message: error.localizedDescription))
        }
    }

    func verifyOTP(email: String, token: String) async {
        await set(.loading)
        guard let url = URL(string: "\(Self.baseURL)/auth/v1/verify") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        let body: [String: String] = ["type": "email", "email": email, "token": token]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let access = json["access_token"] as? String,
               let refresh = json["refresh_token"] as? String {
                let userEmail: String
                if let userObj = json["user"] as? [String: Any],
                   let e = userObj["email"] as? String { userEmail = e } else { userEmail = email }
                await MainActor.run {
                    defaults.set(access, forKey: "authAccessToken")
                    defaults.set(refresh, forKey: "authRefreshToken")
                    defaults.set(userEmail, forKey: "authEmail")
                    state = .signedIn(email: userEmail)
                }
            } else {
                await set(.error(message: L("account.error_invalid_code")))
            }
        } catch {
            await set(.error(message: error.localizedDescription))
        }
    }

    func signOut() async {
        let token = defaults.string(forKey: "authAccessToken") ?? ""
        if !token.isEmpty, let url = URL(string: "\(Self.baseURL)/auth/v1/logout") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
        await MainActor.run {
            defaults.removeObject(forKey: "authAccessToken")
            defaults.removeObject(forKey: "authRefreshToken")
            defaults.removeObject(forKey: "authEmail")
            state = .signedOut
        }
    }

    @MainActor
    private func set(_ newState: AuthState) {
        state = newState
    }
}
