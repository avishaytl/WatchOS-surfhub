//
//  AccountView.swift
//  Kiters Watch App
//
//  Email OTP sign-in / account management screen.
//

import SwiftUI

struct AccountView: View {
    @EnvironmentObject var authService: AuthService
    @AppStorage("appLanguage") private var languageCode: String = "en"

    @State private var emailInput = ""
    @State private var codeInput = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                switch authService.state {
                case .signedOut:
                    signedOutView
                case .pendingOTP(let email):
                    pendingOTPView(email: email)
                case .signedIn(let email):
                    signedInView(email: email)
                case .loading:
                    loadingView
                case .error(let message):
                    errorView(message: message)
                }
            }
            .padding()
        }
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
        .navigationBarTitleDisplayMode(.inline)
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

            Button(action: {
                let trimmed = emailInput.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                Task { await authService.sendOTP(email: trimmed) }
            }) {
                Text(L("account.send_code"))
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(emailInput.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.gray.opacity(0.3) : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    private func pendingOTPView(email: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 30))
                .foregroundColor(.green)

            VStack(spacing: 2) {
                Text(L("account.code_sent"))
                    .font(.caption)
                    .foregroundColor(.gray)
                Text(email)
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            TextField(L("account.code_placeholder"), text: $codeInput)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .padding(8)
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)

            Button(action: {
                let trimmed = codeInput.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 6 else { return }
                Task { await authService.verifyOTP(email: email, token: trimmed) }
            }) {
                Text(L("account.verify"))
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(codeInput.trimmingCharacters(in: .whitespaces).count >= 6
                                ? Color.green : Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)

            Button(action: {
                Task { await authService.sendOTP(email: email) }
            }) {
                Text(L("account.resend"))
                    .font(.system(size: 11))
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
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

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(.orange)

            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button(action: {
                authService.resetError()
                emailInput = ""
                codeInput = ""
            }) {
                Text(L("account.try_again"))
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }
}
