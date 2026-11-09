import CleanerCore
import Foundation

/// Runs the Now Playing helper and hands on what it reports.
///
/// The helper is a small library inside the app that /usr/bin/perl loads, because macOS's
/// Now Playing service answers only Apple's own programs (see `MediaRemoteLine`). If the
/// library is missing, or a later macOS closes this way too, the feed simply stays quiet and
/// the island keeps Music and Spotify, which it reads on their own.
@MainActor
final class MediaRemoteFeed {
    typealias Handler = @MainActor (MediaRemoteLine) -> Void

    private let handler: Handler
    private var process: Process?
    private var buffer = Data()
    private var failures = 0
    private var stopped = false
    /// The app macOS considers current, to know which one the play buttons reach.
    private(set) var currentBundleID: String?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// The library, next to the app's own frameworks.
    nonisolated static var library: URL? {
        guard let url = Bundle.main.privateFrameworksURL?.appending(path: "libUniMacHubNowPlaying.dylib"),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    nonisolated static var isAvailable: Bool { library != nil }

    func start() {
        stopped = false
        guard process == nil, let library = Self.library else { return }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/perl")
        process.arguments = ["-e", MediaRemoteLine.perlScript, library.path, "umh_stream"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { @MainActor in self?.ended(status: status) }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        failures = 0
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            guard let report = MediaRemoteLine(json: Data(line)) else { continue }
            currentBundleID = report.bundleID.isEmpty ? nil : report.bundleID
            handler(report)
        }
    }

    /// Starts it again after a crash, a few times, then gives up until the next launch.
    private func ended(status: Int32) {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        buffer.removeAll()
        guard !stopped, status != 2 else { return }
        failures += 1
        guard failures <= 5 else { return }
        let delay = Double(failures * 2)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.stopped else { return }
            self.start()
        }
    }

    // MARK: - Commands

    /// Sends a play button to whichever app macOS considers current.
    nonisolated static func send(_ command: MediaRemoteLine.Command) async {
        await run(environment: ["UMH_COMMAND": String(command.rawValue)])
    }

    /// Moves the current app to a place, in seconds.
    nonisolated static func seek(to seconds: TimeInterval) async {
        await run(environment: ["UMH_SEEK": String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)])
    }

    private nonisolated static func run(environment: [String: String]) async {
        guard let library = Self.library else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/perl")
            process.arguments = ["-e", MediaRemoteLine.perlScript, library.path, "umh_send"]
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() } catch { done.resume() }
        }
    }
}
