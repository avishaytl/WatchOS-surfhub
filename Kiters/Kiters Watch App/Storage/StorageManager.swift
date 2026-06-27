//
//  StorageManager.swift
//  iSurf-Watch
//
//  Manages local session storage and phone sync
//

import Foundation

class StorageManager {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let pendingCloudUploadKey = "pendingCloudUploadSessionIds"
    
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
    
    func saveSession(_ session: Session) {
        let filename = "\(session.id).json"
        let fileURL = sessionsDirectory.appendingPathComponent(filename)
        
        do {
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(session)
            try data.write(to: fileURL)
            print("💾 Session saved: \(filename)")
            
            // Trigger sync to phone
            syncSessionToPhone(session)
            
        } catch {
            print("❌ Failed to save session: \(error.localizedDescription)")
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
        } catch {
            print("❌ Failed to clear sessions: \(error.localizedDescription)")
        }
    }

    func pendingCloudUploadSessionIds() -> [String] {
        UserDefaults.standard.stringArray(forKey: pendingCloudUploadKey) ?? []
    }
}
