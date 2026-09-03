//
//  SessionLogsView.swift
//  SPOTEQ
//
//  Lists session log files and uploads them to the cloud.
//
//  Cloud is the only export path. Messages/iPhone sharing was removed: on
//  watchOS ShareLink can only carry a truncated text preview, and the
//  WatchConnectivity hand-off needed the phone nearby and then a second manual
//  share from there. Uploading straight to the cloud server delivers the whole
//  binary log every time, phone or no phone.
//
//  Three upload paths:
//    1. "Upload All"      — every log on the watch
//    2. per-row button    — one session
//    3. "Upload Selected" — a chosen subset (tap Select to enter selection mode)
//

import SwiftUI
import WatchKit

// MARK: - Log List View

struct SessionLogsView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var logFiles: [URL] = []
    @State private var showDeleteConfirm = false
    @State private var isUploadingLogs = false
    @State private var isFetchingCloudResponse = false
    @State private var cloudStatus: String? = nil

    // ── Selection mode ──
    // Selection is keyed by absoluteString rather than URL: refreshLogs()
    // rebuilds the URLs, and a path-identical URL is not guaranteed to hash
    // equal once the file coordinator has normalised it.
    @State private var isSelecting = false
    @State private var selectedLogs: Set<String> = []

    @AppStorage("appLanguage") private var languageCode: String = "en"

    private var selectedURLs: [URL] {
        logFiles.filter { selectedLogs.contains($0.absoluteString) }
    }

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

                    if isSelecting {
                        Button(action: uploadSelectedLogsToCloud) {
                            HStack {
                                if isUploadingLogs {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "icloud.and.arrow.up.fill")
                                        .font(.system(size: 12))
                                }
                                Text(String(format: L("logs.upload_selected"), selectedLogs.count))
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.blue.opacity(0.18))
                            .foregroundColor(.blue)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(isUploadingLogs || selectedLogs.isEmpty)

                        HStack(spacing: 8) {
                            Button(action: toggleSelectAll) {
                                Text(selectedLogs.count == logFiles.count
                                     ? L("logs.deselect_all")
                                     : L("logs.select_all"))
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(Color.white.opacity(0.08))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)

                            Button(action: exitSelectionMode) {
                                Text(L("common.cancel"))
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(Color.white.opacity(0.08))
                                    .foregroundColor(.gray)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                        .disabled(isUploadingLogs)
                    } else {
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

                        if logFiles.count > 1 {
                            Button(action: enterSelectionMode) {
                                HStack {
                                    Image(systemName: "checklist")
                                        .font(.system(size: 12))
                                    Text(L("logs.select"))
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.08))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .disabled(isUploadingLogs)
                        }
                    }

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
                        LogFileRow(
                            url: url,
                            isSelecting: isSelecting,
                            isSelected: selectedLogs.contains(url.absoluteString),
                            onToggleSelection: { toggleSelection(url) }
                        )
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
                    .disabled(isSelecting || isUploadingLogs)
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
        // Drop selections whose file no longer exists, so "Upload Selected"
        // can never report a count larger than what it will actually send.
        let present = Set(logFiles.map(\.absoluteString))
        selectedLogs.formIntersection(present)
        if logFiles.isEmpty { exitSelectionMode() }
    }

    // MARK: - Selection

    private func enterSelectionMode() {
        isSelecting = true
        selectedLogs = []
        cloudStatus = nil
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedLogs = []
    }

    private func toggleSelection(_ url: URL) {
        let key = url.absoluteString
        if selectedLogs.contains(key) {
            selectedLogs.remove(key)
        } else {
            selectedLogs.insert(key)
        }
    }

    private func toggleSelectAll() {
        if selectedLogs.count == logFiles.count {
            selectedLogs = []
        } else {
            selectedLogs = Set(logFiles.map(\.absoluteString))
        }
    }

    // MARK: - Cloud upload

    private func uploadAllLogsToCloud() {
        upload(logFiles)
    }

    private func uploadSelectedLogsToCloud() {
        upload(selectedURLs)
    }

    private func upload(_ files: [URL]) {
        guard !files.isEmpty else { return }
        isUploadingLogs = true
        cloudStatus = nil

        Task {
            do {
                let count = try await sessionManager.uploadStoredLogs(files)
                await MainActor.run {
                    isUploadingLogs = false
                    cloudStatus = String(format: L("logs.upload_cloud_success"), count)
                    exitSelectionMode()
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
    @EnvironmentObject private var sessionManager: SessionManager
    let url: URL
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: () -> Void = {}

    @State private var fileSize: String = ""
    @State private var rowCount: Int = 0

    // ── Cloud upload ──
    @State private var isUploading = false
    @State private var uploadResult: String? = nil

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

    private var isUploaded: Bool {
        sessionManager.isStoredLogUploaded(url)
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ── File info ──
            HStack {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .blue : .gray)
                        .font(.system(size: 16))
                } else {
                    Image(systemName: "doc.text")
                        .foregroundColor(.cyan)
                        .font(.system(size: 14))
                }
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
                    HStack(spacing: 3) {
                        Image(systemName: isUploaded ? "checkmark.icloud.fill" : "icloud.and.arrow.up")
                        Text(L(isUploaded ? "logs.uploaded" : "logs.pending_upload"))
                    }
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(isUploaded ? .green : .orange)
                }
                Spacer()
            }
            // In selection mode the whole row is the checkbox target — the
            // per-row buttons below are hidden, so there is nothing to conflict
            // with, and a 40 px-tall tap area beats a 16 px glyph on a watch.
            .contentShape(Rectangle())
            .onTapGesture {
                guard isSelecting else { return }
                onToggleSelection()
            }

            if !isSelecting {
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

                // ── Upload this one session to the cloud ──
                Button(action: uploadToCloud) {
                    HStack {
                        if isUploading {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "icloud.and.arrow.up")
                                .font(.system(size: 12))
                        }
                        Text(L(isUploaded ? "logs.upload_again" : "logs.upload_this"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.2))
                    .foregroundColor(.blue)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(isUploading)

                if let uploadResult {
                    Text(uploadResult)
                        .font(.system(size: 9))
                        .foregroundColor(uploadResult.contains("⚠️") ? .orange : .green)
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(isSelected ? 0.12 : 0.05))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.blue.opacity(0.8) : Color.cyan.opacity(0.2), lineWidth: 1)
        )
        .onAppear { loadInfo() }
    }

    // MARK: - Helpers

    /// Load file size and estimate row count off the watch's main thread.
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

            DispatchQueue.main.async {
                self.fileSize = size
                self.rowCount = rows
            }
        }
    }

    /// Upload this single log to the cloud server.
    private func uploadToCloud() {
        isUploading = true
        uploadResult = nil

        Task {
            do {
                _ = try await sessionManager.uploadStoredLogs([url])
                await MainActor.run {
                    isUploading = false
                    uploadResult = L("logs.upload_this_success")
                }
            } catch {
                await MainActor.run {
                    isUploading = false
                    uploadResult = String(format: L("logs.cloud_failed"), error.localizedDescription)
                }
            }
        }
    }
}

#Preview {
    SessionLogsView()
        .environmentObject(SessionManager())
}
