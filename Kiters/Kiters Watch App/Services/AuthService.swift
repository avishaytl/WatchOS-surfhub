import Foundation

enum AuthState: Equatable {
    case signedOut
    case signedIn(email: String)
    case loading
    case error(message: String)
}

final class AuthService: ObservableObject {
    @Published var state: AuthState = .signedOut

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
            if await WatchPairingStore.shared.isPaired,
               let pairing = try? await WatchPairingStore.shared.validPairing() {
                await set(.signedIn(email: pairing.accountLabel))
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
            await set(.signedIn(email: uid))
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
}
