import AppKit
import CleanerCore
import SwiftUI

/// What a tool shows in place of itself while it is waiting on Full Disk Access.
///
/// A scan without access does not fail; it comes back small and looks finished. So rather
/// than an answer that is quietly wrong, the tool says what it is missing and how to give it.
/// Coming back from System Settings unlocks it on its own: the app looks again whenever it
/// becomes active.
struct LockedView: View {
    @Environment(AppState.self) private var state
    let module: Module

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: module.symbol)
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.tertiary)
                Image(systemName: "lock.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(5)
                    .background(.background, in: .circle)
                    .offset(x: 10, y: 8)
            }
            .appears()

            VStack(spacing: 8) {
                Text("\(module.titleText) needs Full Disk Access")
                    .font(.title3.weight(.semibold))
                Text("What it looks through is kept where macOS lets only trusted apps read. Without access the scan would still finish, just with part of the answer missing, so it waits until access is given.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 460)
            .appears(0.05)

            HStack(spacing: 10) {
                Button("Open Settings") {
                    NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                }
                .prominentButton()
                .controlSize(.large)
                Button("Show Me How") { state.showsPermissionsGuide = true }
                    .glassButton()
                    .controlSize(.large)
            }
            .appears(0.1)

            Text("Switch UniMacHub on in the list, then come back here. It unlocks by itself.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .appears(0.14)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
