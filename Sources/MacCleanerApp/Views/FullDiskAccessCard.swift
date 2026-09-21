import CleanerCore
import SwiftUI

/// Explains why Full Disk Access is needed and walks the user to System Settings.
struct FullDiskAccessCard: View {
    let status: FullDiskAccess.Status
    @Environment(AppState.self) private var state

    var body: some View {
        DashboardCard {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 10) {
                    Text(status == .denied ? "Full Disk Access is not granted" : "Full Disk Access status is unknown")
                        .font(.headline)
                    Text(
                        "MacCleaner needs Full Disk Access to scan caches, mail and browser data. Without it, some files will be skipped."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Text("Turn on MacCleaner in the list. If it is not there, click + and add it, then come back here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                        }
                        .buttonStyle(.glassProminent)
                        Button("Show MacCleaner in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        .buttonStyle(.glass)
                        Button("Check Again") {
                            state.refresh()
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}
