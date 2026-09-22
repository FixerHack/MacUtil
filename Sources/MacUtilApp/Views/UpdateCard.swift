import CleanerCore
import SecurityCore
import SwiftUI

/// Dashboard card for a new MacUtil version: what changed, and one button to install it.
struct UpdateCard: View {
    @Environment(AppState.self) private var state
    @State private var showsNotes = false

    var body: some View {
        let store = state.selfUpdate
        switch store.phase {
        case let .available(release):
            card {
                VStack(alignment: .leading, spacing: 10) {
                    header(
                        title: "MacUtil \(release.version) is available",
                        detail: "You have \(MacUtilInfo.version). The update is \(release.size.formatted(.byteCount(style: .file)))."
                    )
                    if let error = store.lastError {
                        Text(verbatim: error)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if showsNotes, !release.notes.isEmpty {
                        ScrollView {
                            Text(verbatim: release.notes)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                    }
                    HStack {
                        Button("Update Now") { Task { await store.install() } }
                            .prominentButton()
                        Button(showsNotes ? "Hide Changes" : "What's New") { showsNotes.toggle() }
                        Link("Release page", destination: release.pageURL)
                        Spacer()
                        Button("Later") { store.dismiss() }
                    }
                }
            }
        case let .downloading(fraction):
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Downloading the update…")
                    ProgressView(value: fraction)
                }
            }
        case .installing:
            card { progress(title: "Installing…") }
        case let .installed(path):
            card {
                VStack(alignment: .leading, spacing: 10) {
                    header(
                        title: "MacUtil is updated",
                        detail: "Restart MacUtil to start using the new version.",
                        symbol: "checkmark.circle.fill", color: .green
                    )
                    HStack {
                        Button("Restart Now") { state.selfUpdate.restart() }
                            .prominentButton()
                        Spacer()
                        Text(verbatim: FinderActions.abbreviate(path))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        case .idle, .checking:
            EmptyView()
        }
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 14))
    }

    private func header(
        title: LocalizedStringKey, detail: LocalizedStringKey,
        symbol: String = "arrow.down.app.fill", color: Color = .accentColor
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func progress(title: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(title)
            Spacer(minLength: 0)
        }
    }
}

/// Settings row: automatic checks, the current state and a manual check.
struct UpdateSettings: View {
    @Environment(AppState.self) private var state
    @AppStorage(Preferences.automaticUpdateCheck) private var automatic = true

    var body: some View {
        let store = state.selfUpdate
        Toggle("Check for updates automatically", isOn: $automatic)
        LabeledContent("MacUtil \(MacUtilInfo.version)") {
            HStack(spacing: 10) {
                switch store.phase {
                case .checking:
                    ProgressView().controlSize(.small)
                case let .available(release):
                    Text("Version \(release.version) is available")
                        .foregroundStyle(.orange)
                case let .downloading(fraction):
                    ProgressView(value: fraction).frame(width: 90)
                case .installing:
                    ProgressView().controlSize(.small)
                    Text("Updating…")
                case .installed:
                    Button("Restart Now") { store.restart() }
                case .idle:
                    if store.checkedManually {
                        Label("Up to date", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Button("Check Now") { Task { await store.check(manual: true) } }
                    .disabled(store.isBusy)
            }
        }
        if let error = store.lastError {
            Text(verbatim: error)
                .font(.callout)
                .foregroundStyle(.orange)
        }
        Text(
            "MacUtil downloads updates from its GitHub releases and installs only files signed with the same certificate as this copy. Updates installed this way open without the Gatekeeper prompt you saw the first time."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
