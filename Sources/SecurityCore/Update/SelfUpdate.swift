import CleanerCore
import CryptoKit
import Foundation
import Security

/// A MacUtil release on GitHub.
public struct MacUtilRelease: Sendable, Hashable, Identifiable {
    public let version: String
    public let notes: String
    public let downloadURL: URL
    public let pageURL: URL
    /// sha256 of the DMG as GitHub reports it, when the API includes a digest.
    public let sha256: String?
    public let size: Int64

    public var id: String { version }
}

/// Updates MacUtil itself from its GitHub releases.
///
/// An update installed this way never carries the quarantine flag, because MacUtil downloads it
/// instead of a browser. The first install still goes through Gatekeeper; later updates do not.
/// Two checks stand between the download and the Applications folder: the sha256 GitHub reports,
/// and a code signature that satisfies the running app's own designated requirement, so a
/// replaced download signed by anyone else is refused.
public enum SelfUpdate {
    public enum Failure: LocalizedError, Sendable, Equatable {
        case network
        case badDownload
        case wrongChecksum
        case notSameSigner
        case cannotWrite(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .network:
                String(localized: "Could not reach GitHub.")
            case .badDownload:
                String(localized: "The downloaded file is not a working MacUtil disk image.")
            case .wrongChecksum:
                String(localized: "The downloaded file does not match what GitHub published. Nothing was installed.")
            case .notSameSigner:
                String(
                    localized: "The downloaded MacUtil is signed by someone else, so it was not installed. Download MacUtil from the releases page instead."
                )
            case let .cannotWrite(path):
                String(localized: "MacUtil cannot update itself at \(path). Move it to your Applications folder and try again.")
            case let .failed(message):
                message
            }
        }
    }

    /// The newest release when it is newer than `currentVersion`, otherwise nil.
    public static func check(
        currentVersion: String = MacUtilInfo.version,
        repository: String = MacUtilInfo.repository,
        session: URLSession = .shared
    ) async throws -> MacUtilRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacUtil/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { throw Failure.network }

        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              !release.draft, !release.prerelease
        else { return nil }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard isNewer(version, than: currentVersion) else { return nil }
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { return nil }

        return MacUtilRelease(
            version: version,
            notes: release.body ?? "",
            downloadURL: asset.browserDownloadURL,
            pageURL: release.htmlURL,
            sha256: asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil },
            size: asset.size
        )
    }

    /// Downloads the disk image and checks its sha256 against what GitHub published.
    /// `progress` is called with 0…1 while the file arrives.
    public static func download(
        _ release: MacUtilRelease,
        session: URLSession = .shared,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        var request = URLRequest(url: release.downloadURL)
        request.timeoutInterval = 300
        request.setValue("MacUtil", forHTTPHeaderField: "User-Agent")

        let temporary: URL
        do {
            temporary = try await DownloadWatcher.download(request, session: session, progress: progress)
        } catch {
            throw Failure.network
        }

        let file = FileManager.default.temporaryDirectory
            .appending(path: "MacUtil-\(release.version)-\(UUID().uuidString).dmg")
        try? FileManager.default.removeItem(at: file)
        do {
            try FileManager.default.moveItem(at: temporary, to: file)
        } catch {
            throw Failure.badDownload
        }

        if let expected = release.sha256, try sha256(of: file) != expected.lowercased() {
            try? FileManager.default.removeItem(at: file)
            throw Failure.wrongChecksum
        }
        return file
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Mounts the image, checks the signature and replaces the running app with the new one.
    /// Returns where the updated app sits.
    public static func install(dmg: URL, replacing app: URL = Bundle.main.bundleURL) async throws -> URL {
        let directory = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw Failure.cannotWrite(directory.path)
        }

        let mountPoint = FileManager.default.temporaryDirectory.appending(path: "MacUtilUpdate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard let attach = await Command.run("/usr/bin/hdiutil", [
            "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path,
        ], timeout: .seconds(120)), attach.status == 0 else {
            try? FileManager.default.removeItem(at: mountPoint)
            throw Failure.badDownload
        }
        let newApp = mountPoint.appending(path: app.lastPathComponent)
        func unmount() async {
            _ = await Command.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"], timeout: .seconds(60))
            try? FileManager.default.removeItem(at: mountPoint)
        }
        func fail(_ error: Failure, staged: URL? = nil) async -> Failure {
            if let staged { try? FileManager.default.removeItem(at: staged) }
            await unmount()
            return error
        }

        guard FileManager.default.fileExists(atPath: newApp.path) else { throw await fail(.badDownload) }
        do {
            try verifySameSigner(newApp, as: app)
        } catch let error as Failure {
            throw await fail(error)
        }

        // Stage next to the current app so the swap happens on one volume.
        let staged = directory.appending(path: ".\(app.lastPathComponent).update-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: staged)
        let copy = await Command.run("/usr/bin/ditto", [newApp.path, staged.path], timeout: .seconds(300))
        guard copy?.status == 0 else {
            throw await fail(.failed(copy?.text ?? String(localized: "The update could not be copied.")), staged: staged)
        }
        do {
            _ = try FileManager.default.replaceItemAt(app, withItemAt: staged)
        } catch {
            throw await fail(.failed(error.localizedDescription), staged: staged)
        }
        await unmount()
        return app
    }

    /// Quits this copy and starts the updated one.
    public static func relaunch(at app: URL) {
        let task = Process()
        task.executableURL = URL(filePath: "/usr/bin/open")
        task.arguments = ["-n", app.path]
        try? task.run()
    }

    // MARK: - Checks

    /// The new app must satisfy the requirement this copy was signed against, so only builds from
    /// the same certificate can replace it.
    static func verifySameSigner(_ candidate: URL, as current: URL) throws {
        var currentCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(current as CFURL, [], &currentCode) == errSecSuccess,
              let currentCode
        else { throw Failure.failed(String(localized: "MacUtil cannot read its own signature.")) }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(currentCode, [], &requirement) == errSecSuccess,
              let requirement
        else { throw Failure.failed(String(localized: "MacUtil cannot read its own signature.")) }

        var candidateCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess,
              let candidateCode
        else { throw Failure.notSameSigner }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(candidateCode, flags, requirement)
        guard status == errSecSuccess else { throw Failure.notSameSigner }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    /// Reports download progress, which `URLSession.download(for:)` does not.
    private final class DownloadWatcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let progress: @Sendable (Double) -> Void
        private var resume: CheckedContinuation<URL, Error>?

        private init(progress: @escaping @Sendable (Double) -> Void) {
            self.progress = progress
        }

        static func download(
            _ request: URLRequest, session: URLSession, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> URL {
            let watcher = DownloadWatcher(progress: progress)
            let delegating = URLSession(
                configuration: session.configuration, delegate: watcher, delegateQueue: nil
            )
            defer { delegating.finishTasksAndInvalidate() }
            return try await withCheckedThrowingContinuation { continuation in
                watcher.resume = continuation
                delegating.downloadTask(with: request).resume()
            }
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
            totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64
        ) {
            guard expected > 0 else { return }
            progress(min(Double(written) / Double(expected), 1))
        }

        func urlSession(
            _: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
        ) {
            // The file is deleted when this method returns, so move it out of the way first.
            let kept = FileManager.default.temporaryDirectory.appending(path: "MacUtil-\(UUID().uuidString).part")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
            } catch {
                resume?.resume(throwing: error)
                resume = nil
                return
            }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                try? FileManager.default.removeItem(at: kept)
                resume?.resume(throwing: Failure.network)
                resume = nil
                return
            }
            progress(1)
            resume?.resume(returning: kept)
            resume = nil
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            resume?.resume(throwing: error)
            resume = nil
        }
    }

    // MARK: - GitHub API

    private struct GitHubRelease: Decodable {
        let tagName: String
        let body: String?
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let size: Int64
            let digest: String?
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name, size, digest
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case body, draft, prerelease, assets
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
