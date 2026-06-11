import SwiftUI

struct AccountView: View {
    @EnvironmentObject var authService: AuthService
    @AppStorage("appLanguage") private var languageCode: String = "en"

    @State private var emailInput    = "sanbata.tv@gmail.com"
    @State private var passwordInput = "123456"
    @State private var alertMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                switch authService.state {
                case .signedOut, .error:
                    signedOutView
                case .signedIn(let email):
                    signedInView(email: email)
                case .loading:
                    loadingView
                }
            }
            .padding()
        }
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: authService.state) { _, newState in
            if case .error(let msg) = newState {
                alertMessage = msg
                authService.resetError()
            }
        }
        .alert(L("common.error_title"), isPresented: .init(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(L("common.ok"), role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Sub-views

    private var signedOutView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.circle")
                .font(.system(size: 34))
                .foregroundColor(.blue)

            Text(L("account.section_title"))
                .font(.headline)

            TextField(L("account.email_placeholder"), text: $emailInput)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .padding(8)
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField(L("account.password_placeholder"), text: $passwordInput)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .padding(8)
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)

            Button(action: {
                let email = emailInput.trimmingCharacters(in: .whitespaces)
                guard !email.isEmpty, !passwordInput.isEmpty else { return }
                Task { await authService.signIn(email: email, password: passwordInput) }
            }) {
                Text(L("account.sign_in"))
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(canSignIn ? Color.blue : Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)

            // OR divider
            HStack(spacing: 6) {
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(.gray.opacity(0.5))
                Text(L("account.or"))
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(.gray.opacity(0.5))
            }

            // Google sign-in
            Button(action: {
                Task { await authService.signInWithGoogle() }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                    Text(L("account.sign_in_google"))
                        .font(.system(size: 11))
                }
                .frame(maxWidth: .infinity)
                .padding(9)
                .background(Color.white.opacity(0.12))
                .foregroundColor(.white)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            Text(L("account.no_account_hint"))
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }

    private var canSignIn: Bool {
        !emailInput.trimmingCharacters(in: .whitespaces).isEmpty && !passwordInput.isEmpty
    }

    private func signedInView(email: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundColor(.green)

            VStack(spacing: 4) {
                Text(L("account.signed_in_as"))
                    .font(.caption)
                    .foregroundColor(.gray)
                Text(email)
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            }

            Button(action: {
                Task { await authService.signOut() }
            }) {
                Text(L("account.sign_out"))
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Color.red.opacity(0.75))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .blue))
            Text(L("account.section_title"))
                .font(.caption)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
