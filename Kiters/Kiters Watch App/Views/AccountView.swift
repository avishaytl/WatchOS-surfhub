import SwiftUI

struct AccountView: View {
    @EnvironmentObject var authService: AuthService
    @AppStorage("appLanguage") private var languageCode: String = "en"

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
            WatchPairQRView { uid in
                Task {
                    await authService.completePairing(uid: uid)
                }
            }
        }
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
