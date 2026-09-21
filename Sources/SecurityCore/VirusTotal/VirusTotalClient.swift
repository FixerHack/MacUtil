import CryptoKit
import Foundation

public struct VirusTotalReport: Codable, Sendable, Hashable {
    public let sha256: String
    public let malicious: Int
    public let suspicious: Int
    public let harmless: Int
    public let undetected: Int
    public let name: String?
    public let analysisDate: Date?

    public var engines: Int {
        malicious + suspicious + harmless + undetected
    }

    public var detections: Int {
        malicious + suspicious
    }

    public var permalink: URL {
        URL(string: "https://www.virustotal.com/gui/file/\(sha256)")!
    }
}

public enum VirusTotalLookup: Codable, Sendable, Hashable {
    case found(VirusTotalReport)
    /// VirusTotal has never seen this file.
    case unknown(sha256: String)
}

public enum VirusTotalError: LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case rateLimited
    case fileTooLarge
    case server(Int)
    case analysisTimedOut

    public var errorDescription: String? {
        switch self {
        case .missingKey: String(localized: "Add your VirusTotal API key in Settings.")
        case .invalidKey: String(localized: "VirusTotal rejected the API key.")
        case .rateLimited: String(localized: "VirusTotal's request limit is reached. Try again in a minute.")
        case .fileTooLarge: String(localized: "The file is larger than 32 MB, the upload limit of the free API.")
        case let .server(code): String(localized: "VirusTotal answered with error \(code).")
        case .analysisTimedOut: String(localized: "VirusTotal did not finish the analysis in time. Check again later.")
        }
    }
}

/// VirusTotal API v3 client. Lookups send only a file's SHA-256; files are uploaded
/// only through `upload`, which the app calls after the user explicitly agrees.
/// Requests are spaced to respect the free API limit of 4 per minute.
public actor VirusTotalClient {
    public static let uploadLimit = 32 * 1024 * 1024

    private let apiKey: String
    private let session: URLSession
    private let minimumInterval: Duration
    private let baseURL = URL(string: "https://www.virustotal.com/api/v3")!
    private var lastRequest: ContinuousClock.Instant?

    public init(apiKey: String, session: URLSession = .shared, minimumInterval: Duration = .seconds(15)) {
        self.apiKey = apiKey
        self.session = session
        self.minimumInterval = minimumInterval
    }

    public func lookup(sha256: String) async throws -> VirusTotalLookup {
        let (data, status) = try await send(URLRequest(url: baseURL.appending(path: "files/\(sha256)")))
        switch status {
        case 200: return try .found(Self.parseFileReport(data, sha256: sha256))
        case 404: return .unknown(sha256: sha256)
        default: throw Self.error(for: status)
        }
    }

    /// Uploads a file (up to 32 MB) and waits for the analysis.
    public func upload(fileAt url: URL, sha256: String) async throws -> VirusTotalReport {
        let file = try Data(contentsOf: url, options: .mappedIfSafe)
        guard file.count <= Self.uploadLimit else { throw VirusTotalError.fileTooLarge }

        let boundary = "MacCleaner-\(UUID().uuidString)"
        var body = Data()
        body
            .append(
                Data(
                    "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
                        .utf8
                )
            )
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: baseURL.appending(path: "files"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, status) = try await send(request)
        guard status == 200 else { throw Self.error(for: status) }
        guard let analysisID = Self.parseAnalysisID(data) else { throw VirusTotalError.server(status) }

        // Analyses usually finish within a few minutes.
        for _ in 0 ..< 20 {
            let (analysis, status) = try await send(URLRequest(url: baseURL.appending(path: "analyses/\(analysisID)")))
            guard status == 200 else { throw Self.error(for: status) }
            if let report = try Self.parseCompletedAnalysis(analysis, sha256: sha256, name: url.lastPathComponent) {
                return report
            }
        }
        throw VirusTotalError.analysisTimedOut
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        if let lastRequest {
            let wait = minimumInterval - (ContinuousClock.now - lastRequest)
            if wait > .zero {
                try await Task.sleep(for: wait)
            }
        }
        lastRequest = .now
        var request = request
        request.setValue(apiKey, forHTTPHeaderField: "x-apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - Parsing

    static func error(for status: Int) -> VirusTotalError {
        switch status {
        case 401, 403: .invalidKey
        case 429: .rateLimited
        default: .server(status)
        }
    }

    private struct FileResponse: Decodable {
        struct Attributes: Decodable {
            let last_analysis_stats: Stats?
            let meaningful_name: String?
            let last_analysis_date: Double?
        }

        struct Data: Decodable {
            let attributes: Attributes
        }

        let data: Data
    }

    private struct Stats: Decodable {
        let malicious: Int?
        let suspicious: Int?
        let harmless: Int?
        let undetected: Int?
    }

    static func parseFileReport(_ data: Data, sha256: String) throws -> VirusTotalReport {
        let attributes = try JSONDecoder().decode(FileResponse.self, from: data).data.attributes
        let stats = attributes.last_analysis_stats
        return VirusTotalReport(
            sha256: sha256,
            malicious: stats?.malicious ?? 0,
            suspicious: stats?.suspicious ?? 0,
            harmless: stats?.harmless ?? 0,
            undetected: stats?.undetected ?? 0,
            name: attributes.meaningful_name,
            analysisDate: attributes.last_analysis_date.map(Date.init(timeIntervalSince1970:))
        )
    }

    static func parseAnalysisID(_ data: Data) -> String? {
        struct Response: Decodable {
            struct Data: Decodable { let id: String }
            let data: Data
        }
        return try? JSONDecoder().decode(Response.self, from: data).data.id
    }

    /// Returns nil while the analysis is still queued or running.
    static func parseCompletedAnalysis(_ data: Data, sha256: String, name: String) throws -> VirusTotalReport? {
        struct Response: Decodable {
            struct Attributes: Decodable {
                let status: String
                let stats: Stats?
                let date: Double?
            }

            struct Data: Decodable { let attributes: Attributes }
            let data: Data
        }
        let attributes = try JSONDecoder().decode(Response.self, from: data).data.attributes
        guard attributes.status == "completed" else { return nil }
        return VirusTotalReport(
            sha256: sha256,
            malicious: attributes.stats?.malicious ?? 0,
            suspicious: attributes.stats?.suspicious ?? 0,
            harmless: attributes.stats?.harmless ?? 0,
            undetected: attributes.stats?.undetected ?? 0,
            name: name,
            analysisDate: attributes.date.map(Date.init(timeIntervalSince1970:))
        )
    }
}

public enum FileHasher {
    /// SHA-256 of a file, read in chunks so large files do not fill memory.
    /// For an app bundle, hashes its main executable.
    public static func sha256(of path: String) throws -> String {
        var target = path
        if path.hasSuffix(".app"), let executable = Bundle(path: path)?.executablePath {
            target = executable
        }
        let handle = try FileHandle(forReadingFrom: URL(filePath: target))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
