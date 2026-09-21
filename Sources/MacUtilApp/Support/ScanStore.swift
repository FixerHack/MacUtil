import AppKit
import CleanerCore
import Observation

/// The current disk scan, shared by Space Lens and Large & Old Files so one scan
/// serves both screens.
@MainActor
@Observable
final class ScanStore {
    enum Phase {
        case idle, scanning, finished
        case failed(String)
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let startupDisk = URL(filePath: "/")

    private(set) var target = ScanStore.home
    private(set) var phase = Phase.idle
    private(set) var progress = ScanProgress()
    private(set) var result: ScanResult?
    private var scanner: DiskScanner?

    var isScanning: Bool {
        if case .scanning = phase {
            true
        } else {
            false
        }
    }

    func scan(_ url: URL) {
        scanner?.cancel()
        let scanner = DiskScanner()
        self.scanner = scanner
        target = url
        result = nil
        progress = ScanProgress()
        phase = .scanning

        Task {
            let poller = Task {
                while !Task.isCancelled {
                    progress = scanner.progress
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            defer { poller.cancel() }
            do {
                let result = try await scanner.scan(url)
                guard self.scanner === scanner else { return }
                self.result = result
                phase = .finished
            } catch is CancellationError {
                if self.scanner === scanner {
                    phase = .idle
                }
            } catch {
                if self.scanner === scanner {
                    phase = .failed(error.localizedDescription)
                }
            }
            if self.scanner === scanner {
                progress = scanner.progress
            }
        }
    }

    func rescan() {
        scan(target)
    }

    func cancel() {
        scanner?.cancel()
    }

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = target
        if panel.runModal() == .OK, let url = panel.url {
            scan(url)
        }
    }
}
