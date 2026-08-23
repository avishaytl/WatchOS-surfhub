import Foundation

enum AuthState: Equatable {
    case signedOut
    case signedIn(email: String)
    case loading
    case error(message: String)
}

/// One-shot banner shown at app launch to confirm the watch reconnected
/// (or to flag that the stored pairing expired). Cleared once dismissed.
struct AuthLaunchNotice: Identifiable {
    let id = UUID()
    let titleKey: String
    let messageKey: String
    /// Optional `%@` argument for the message (e.g. the account label).
    let messageArg: String?
}

final class AuthService: ObservableObject {
    @Published var state: AuthState = .signedOut
    @Published var launchNotice: AuthLaunchNotice?

    var isSignedIn: Bool {
        guard case .signedIn = state else { return false }
        return true
    }

    var currentEmail: String {
        guard case .signedIn(let email) = state else { return "" }
        return email
    }

    init() {
        Task {
            // Only surface a launch notice when a pairing was previously stored,
            // so fresh installs stay silent and just see the connect screen.
            guard await WatchPairingStore.shared.isPaired else { return }
            if let pairing = try? await WatchPairingStore.shared.validPairing() {
                await set(.signedIn(email: pairing.accountLabel))
                await setLaunchNotice(AuthLaunchNotice(
                    titleKey: "account.connected_title",
                    messageKey: "account.connected_message",
                    messageArg: pairing.accountLabel
                ))
            } else {
                await setLaunchNotice(AuthLaunchNotice(
                    titleKey: "account.connect_failed_title",
                    messageKey: "account.connect_failed_message",
                    messageArg: nil
                ))
            }
        }
    }

    func signIn(email: String, password: String) async {
        await set(.loading)
        do {
            _ = try await WatchAuth.signInWithEmail(email, password)
            if let pairing = try? await WatchPairingStore.shared.validPairing() {
                await set(.signedIn(email: pairing.accountLabel))
            }
        } catch WatchAuthError.invalidCredentials {
            await set(.error(message: L("account.error_invalid_credentials")))
        } catch {
            await set(.error(message: error.localizedDescription))
        }
    }

    func signInWithGoogle() async {
        await set(.loading)
        do {
            let idToken = try await GoogleSignInService.shared.signIn()
            _ = try await WatchAuth.signInWithGoogle(idToken: idToken)
            if let pairing = try? await WatchPairingStore.shared.validPairing() {
                await set(.signedIn(email: pairing.accountLabel))
            }
        } catch GoogleSignInError.cancelled {
            await set(.signedOut)
        } catch {
            await set(.error(message: error.localizedDescription))
        }
    }

    func completePairing(uid: String) async {
        if let pairing = try? await WatchPairingStore.shared.validPairing() {
            await set(.signedIn(email: pairing.accountLabel))
        } else {
            await set(.signedIn(email: L("account.connected_title")))
        }
    }

    func signOut() async {
        await WatchAuth.signOut()
        await set(.signedOut)
    }

    func resetError() {
        if case .error = state { state = .signedOut }
    }

    @MainActor
    private func set(_ newState: AuthState) {
        state = newState
    }

    @MainActor
    private func setLaunchNotice(_ notice: AuthLaunchNotice) {
        launchNotice = notice
    }
}
