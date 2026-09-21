import CleanerCore
import SwiftUI

/// Step-by-step guide to granting Full Disk Access. Opens by itself on launch while
/// access is missing and notices the moment the user turns it on.
struct PermissionsGuideView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private var isGranted: Bool {
        state.fullDiskAccess == .granted
    }

    /// Permissions only stick to an app at a stable location.
    private var isOutsideApplications: Bool {
        let path = Bundle.main.bundlePath
        return !path.hasPrefix("/Applications/") && !path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if isOutsideApplications {
                Label {
                    Text(
                        "MacUtil is not in the Applications folder. Move it there first, otherwise macOS may forget the permission."
                    )
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
            }

            VStack(alignment: .leading, spacing: 16) {
                GuideStep(number: 1, isDone: isGranted) {
                    Text("Open the Full Disk Access settings.")
                    Button("Open System Settings", systemImage: "gear") {
                        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                    }
                    .buttonStyle(.glassProminent)
                }
                GuideStep(number: 2, isDone: isGranted) {
                    Text(
                        "Find MacUtil in the list and turn on its switch. macOS asks for your password or Touch ID."
                    )
                    HStack(spacing: 14) {
                        AppIconDragSource()
                        Text(
                            "Not in the list? Drag this icon into the list, or click + below the list and choose MacUtil."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GuideStep(number: 3, isDone: isGranted) {
                    Text(
                        "If macOS offers to quit and reopen MacUtil, choose either option. MacUtil notices the change by itself."
                    )
                }
            }

            status

            HStack {
                Spacer()
                if isGranted {
                    Button("Continue") { dismiss() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Later") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 560)
        .task {
            // Poll: macOS does not notify apps when a permission changes.
            while !Task.isCancelled, !isGranted {
                try? await Task.sleep(for: .seconds(1))
                state.refresh()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange, .orange.opacity(0.25))
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow MacUtil to see your whole disk")
                    .font(.title2.bold())
                Text(
                    "Caches, mail attachments, browser data and the Trash are protected by macOS. Without Full Disk Access MacUtil cannot measure or clean them. Files never leave your Mac."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Full Disk Access is on. You're all set.")
                    .fontWeight(.semibold)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for access…")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.headline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isGranted ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
        .animation(.default, value: isGranted)
    }
}

private struct GuideStep<Content: View>: View {
    let number: Int
    let isDone: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isDone ? Color.green : Color.accentColor)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                } else {
                    Text(verbatim: "\(number)")
                        .font(.callout.bold())
                }
            }
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The app's own icon, draggable into the System Settings list.
private struct AppIconDragSource: View {
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .frame(width: 56, height: 56)
            .padding(6)
            .background(.fill.quaternary, in: .rect(cornerRadius: 12))
            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            .help("Drag into the Full Disk Access list")
    }
}
