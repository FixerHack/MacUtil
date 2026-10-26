import CleanerCore
import SwiftUI

/// What build tools leave inside project folders.
struct ProjectBuildsView: View {
    @Bindable var store: ProjectBuildsStore
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Project Build Files")
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
                Label("Project Build Files", systemImage: "shippingbox")
            } description: {
                Text("Dependencies and build output live inside your project folders, where no cache cleaner looks. One command brings any of it back.")
            } actions: {
                Button("Look Through Projects") { Task { await store.scan() } }
                    .prominentButton()
                    .controlSize(.large)
            }
        case .scanning:
            BusyView(title: "Looking through projects…")
        case .cleaning:
            BusyView(title: "Moving to Trash…")
        case let .done(result):
            CleanupResultView(result: result) {
                Task { await store.finish() }
            } done: {
                Task { await store.finish() }
            }
        case .ready where store.artifacts.isEmpty:
            ContentUnavailableView(
                "No build output found", systemImage: "checkmark.circle",
                description: Text("Nothing in Developer, Projects, Code, Documents or on the Desktop.")
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
        HStack {
            Text("\(store.artifacts.count) folders · \(store.totalSize.formatted(.byteCount(style: .file)))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if store.excluded.isEmpty {
                Text("Only what one command rebuilds is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(store.excluded.count) folders now stay out of Time Machine.")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var list: some View {
        List {
            ForEach(store.byProject, id: \.path) { group in
                Section {
                    ForEach(group.artifacts) { artifact in
                        HStack(spacing: 10) {
                            CheckButton(
                                state: store.selection.contains(artifact.id) ? .all : .none, isEnabled: true
                            ) { store.toggle(artifact) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: artifact.kind)
                                Text(artifact.tool)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !artifact.isSafe {
                                Text("Check first")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.orange.opacity(0.2), in: .capsule)
                            }
                            Spacer()
                            Text(verbatim: artifact.size.formatted(.byteCount(style: .file)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Button {
                            store.toggle(project: group.path)
                        } label: {
                            Text(verbatim: group.project).font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        if let modified = group.artifacts.first?.projectModified {
                            Text("last touched \(modified.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(verbatim: group.artifacts.reduce(0) { $0 + $1.size }
                            .formatted(.byteCount(style: .file)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Text("Selected \(store.selection.count) · \(store.selectedSize.formatted(.byteCount(style: .file)))")
                .monospacedDigit()
                .font(.headline)
            Spacer()
            Button("Keep Out of Backups") { Task { await store.excludeFromBackups() } }
                .controlSize(.large)
                .disabled(store.selection.isEmpty)
                .help("Leaves the folders where they are and stops Time Machine copying them.")
            Button("Move to Trash…") { confirming = true }
                .prominentButton()
                .controlSize(.large)
                .disabled(store.selection.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .confirmationDialog(
            "Move \(store.selection.count) folders to the Trash?", isPresented: $confirming
        ) {
            Button("Move to Trash") { Task { await store.clean() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your source code is not touched. The next build or install puts these back.")
        }
    }
}
