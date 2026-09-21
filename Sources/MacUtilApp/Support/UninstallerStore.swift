import AppKit
import CleanerCore
import Observation

/// Installed apps, the data each one leaves in the libraries, and uninstalling.
@MainActor
@Observable
final class UninstallerStore {
    enum Phase {
        case idle, loading, ready, working
        case done(CleanupResult)
    }

    private(set) var phase = Phase.idle
    private(set) var apps: [AppRecord] = []
    private(set) var leftovers: [Leftover] = []
    private(set) var isLoadingLeftovers = false
    var selectedLeftovers = Set<Leftover.ID>()
    var selectedAppID: AppRecord.ID? {
        didSet {
            if selectedAppID != oldValue {
                Task { await loadLeftovers() }
            }
        }
    }

    var selectedApp: AppRecord? {
        apps.first { $0.id == selectedAppID }
    }

    var selectedLeftoverSize: Int64 {
        leftovers.filter { selectedLeftovers.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func load() async {
        phase = .loading
        apps = await AppCatalog.scan()
        phase = .ready
        if selectedApp == nil {
            selectedAppID = nil
        }
    }

    private func loadLeftovers() async {
        leftovers = []
        selectedLeftovers = []
        guard let app = selectedApp else { return }
        isLoadingLeftovers = true
        let found = await AppLeftovers.find(bundleID: app.bundleID, name: app.name)
        guard selectedAppID == app.id else { return }
        leftovers = found
        // Items matched only by name need a look first; /Library needs admin rights.
        selectedLeftovers = Set(found.filter { $0.match == .bundleID && !$0.requiresAdmin }.map(\.id))
        isLoadingLeftovers = false
    }

    func runningApp(for app: AppRecord) -> NSRunningApplication? {
        guard let bundleID = app.bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    func quit(_ app: AppRecord) async {
        runningApp(for: app)?.terminate()
        // Give the app a moment to save and quit.
        for _ in 0 ..< 20 where runningApp(for: app) != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Moves the app (optionally) and the selected data to the Trash.
    func remove(_ app: AppRecord, includingApp: Bool) async {
        var targets = leftovers.filter { selectedLeftovers.contains($0.id) }
            .map { CleanupTarget(path: $0.path, size: $0.size) }
        if includingApp {
            targets.insert(CleanupTarget(path: app.path, size: app.size), at: 0)
        }
        guard !targets.isEmpty else { return }
        phase = .working
        let cleaner = Cleaner(safety: SafetyGuard(extraAllowedRoots: ["/Applications"]), trash: AppTrash())
        let result = await cleaner.clean(targets, mode: .trash, source: "uninstall.\(app.bundleID ?? app.name)")
        phase = .done(result)
    }

    func undo(_ result: CleanupResult) async {
        phase = .working
        _ = await Cleaner().undo(result)
        await finish()
    }

    func finish() async {
        selectedAppID = nil
        await load()
    }
}

/// Moves items to the Trash. Apps installed by an administrator (for example from
/// the App Store) belong to root; Finder can remove those after asking for the password.
struct AppTrash: TrashDestination {
    func trash(_ url: URL) throws -> URL? {
        do {
            return try SystemTrash().trash(url)
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            return try finderDelete(url)
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && [EPERM, EACCES].contains(Int32(error.code))
        {
            return try finderDelete(url)
        }
    }

    private func finderDelete(_ url: URL) throws -> URL? {
        let path = url.path(percentEncoded: false)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to return POSIX path of ((delete (POSIX file \"\(path)\")) as alias)"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
        }
        let trashed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trashed.isEmpty ? nil : URL(filePath: trashed)
    }
}
