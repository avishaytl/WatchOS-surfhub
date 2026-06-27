//
//  CloudSyncService.swift
//  Kiters Watch App
//
//  Cloud API requests for diagnostic logs.
//

import Foundation

enum CloudSyncError: LocalizedError {
    case missingBaseURL
    case invalidURL
    case invalidResponse
    case serverStatus(Int)
    case missingFileData
    case invalidFileText
    case missingCloudPath

    var errorDescription: String? {
        switch self {
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

struct CloudCalibrationSchema: Codable {
    let version: String?
    let minSpeed: Double
    let takeoffG: Double
    let landingG: Double
    let minAirtime: Double
    let maxAirtime: Double
    let cooldown: Double
    let kinematicCalibration: Double
}

final class CloudSyncService {
    static let shared = CloudSyncService()

    private static let defaultBaseURL = "https://vvowvcdylztsqpzifdqc.supabase.co"
    private static let defaultAuthToken = "ywxC26KVA7WD-_HftsCiCBb6W5bxkFzGT-Xe1Z4FvC4"
    private static let defaultLogPath = "/functions/v1/calib-log"

    private let session: URLSession
    private let defaults = UserDefaults.standard

    private init(session: URLSession = CloudSyncService.makeDefaultSession()) {
        self.session = session
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }

    func uploadLog(_ fileURL: URL) async throws -> CloudLogUploadResponse {
        guard let fileData = try? Data(contentsOf: fileURL) else {
            throw CloudSyncError.missingFileData
        }

        // Every log leaves the watch as a binary envelope (KLOG). The raw log
        // bytes are embedded as-is — no base64, no CSV/text branch — while the
        // surrounding metadata keeps the exact same schema/fields as before.
        let logContentType = fileURL.pathExtension.lowercased() == "kslog"
            ? "application/x-kiters-session-log"
            : "application/octet-stream"

        let sessionName = fileURL.deletingPathExtension().lastPathComponent
        var request = try makeRequest(
            method: "POST",
            queryItems: [
                URLQueryItem(name: "device", value: deviceId),
                URLQueryItem(name: "session", value: sessionName)
            ]
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

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

        let (data, response) = try await session.upload(for: request, from: body)
        try validate(response)

        let uploadResponse = (try? JSONDecoder().decode(CloudLogUploadResponse.self, from: data))
            ?? CloudLogUploadResponse(id: nil, status: "uploaded", message: nil, ok: nil, path: nil)
        if let path = uploadResponse.path, !path.isEmpty {
            defaults.set(path, forKey: "cloudLastLogPath")
        }
        return uploadResponse
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

        let request = try makeRequest(
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
        let plistValue = Bundle.main.object(forInfoDictionaryKey: "ISURF_CLOUD_BASE_URL") as? String
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
        let plistValue = Bundle.main.object(forInfoDictionaryKey: "ISURF_CLOUD_AUTH_TOKEN") as? String
        return userValue?.isEmpty == false
            ? userValue
            : plistValue?.isEmpty == false
                ? plistValue
                : Self.defaultAuthToken
    }

    private var logPath: String {
        let userValue = defaults.string(forKey: "cloudLogPath")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyUserValue = defaults.string(forKey: "cloudUploadLogsPath")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plistValue = Bundle.main.object(forInfoDictionaryKey: "ISURF_CLOUD_LOG_PATH") as? String
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

    private func makeRequest(method: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        guard let baseURL else { throw CloudSyncError.missingBaseURL }
        guard let endpointURL = URL(string: logPath, relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: true) else {
            throw CloudSyncError.invalidURL
        }

        components.queryItems = queryItems

        guard let url = components.url else { throw CloudSyncError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        if let authToken, !authToken.isEmpty {
            request.setValue(authToken, forHTTPHeaderField: "X-Calib-Token")
        }

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
