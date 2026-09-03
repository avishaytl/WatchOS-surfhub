//
//  StorageManager.swift
//  SPOTEQ
//
//  Manages local session storage and phone sync
//

import Foundation

class StorageManager {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let pendingCloudUploadKey = "pendingCloudUploadSessionIds"
    private let uploadedCloudLogNamesKey = "uploadedCloudLogFileNames"
    private let cloudLogFileBySessionKey = "cloudLogFileBySessionId"
    private let cloudServerSessionIdKey = "cloudServerSessionIdByLocalSessionId"
    
    // Storage paths
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private var sessionsDirectory: URL {
        documentsDirectory.appendingPathComponent("sessions", isDirectory: true)
    }
    
    init() {
        setupStorage()
    }
    
    // MARK: - Setup
    
    private func setupStorage() {
        // Create sessions directory if it doesn't exist
        if !fileManager.fileExists(atPath: sessionsDirectory.path) {
            try? fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
            print("📁 Created sessions directory")
        }
    }
    
    // MARK: - Session Storage
    
    /// Persists the complete session before any cloud work begins.
    ///
    /// Returning the result lets the caller surface a storage failure instead
    /// of silently resetting the UI and losing the only in-memory copy. Atomic
    /// replacement also protects an existing session from a partial rewrite.
    @discardableResult
    func saveSession(_ session: Session) -> Bool {
        let filename = "\(session.id).json"
        let fileURL = sessionsDirectory.appendingPathComponent(filename)
        
        do {
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(session)
            try data.write(to: fileURL, options: .atomic)
            print("💾 Session saved: \(filename)")
            
            // Trigger sync to phone
            syncSessionToPhone(session)
            return true
            
        } catch {
            print("❌ Failed to save session: \(error.localizedDescription)")
            return false
        }
    }
    
    func loadSession(id: String) -> Session? {
        let filename = "\(id).json"
        let fileURL = sessionsDirectory.appendingPathComponent(filename)
        
        do {
            let data = try Data(contentsOf: fileURL)
            decoder.dateDecodingStrategy = .iso8601
            let session = try decoder.decode(Session.self, from: data)
            return session
            
        } catch {
            print("❌ Failed to load session: \(error.localizedDescription)")
            return nil
        }
    }
    
    func loadAllSessions() -> [Session] {
        do {
            let fileURLs = try fileManager.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: nil
            )
            
            let sessions = fileURLs.compactMap { url -> Session? in
                guard url.pathExtension == "json" else { return nil }
                
                do {
                    let data = try Data(contentsOf: url)
                    decoder.dateDecodingStrategy = .iso8601
                    return try decoder.decode(Session.self, from: data)
                } catch {
                    print("⚠️ Failed to load session from \(url.lastPathComponent)")
                    return nil
                }
            }
            
            // Sort by start time (newest first)
            return sessions.sorted { $0.startTime > $1.startTime }
            
        } catch {
            print("❌ Failed to load sessions: \(error.localizedDescription)")
            return []
        }
    }
    
    func deleteSession(id: String) {
        let filename = "\(id).json"
        let fileURL = sessionsDirectory.appendingPathComponent(filename)
        
        do {
            try fileManager.removeItem(at: fileURL)
            clearPendingCloudUpload(sessionId: id)
            var associations = cloudLogFileAssociations()
            associations.removeValue(forKey: id)
            UserDefaults.standard.set(associations, forKey: cloudLogFileBySessionKey)
            var serverIds = cloudServerSessionIds()
            serverIds.removeValue(forKey: id)
            UserDefaults.standard.set(serverIds, forKey: cloudServerSessionIdKey)
            print("🗑️ Session deleted: \(filename)")
        } catch {
            print("❌ Failed to delete session: \(error.localizedDescription)")
        }
    }

    func markPendingCloudUpload(sessionId: String) {
        var ids = pendingCloudUploadSessionIds()
        if !ids.contains(sessionId) {
            ids.append(sessionId)
            UserDefaults.standard.set(ids, forKey: pendingCloudUploadKey)
        }
    }

    func clearPendingCloudUpload(sessionId: String) {
        let ids = pendingCloudUploadSessionIds().filter { $0 != sessionId }
        UserDefaults.standard.set(ids, forKey: pendingCloudUploadKey)
    }

    func loadMostRecentPendingCloudSession() -> Session? {
        let pendingIds = Set(pendingCloudUploadSessionIds())
        guard !pendingIds.isEmpty else { return nil }
        return loadAllSessions().first { pendingIds.contains($0.id) }
    }

    // MARK: - Diagnostic Log Upload Ledger

    /// A missing filename means the local log has never completed an upload.
    /// Keeping this separately from session-summary state prevents one
    /// successful half of the upload from incorrectly clearing the other.
    func markCloudLogUploaded(_ fileURL: URL) {
        var names = uploadedCloudLogNames()
        names.insert(fileURL.lastPathComponent)
        UserDefaults.standard.set(Array(names).sorted(), forKey: uploadedCloudLogNamesKey)
    }

    func isCloudLogUploaded(_ fileURL: URL) -> Bool {
        uploadedCloudLogNames().contains(fileURL.lastPathComponent)
    }

    func associateCloudLog(_ fileURL: URL, withSessionId sessionId: String) {
        var associations = cloudLogFileAssociations()
        associations[sessionId] = fileURL.lastPathComponent
        UserDefaults.standard.set(associations, forKey: cloudLogFileBySessionKey)
    }

    func cloudLogFileName(forSessionId sessionId: String) -> String? {
        cloudLogFileAssociations()[sessionId]
    }

    /// Persist the server-side id as soon as Start succeeds. A later callback or
    /// relaunch can then finish this exact remote session instead of borrowing a
    /// newer recording's id or creating another row.
    func saveCloudServerSessionId(_ serverSessionId: Int, forLocalSessionId sessionId: String) {
        var serverIds = cloudServerSessionIds()
        serverIds[sessionId] = serverSessionId
        UserDefaults.standard.set(serverIds, forKey: cloudServerSessionIdKey)
    }

    func cloudServerSessionId(forLocalSessionId sessionId: String) -> Int? {
        cloudServerSessionIds()[sessionId]
    }

    /// Log filenames contain the first eight characters of their session UUID.
    /// Resolve that durable association when rebuilding pending state at launch.
    func loadSession(matchingLogURL fileURL: URL) -> Session? {
        let filename = fileURL.lastPathComponent
        if let sessionId = cloudLogFileAssociations().first(where: { $0.value == filename })?.key,
           let session = loadSession(id: sessionId) {
            return session
        }
        return loadAllSessions().first { session in
            filename.contains(String(session.id.prefix(8)))
        }
    }

    private func uploadedCloudLogNames() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: uploadedCloudLogNamesKey) ?? [])
    }

    private func cloudLogFileAssociations() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: cloudLogFileBySessionKey) as? [String: String] ?? [:]
    }

    private func cloudServerSessionIds() -> [String: Int] {
        let raw = UserDefaults.standard.dictionary(forKey: cloudServerSessionIdKey) ?? [:]
        return raw.reduce(into: [String: Int]()) { result, item in
            if let value = item.value as? NSNumber {
                result[item.key] = value.intValue
            }
        }
    }
    
    // MARK: - Sync to Phone
    
    private func syncSessionToPhone(_ session: Session) {
        // This will be implemented with WatchConnectivity
        // For now, just mark it as pending sync
        print("📱 Queued for phone sync: \(session.id)")
        
        // TODO: Implement WatchConnectivity file transfer
        // WatchConnectivityManager.shared.transferSession(session)
    }
    
    // MARK: - Storage Utilities
    
    func getStorageSize() -> Int64 {
        var totalSize: Int64 = 0
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: [.fileSizeKey]
            )
            
            for url in fileURLs {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                if let size = attributes[.size] as? Int64 {
                    totalSize += size
                }
            }
        } catch {
            print("⚠️ Failed to calculate storage size")
        }
        
        return totalSize
    }
    
    func clearAllSessions() {
        do {
            let fileURLs = try fileManager.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: nil
            )
            
            for url in fileURLs {
                try fileManager.removeItem(at: url)
            }
            
            print("🗑️ All sessions cleared")
            UserDefaults.standard.removeObject(forKey: pendingCloudUploadKey)
            UserDefaults.standard.removeObject(forKey: cloudLogFileBySessionKey)
            UserDefaults.standard.removeObject(forKey: cloudServerSessionIdKey)
        } catch {
            print("❌ Failed to clear sessions: \(error.localizedDescription)")
        }
    }

    func pendingCloudUploadSessionIds() -> [String] {
        UserDefaults.standard.stringArray(forKey: pendingCloudUploadKey) ?? []
    }
}
