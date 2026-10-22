import CleanerCore
import SwiftUI

/// Removes the half of each universal app that this Mac never runs.
struct SlimmingView: View {
    @Bindable var store: SlimmingStore
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Slim Down Apps")
        .toolbar {
            ToolbarItem {
                Button("Rescan", systemImage: "arrow.clockwise") { Task { await store.scan() } }
                    .disabled(store.isBusy)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .idle:
            ContentUnavailableView {
                Label("Slim Down Apps", systemImage: "arrow.down.right.and.arrow.up.left")
            } description: {
                Text("A universal app carries a complete copy of itself for Apple Silicon and another for Intel. Your Mac runs one of them, and the other takes up space for nothing.")
            } actions: {
                Button("Look for Universal Apps") { Task { await store.scan() } }
                    .prominentButton()
                    .controlSize(.large)
            }
        case .scanning:
            BusyView(title: "Reading app binaries…")
        case .working:
            BusyView(title: store.current.map { "Slimming \($0)…" } ?? "Slimming…")
        case .ready where store.apps.isEmpty:
            ContentUnavailableView(
                "Nothing to slim down", systemImage: "checkmark.circle",
                description: Text("Every app here is already built for this Mac alone.")
            )
        case .ready:
            header
            Divider()
            list
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(store.apps.count) apps · \(store.totalSavings.formatted(.byteCount(style: .file))) to free")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Select All") { store.selectAll() }
                    .buttonStyle(.link)
            }
            if !store.outcomes.isEmpty {
                outcomes
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var outcomes: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Freed \(store.freedSoFar.formatted(.byteCount(style: .file)))")
                .font(.callout.weight(.semibold))
            ForEach(store.outcomes) { outcome in
                if let problem = outcome.problem {
                    Text("\(outcome.name): \(Text(problem))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(store.apps) { app in
                let allowed = store.canSlim(app)
                HStack(spacing: 10) {
                    CheckButton(
                        state: store.selection.contains(app.id) ? .all : .none, isEnabled: allowed
                    ) { store.toggle(app) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: app.name).lineLimit(1)
                        HStack(spacing: 6) {
                            if let version = app.version {
                                Text(verbatim: version)
                            }
                            Text("\(app.binaryCount) binaries")
                            if app.isAppStore {
                                Text("App Store")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if !allowed {
                        Text(store.isRunning(app) ? "Running" : "Needs an administrator")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: .capsule)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("−\(app.savings.formatted(.byteCount(style: .file)))")
                            .monospacedDigit()
                        Text(verbatim: app.size.formatted(.byteCount(style: .file)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Text("Selected \(store.selection.count) · \(store.selectedSavings.formatted(.byteCount(style: .file)))")
                .monospacedDigit()
                .font(.headline)
            Spacer()
            Button("Slim Down…") { confirming = true }
                .prominentButton()
                .controlSize(.large)
                .disabled(store.selection.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .confirmationDialog(
            "Slim down \(store.selection.count) apps?", isPresented: $confirming
        ) {
            Button("Slim Down", role: .destructive) { Task { await store.slim() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone: getting the removed code back means reinstalling the app, and an update will bring it back anyway. Leave out anything you open with Rosetta, which needs the Intel copy. Each app is checked afterwards and put back untouched if its signature no longer holds.")
        }
    }
}
