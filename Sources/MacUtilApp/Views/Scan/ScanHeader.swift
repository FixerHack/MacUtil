import CleanerCore
import SwiftUI

/// Location picker, scan button and live progress, shared by the disk space screens.
struct ScanHeader: View {
    @Environment(AppState.self) private var state

    private var store: ScanStore { state.scans }

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Home Folder", systemImage: "house") { store.scan(ScanStore.home) }
                Button("Startup Disk", systemImage: "internaldrive") { store.scan(ScanStore.startupDisk) }
                Divider()
                Button("Choose Folder…", systemImage: "folder") { store.chooseFolderAndScan() }
            } label: {
                Label { ScanTargetName(url: store.target) } icon: { Image(systemName: "folder") }
            }
            .fixedSize()
            .help("Choose what to scan")

            if store.isScanning {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(store.progress.files.formatted()) files · \(store.progress.bytes.formatted(.byteCount(style: .file)))"
                    )
                    .monospacedDigit()
                    Text(verbatim: store.progress.currentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Stop") { store.cancel() }
                    .glassButton()
            } else {
                if let result = store.result {
                    ScanSummary(result: result)
                }
                Spacer()
                Button(store.result == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise") {
                    store.rescan()
                }
                .prominentButton()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

struct ScanTargetName: View {
    let url: URL

    var body: some View {
        if url.isSameLocation(as: ScanStore.home) {
            Text("Home Folder")
        } else if url.isSameLocation(as: ScanStore.startupDisk) {
            Text("Startup Disk")
        } else {
            Text(verbatim: url.lastPathComponent)
        }
    }
}

private struct ScanSummary: View {
    let result: ScanResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(
                "\(result.root.allocatedSize.formatted(.byteCount(style: .file))) in \(result.root.fileCount.formatted()) files"
            )
            .monospacedDigit()
            if result.inaccessibleCount > 0 {
                Text("\(result.inaccessibleCount) folders could not be read")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Grant Full Disk Access to scan everything")
            }
        }
    }
}

/// Shown before the first scan and while scanning.
struct ScanPlaceholder: View {
    let module: Module
    @Environment(AppState.self) private var state

    var body: some View {
        switch state.scans.phase {
        case .scanning:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Scanning…")
                    .font(.title2)
                Text(
                    "\(state.scans.progress.files.formatted()) files · \(state.scans.progress.bytes.formatted(.byteCount(style: .file)))"
                )
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Scan Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Try Again") { state.scans.rescan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .idle, .finished:
            ContentUnavailableView {
                Label(module.title, systemImage: module.symbol)
            } description: {
                Text(module.summary)
            } actions: {
                Button("Scan Home Folder") { state.scans.scan(ScanStore.home) }
                    .prominentButton()
                    .controlSize(.large)
            }
            // Fill the height, or the scan header above slides to the middle of the window.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension URL {
    /// Compares file URLs ignoring a trailing slash and `..` components.
    func isSameLocation(as other: URL) -> Bool {
        standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
            == other.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        count > suffix.count && hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
