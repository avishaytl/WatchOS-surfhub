//
//  CloudSyncService.swift
//  SPOTEQ Watch App
//
//  Cloud API requests for diagnostic logs.
//

import Foundation
import Compression

/// RFC 1952 (gzip) encoder.
///
/// Foundation has no gzip API. `NSData.compressed(using: .zlib)` is the
/// Compression framework's COMPRESSION_ZLIB, which despite the name emits RAW
/// DEFLATE (RFC 1951) with no container at all — send that as
/// `Content-Encoding: gzip` and every decoder rejects it. The 10-byte header
/// and 8-byte trailer below are what make it a gzip stream; the trailer's CRC
/// and length are checked by the receiver, so they are not optional padding.
private enum Gzip {
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else {
            return nil
        }

        var out = Data(capacity: deflated.count + 18)
        out.append(contentsOf: [
            0x1f, 0x8b,             // magic
            0x08,                   // DEFLATE
            0x00,                   // no optional fields
            0x00, 0x00, 0x00, 0x00, // mtime: unset — the filename is in the envelope
            0x00,                   // no extra flags
            0xff,                   // unknown OS
        ])
        out.append(deflated)
        withUnsafeBytes(of: crc32(data).littleEndian) { out.append(contentsOf: $0) }
        // ISIZE is the uncompressed length modulo 2^32 by definition, so the
        // truncation here is the spec, not a bug.
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).littleEndian) {
            out.append(contentsOf: $0)
        }
        return out
    }

    private static let table: [UInt32] = (0..<256).map { i in
        (0..<8).reduce(UInt32(i)) { c, _ in (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { raw in
                for byte in raw.bindMemory(to: UInt8.self) {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

enum CloudSyncError: LocalizedError {
    case notAuthenticated
    case diagnosticAdminUnavailable
    case missingBaseURL
    case invalidURL
    case invalidResponse
    case serverStatus(Int)
    case missingFileData
    case invalidFileText
    case missingCloudPath

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in to upload this session."
        case .diagnosticAdminUnavailable:
            return "Diagnostic cloud access is not configured."
        case .missingBaseURL:
            return "Cloud URL is not configured."
        case .invalidURL:
            return "Cloud URL is invalid."
        case .invalidResponse:
            return "Cloud response is invalid."
        case .serverStatus(let status):
            return "Cloud returned HTTP \(status)."
        case .missingFileData:
            return "Log file could not be read."
        case .invalidFileText:
            return "Log file is not valid text."
        case .missingCloudPath:
            return "Upload a log before fetching it."
        }
    }
}

struct CloudLogUploadResponse: Decodable {
    let id: String?
    let status: String?
    let message: String?
    let ok: Bool?
    let path: String?
}

final class CloudSyncService {
    static let shared = CloudSyncService()

    private static let defaultBaseURL = "https://vvowvcdylztsqpzifdqc.supabase.co"
    private static let defaultUploadPath = "/functions/v1/watch-log-upload"
    private static let defaultLogPath = "/functions/v1/calib-log"

    private let session: URLSession
    private let defaults = UserDefaults.standard

    private init(session: URLSession = CloudSyncService.makeDefaultSession()) {
        self.session = session
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        // IDLE timeout — the longest gap allowed BETWEEN packets, not a cap on
        // the transfer. 30 s was tight for a watch relaying through the phone
        // over Bluetooth, where a stall of that length is ordinary.
        configuration.timeoutIntervalForRequest = 60
        // TOTAL timeout for the whole transfer, and the one that was actually
        // failing: a 22 MB session log pushed off the wrist over BT/WiFi does
        // not finish inside 120 s, so every large upload died with
        // NSURLErrorTimedOut ("The request timed out") no matter how healthy
        // the link was. 10 minutes, which is generous even for an uncompressed
        // body on a slow link — the gzip path below normally lands in seconds.
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }

    func uploadLog(_ fileURL: URL) async throws -> CloudLogUploadResponse {
        let sessionName = fileURL.deletingPathExtension().lastPathComponent
        var request = try await makeUploadRequest(
            queryItems: [
                URLQueryItem(name: "device", value: deviceId),
                URLQueryItem(name: "session", value: sessionName)
            ]
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        // The envelope is built inside its own scope so the file bytes and the
        // uncompressed envelope are both released BEFORE the upload starts. A
        // 22 MB log otherwise sits in memory three times over — file, envelope,
        // compressed body — for the whole transfer, on a watch.
        let payload = try makeUploadPayload(for: fileURL)
        if payload.isGzipped {
            // Transport-level encoding. The KLOG envelope's own
            // `contentEncoding` field still describes the INNER log bytes and
            // stays "binary" — the server gunzips first, then parses exactly
            // what it parsed before.
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }

        let (data, response) = try await session.upload(for: request, from: payload.body)
        try validate(response)

        let uploadResponse = (try? JSONDecoder().decode(CloudLogUploadResponse.self, from: data))
            ?? CloudLogUploadResponse(id: nil, status: "uploaded", message: nil, ok: nil, path: nil)
        if let path = uploadResponse.path, !path.isEmpty {
            defaults.set(path, forKey: "cloudLastLogPath")
        }
        return uploadResponse
    }

    private struct UploadPayload {
        let body: Data
        let isGzipped: Bool
    }

    /// Reads the log, wraps it in the KLOG envelope, and gzips the result when
    /// that actually helps.
    ///
    /// A session log is half a million lines of decimal numbers, so it deflates
    /// by roughly 5-10x: the 22 MB upload that was timing out goes out as a few
    /// MB and lands in seconds. It also clears the server's body-size ceiling,
    /// which the raw envelope exceeded outright.
    ///
    /// Falls back to the uncompressed body whenever compression fails or fails
    /// to pay — an older server that ignores `Content-Encoding` then still sees
    /// exactly the bytes it saw before.
    private func makeUploadPayload(for fileURL: URL) throws -> UploadPayload {
        guard let fileData = try? Data(contentsOf: fileURL) else {
            throw CloudSyncError.missingFileData
        }

        // Every log leaves the watch as a binary envelope (KLOG). The raw log
        // bytes are embedded as-is — no base64, no CSV/text branch — while the
        // surrounding metadata keeps the exact same schema/fields as before.
        let logContentType = fileURL.pathExtension.lowercased() == "kslog"
            ? "application/x-kiters-session-log"
            : "application/octet-stream"

        let envelope = BinaryLogEnvelope(fields: [
            .string("type", "session_log"),
            .string("filename", fileURL.lastPathComponent),
            .string("contentType", logContentType),
            .string("contentEncoding", "binary"),
            .string("appVersion", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""),
            .string("build", Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""),
            .string("uploadedAt", ISO8601DateFormatter().string(from: Date())),
            .blob("content", fileData)
        ])
        let body = envelope.encoded()

        if let gzipped = Gzip.compress(body), gzipped.count < body.count {
            return UploadPayload(body: gzipped, isGzipped: true)
        }
        return UploadPayload(body: body, isGzipped: false)
    }

    func uploadLogs(_ fileURLs: [URL]) async throws -> Int {
        var uploadedCount = 0
        for fileURL in fileURLs {
            _ = try await uploadLog(fileURL)
            uploadedCount += 1
        }
        return uploadedCount
    }

    func fetchCloudLogResponse() async throws -> String {
        guard let path = defaults.string(forKey: "cloudLastLogPath")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw CloudSyncError.missingCloudPath
        }

        let request = try makeAdminRequest(
            method: "GET",
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
        let (data, response) = try await session.data(for: request)
        try validate(response)

        guard !data.isEmpty else { return "Empty response" }
        return String(data: data, encoding: .utf8) ?? "\(data.count) bytes received"
    }

    private var baseURL: URL? {
        let userValue = defaults.string(forKey: "cloudBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plistValue = Bundle.main.object(forInfoDictionaryKey: "SPOTEQ_CLOUD_BASE_URL") as? String
        let rawValue = userValue?.isEmpty == false
            ? userValue
            : plistValue?.isEmpty == false
                ? plistValue
                : Self.defaultBaseURL

        guard let rawValue, !rawValue.isEmpty else { return nil }
        return URL(string: rawValue)
    }

    private var authToken: String? {
        let userValue = defaults.string(forKey: "cloudAuthToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plistValue = Bundle.main.object(forInfoDictionaryKey: "SPOTEQ_CLOUD_AUTH_TOKEN") as? String
        if let userValue, !userValue.isEmpty { return userValue }
        if let plistValue, !plistValue.isEmpty { return plistValue }
        return nil
    }

    /// Admin-only calibration access remains available for internal builds that
    /// inject a token at runtime. Production session uploads never use it.
    var isAdminConfigured: Bool {
        baseURL != nil && authToken != nil
    }

    private var logPath: String {
        let userValue = defaults.string(forKey: "cloudLogPath")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyUserValue = defaults.string(forKey: "cloudUploadLogsPath")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plistValue = Bundle.main.object(forInfoDictionaryKey: "SPOTEQ_CLOUD_LOG_PATH") as? String
        return userValue?.isEmpty == false
            ? userValue!
            : legacyUserValue?.isEmpty == false
                ? legacyUserValue!
                : plistValue?.isEmpty == false
                    ? plistValue!
                    : Self.defaultLogPath
    }

    private var deviceId: String {
        let userValue = defaults.string(forKey: "cloudDeviceId")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return userValue?.isEmpty == false ? userValue! : "watch"
    }

    private func makeBaseRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URLRequest {
        guard let baseURL else { throw CloudSyncError.missingBaseURL }
        guard let endpointURL = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: true) else {
            throw CloudSyncError.invalidURL
        }

        components.queryItems = queryItems

        guard let url = components.url else { throw CloudSyncError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        // Per-request IDLE timeout; it OVERRIDES timeoutIntervalForRequest, so
        // leaving it at 45 would have undone half the fix above. It does not
        // cap the transfer — timeoutIntervalForResource does that.
        request.timeoutInterval = 60
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    private func makeUploadRequest(queryItems: [URLQueryItem]) async throws -> URLRequest {
        let pairing: WatchPairing
        do {
            pairing = try await WatchPairingStore.shared.validPairing()
        } catch {
            throw CloudSyncError.notAuthenticated
        }

        var request = try makeBaseRequest(
            method: "POST",
            path: Self.defaultUploadPath,
            queryItems: queryItems
        )
        request.setValue(WatchAuth.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(pairing.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeAdminRequest(method: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        guard let authToken, !authToken.isEmpty else {
            throw CloudSyncError.diagnosticAdminUnavailable
        }
        var request = try makeBaseRequest(method: method, path: logPath, queryItems: queryItems)
        request.setValue(authToken, forHTTPHeaderField: "X-Calib-Token")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudSyncError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw CloudSyncError.serverStatus(httpResponse.statusCode)
        }
    }
}
