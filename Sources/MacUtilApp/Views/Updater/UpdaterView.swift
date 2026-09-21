import CleanerCore
import SwiftUI

struct UpdaterView: View {
    let store: UpdaterStore

    var body: some View {
        Group {
            switch store.phase {
            case .idle:
                ContentUnavailableView {
                    Label("Updater", systemImage: "arrow.down.app")
                } description: {
                    Text(
                        "Checks your apps for new versions through their own update feeds (Sparkle), Homebrew and the App Store."
                    )
                } actions: {
                    Button("Check for Updates") { Task { await store.check() } }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
            case .checking:
                BusyView(title: "Checking for updates…")
            case .ready:
                List {
                    if store.updates.isEmpty {
                        Label("All \(store.appCount) apps are up to date.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    ForEach(store.updates) { update in
                        UpdateRow(update: update, store: store)
                    }
                    Section {
                        if !store.hasHomebrew {
                            Text("Apps installed with Homebrew are checked when Homebrew is installed.")
                        }
                        if !store.hasMas {
                            Text("To check App Store apps, install the mas tool: brew install mas")
                        }
                        Text(
                            "Apps without an update feed are not listed; they update themselves or through the website."
                        )
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Updater")
        .toolbar {
            ToolbarItem {
                Button("Check Again", systemImage: "arrow.clockwise") { Task { await store.check() } }
                    .disabled(store.phase == .checking)
            }
        }
    }
}

private struct UpdateRow: View {
    let update: AppUpdate
    let store: UpdaterStore

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: update.appPath))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: update.name).font(.headline)
                Text(verbatim: "\(update.installedVersion) → \(update.availableVersion)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let message = store.messages[update.id] {
                    Text(verbatim: message).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            source
            if store.upgrading.contains(update.id) {
                ProgressView().controlSize(.small)
            } else {
                Button(buttonTitle) { Task { await store.update(update) } }
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var source: some View {
        switch update.source {
        case .sparkle: Badge(title: "Built-in updater", color: .secondary)
        case .homebrew: Badge(title: "Homebrew", color: .orange)
        case .appStore: Badge(title: "App Store", color: .blue)
        }
    }

    private var buttonTitle: LocalizedStringKey {
        switch update.source {
        case .homebrew: "Update"
        case .sparkle: "Open App"
        case .appStore: "Open App Store"
        }
    }
}
