//
//  SessionLogsView.swift
//  SPOTEQ
//
//  Lists session log files and lets the user share them.
//
//  watchOS limitations:
//    • No Mail/Gmail/WhatsApp apps on the watch.
//    • ShareLink opens Messages — works for text, unreliable for file URLs.
//    • Best path for email/WhatsApp: transfer the file to the paired
//      iPhone via WatchConnectivity, then share from there.
//
//  Two share options:
//    1. "Share via Messages" — sends a short summary + first rows as text
//    2. "Send to iPhone"    — transfers the full log file to the phone
//

import SwiftUI
import WatchKit

// MARK: - Log List View

struct SessionLogsView: View {
    @State private var logFiles: [URL] = []
    @State private var showDeleteConfirm = false
    @State private var isUploadingLogs = false
    @State private var isFetchingCloudResponse = false
    @State private var cloudStatus: String? = nil
    @AppStorage("appLanguage") private var languageCode: String = "en"

    var body: some View {
        ScrollView {
            // A regular VStack eagerly creates every row. Each log row reads a
            // preview from disk, so a watch with many sessions can run out of
            // memory (or be killed by the watchdog) as soon as this screen is
            // opened. Only create rows as they approach the viewport.
            LazyVStack(spacing: 12) {
                Text(L("logs.title"))
                    .font(.headline)

                VStack(spacing: 8) {
                    if CloudSyncService.shared.isAdminConfigured {
                        Button(action: fetchCloudResponse) {
                            HStack {
                                if isFetchingCloudResponse {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "icloud.and.arrow.down.fill")
                                        .font(.system(size: 12))
                                }
                                Text(L("logs.fetch_cloud_response"))
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.cyan.opacity(0.18))
                            .foregroundColor(.cyan)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(isFetchingCloudResponse)
                    }

                    Button(action: uploadAllLogsToCloud) {
                        HStack {
                            if isUploadingLogs {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "icloud.and.arrow.up.fill")
                                    .font(.system(size: 12))
                            }
                            Text(L("logs.upload_cloud"))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.blue.opacity(0.18))
                        .foregroundColor(.blue)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(isUploadingLogs || logFiles.isEmpty)

                    if let cloudStatus {
                        Text(cloudStatus)
                            .font(.system(size: 9))
                            .foregroundColor(cloudStatus.contains("⚠️") ? .orange : .green)
                            .multilineTextAlignment(.center)
                            .lineLimit(6)
                    }
                }

                if logFiles.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 36))
                            .foregroundColor(.gray)
                        Text(L("logs.empty"))
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(L("logs.empty_hint"))
                            .font(.system(size: 10))
                            .foregroundColor(.gray.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 24)
                } else {
                    ForEach(logFiles, id: \.absoluteString) { url in
                        LogFileRow(url: url)
                    }

                    // Delete all logs
                    Button(action: { showDeleteConfirm = true }) {
                        HStack {
                            Image(systemName: "trash.fill")
                            Text(L("logs.delete_all"))
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(Color.red.opacity(0.2))
                        .foregroundColor(.red)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
            }
            .padding()
        }
        // .watchScrollTopShadow()
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
        .onAppear { refreshLogs() }
        .alert(L("logs.delete_confirm"), isPresented: $showDeleteConfirm) {
            Button(L("common.cancel"), role: .cancel) { }
            Button(L("data.delete"), role: .destructive) {
                SessionLogger.shared.clearAllLogs()
                refreshLogs()
            }
        }
    }

    private func refreshLogs() {
        logFiles = SessionLogger.shared.allLogURLs()
    }

    private func uploadAllLogsToCloud() {
        guard !logFiles.isEmpty else { return }
        let filesToUpload = logFiles
        isUploadingLogs = true
        cloudStatus = nil

        Task {
            do {
                let count = try await CloudSyncService.shared.uploadLogs(filesToUpload)
                await MainActor.run {
                    isUploadingLogs = false
                    cloudStatus = String(format: L("logs.upload_cloud_success"), count)
                }
            } catch {
                await MainActor.run {
                    isUploadingLogs = false
                    cloudStatus = String(format: L("logs.cloud_failed"), error.localizedDescription)
                }
            }
        }
    }

    private func fetchCloudResponse() {
        isFetchingCloudResponse = true
        cloudStatus = nil

        Task {
            do {
                let response = try await CloudSyncService.shared.fetchCloudLogResponse()
                await MainActor.run {
                    isFetchingCloudResponse = false
                    cloudStatus = String(
                        format: L("logs.fetch_cloud_response_success"),
                        Self.watchSized(response)
                    )
                }
            } catch {
                await MainActor.run {
                    isFetchingCloudResponse = false
                    cloudStatus = String(format: L("logs.cloud_failed"), error.localizedDescription)
                }
            }
        }
    }

    private static func watchSized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 240 else { return trimmed }
        return "\(trimmed.prefix(240))..."
    }
}

// MARK: - Single Log File Row

struct LogFileRow: View {
    let url: URL
    @State private var fileSize: String = ""
    @State private var rowCount: Int = 0

    // ── Sharing ──
    @State private var isSending = false
    @State private var sendResult: String? = nil
    @State private var shareText: String = ""

    // MARK: Display name

    private var displayName: String {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.replacingOccurrences(of: "log_", with: "").split(separator: "_")
        guard parts.count >= 2 else { return name }
        let datePart = String(parts[0])
        let timePart = String(parts[1])
        guard datePart.count == 8, timePart.count == 6 else { return name }

        let month = String(datePart.dropFirst(4).prefix(2))
        let day   = String(datePart.suffix(2))
        let hour  = String(timePart.prefix(2))
        let min   = String(timePart.dropFirst(2).prefix(2))

        let monthNames = ["01":"Jan","02":"Feb","03":"Mar","04":"Apr","05":"May","06":"Jun",
                          "07":"Jul","08":"Aug","09":"Sep","10":"Oct","11":"Nov","12":"Dec"]
        let m = monthNames[month] ?? month
        return "\(m) \(day) \(hour):\(min)"
    }

    private var isReplayCompatible: Bool {
        url.pathExtension.lowercased() == "kslog"
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ── File info ──
            HStack {
                Image(systemName: "doc.text")
                    .foregroundColor(.cyan)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(fileSize)
                            .font(.system(size: 9))
                            .foregroundColor(.gray)
                        if rowCount > 0 {
                            Text("~\(rowCount) rows")
                                .font(.system(size: 9))
                                .foregroundColor(.gray)
                        }
                    }
                }
                Spacer()
            }

            // Run this exact local capture through the production detector
            // adapters. The lab reads the file directly from the watch and
            // never uploads it or starts the live sensor pipeline.
            if isReplayCompatible {
                NavigationLink(destination: ReplayLabView(initialLogURL: url, autoStart: true)) {
                    HStack {
                        Image(systemName: "waveform.path.ecg.rectangle.fill")
                            .font(.system(size: 12))
                        Text(L("logs.run_in_lab"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            } else {
                Text(L("logs.replay_legacy_unavailable"))
                    .font(.system(size: 8))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ── Option 1: Share via Messages (text content) ──
            // ShareLink with String is reliable on watchOS.
            // We send a summary + as much decoded text as Messages can handle.
            if !shareText.isEmpty {
                ShareLink(
                    item: shareText,
                    subject: Text("🏄 SPOTEQ Log — \(url.lastPathComponent)")
                ) {
                    HStack {
                        Image(systemName: "message.fill")
                            .font(.system(size: 12))
                        Text(L("logs.share_messages"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            // ── Option 2: Send full log to iPhone ──
            // The iPhone can then share via Email, WhatsApp, AirDrop, etc.
            Button(action: { sendToPhone() }) {
                HStack {
                    if isSending {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "iphone.and.arrow.forward")
                            .font(.system(size: 12))
                    }
                    Text(L("logs.send_to_phone"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.2))
                .foregroundColor(.blue)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(isSending)

            if let result = sendResult {
                Text(result)
                    .font(.system(size: 9))
                    .foregroundColor(result.contains("✅") ? .green : .orange)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.cyan.opacity(0.2), lineWidth: 1)
        )
        .onAppear { loadInfo() }
    }

    // MARK: - Helpers

    /// Load file size, estimate row count, and prepare share text without doing
    /// file parsing on the watch's main thread.
    private func loadInfo() {
        DispatchQueue.global(qos: .utility).async {
            var size = "?"
            var rows = 0
            if let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
               let b = attr[.size] as? Int64 {
                if b < 1024 {
                    size = "\(b) B"
                } else if b < 1_048_576 {
                    size = "\(b / 1024) KB"
                } else {
                    size = String(format: "%.1f MB", Double(b) / 1_048_576)
                }
                rows = SessionLogger.shared.estimatedRowCount(for: url, fileSizeBytes: b)
            }

            let preview = SessionLogger.shared.buildShareText(
                for: url,
                fileSize: size,
                maxChars: 12_000
            )

            DispatchQueue.main.async {
                self.fileSize = size
                self.rowCount = rows
                self.shareText = preview
            }
        }
    }

    /// Transfer the full log to the paired iPhone via WatchConnectivity.
    /// From the iPhone the user can share via Mail, WhatsApp, Gmail, AirDrop, etc.
    private func sendToPhone() {
        isSending = true
        sendResult = nil

        WatchConnectivityManager.shared.transferFile(url, metadata: [
            "type": "session_log",
            "filename": url.lastPathComponent
        ]) { success, error in
            DispatchQueue.main.async {
                isSending = false
                sendResult = success
                    ? "✅ Sent! Open SPOTEQ on iPhone to share via Email/WhatsApp"
                    : "⚠️ Failed — is iPhone nearby?"
            }
        }
    }
}

#Preview {
    SessionLogsView()
}
