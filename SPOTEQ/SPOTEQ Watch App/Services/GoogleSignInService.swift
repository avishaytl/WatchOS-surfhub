import AuthenticationServices
import CryptoKit
import Foundation

enum GoogleSignInError: LocalizedError {
    case cancelled
    case configuration
    case invalidResponse
    case exchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:               return nil
        case .configuration:           return L("account.error_configuration")
        case .invalidResponse:         return L("account.error_google_failed")
        case .exchangeFailed(let msg): return msg
        }
    }
}

/// Runs Google OAuth2 Authorization-Code + PKCE flow on watchOS.
/// ASWebAuthenticationSession on watchOS opens the login page on the
/// paired iPhone automatically — no on-watch web view is needed.
@MainActor
final class GoogleSignInService {
    static let shared = GoogleSignInService()

    private struct Configuration {
        let clientID: String
        let callbackScheme: String

        static func load(from bundle: Bundle = .main) throws -> Configuration {
            func requiredValue(_ key: String) throws -> String {
                guard
                    let rawValue = bundle.object(forInfoDictionaryKey: key) as? String,
                    !rawValue.isEmpty,
                    !rawValue.contains("$("),
                    !rawValue.contains("YOUR_SPOTEQ_"),
                    !rawValue.contains("unconfigured")
                else {
                    throw GoogleSignInError.configuration
                }
                return rawValue
            }

            let clientID = try requiredValue("SPOTEQ_GOOGLE_CLIENT_ID")
            let callbackScheme = try requiredValue("SPOTEQ_GOOGLE_CALLBACK_SCHEME")
            guard callbackScheme.range(
                of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#,
                options: .regularExpression
            ) != nil else {
                throw GoogleSignInError.configuration
            }
            return Configuration(clientID: clientID, callbackScheme: callbackScheme)
        }
    }

    // Returns a Google id_token suitable for WatchAuth.signInWithGoogle(idToken:).
    func signIn() async throws -> String {
        let configuration = try Configuration.load()
        let verifier  = randomBase64URL(32)
        let challenge = sha256Base64URL(verifier)
        let nonce     = randomBase64URL(16)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id",             value: configuration.clientID),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: "openid email profile"),
            URLQueryItem(name: "redirect_uri",          value: "\(configuration.callbackScheme):/oauth2redirect"),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "nonce",                 value: nonce),
        ]
        guard let authURL = comps.url else { throw GoogleSignInError.invalidResponse }

        let code = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: configuration.callbackScheme
            ) { url, error in
                if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(throwing: GoogleSignInError.cancelled)
                    return
                }
                guard
                    let url,
                    let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    cont.resume(throwing: GoogleSignInError.invalidResponse)
                    return
                }
                cont.resume(returning: code)
            }
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }

        return try await exchangeCode(code, verifier: verifier, configuration: configuration)
    }

    // MARK: - Token exchange

    private func exchangeCode(
        _ code: String,
        verifier: String,
        configuration: Configuration
    ) async throws -> String {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw GoogleSignInError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = [
            "code=\(code.percentEncoded)",
            "client_id=\(configuration.clientID)",
            "redirect_uri=\(configuration.callbackScheme):/oauth2redirect",
            "grant_type=authorization_code",
            "code_verifier=\(verifier)",
        ].joined(separator: "&").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["id_token"] as? String
        else {
            let errMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
            throw GoogleSignInError.exchangeFailed(errMsg ?? L("account.error_google_failed"))
        }
        return idToken
    }

    // MARK: - PKCE helpers

    private func randomBase64URL(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func sha256Base64URL(_ input: String) -> String {
        Data(SHA256.hash(data: Data(input.utf8))).base64URLEncoded()
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var percentEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
