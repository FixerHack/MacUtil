import CleanerCore
import SwiftUI

struct DuplicatesView: View {
    @Bindable var store: DuplicatesStore
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Duplicates")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Task { await store.chooseFolder() }
            } label: {
                Label {
                    ScanTargetName(url: store.folder)
                } icon: {
                    Image(systemName: "folder")
                }
            }
            .help("Choose a folder to search")
            Picker("Minimum size", selection: $store.minimumSize) {
                ForEach(DuplicatesStore.MinimumSize.allCases) { size in
                    Text("Over \(size.rawValue.formatted(.byteCount(style: .file)))").tag(size)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            if store.isSearching {
                Button("Stop") { store.cancel() }
            } else {
                Button("Find Duplicates", systemImage: "magnifyingglass") {
                    Task { await store.search() }
                }
                .prominentButton()
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .idle:
            ContentUnavailableView {
                Label("Duplicates", systemImage: "doc.on.doc")
            } description: {
                Text(
                    "Finds files with exactly the same contents. Copies made by Finder on APFS share disk space, so MacUtil shows how much you really free."
                )
            } actions: {
                Button("Find Duplicates") { Task { await store.search() } }
                    .prominentButton()
                    .controlSize(.large)
            }
        case .searching:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                switch store.progress.stage {
                case .scanning:
                    Text("Looking at \(store.progress.filesScanned.formatted()) files…")
                case .comparing, .done:
                    Text(
                        "Comparing \(store.progress.hashed.formatted()) of \(store.progress.candidates.formatted()) candidates…"
                    )
                }
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .removing:
            BusyView(title: "Moving to Trash…")
        case let .done(result):
            CleanupResultView(result: result) {
                Task { await store.undo(result) }
            } done: {
                Task { await store.search() }
            }
        case .ready where store.groups.isEmpty:
            ContentUnavailableView("No duplicates found", systemImage: "checkmark.circle")
        case .ready:
            groupList
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }

    private var groupList: some View {
        List {
            ForEach(store.groups) { group in
                Section {
                    ForEach(group.files) { file in
                        DuplicateRow(
                            file: file,
                            isSelected: store.selection.contains(file.id),
                            canSelect: store.canSelect(file, in: group)
                        ) {
                            store.toggle(file, in: group)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: group.kind.symbol)
                            .foregroundStyle(group.kind.color)
                        Text(verbatim: group.files.first?.name ?? "")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(group.files.count) copies × \(group.size.formatted(.byteCount(style: .file)))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Frees \(group.reclaimableSize.formatted(.byteCount(style: .file)))")
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Text(
                "\(store.groups.count) groups · up to \(store.reclaimableSize.formatted(.byteCount(style: .file))) can be freed"
            )
            .foregroundStyle(.secondary)
            Spacer()
            Menu("Auto-select") {
                Button("Keep the oldest copy") { store.select(.keepOldest) }
                Button("Keep the newest copy") { store.select(.keepNewest) }
                Button("Keep the copy with the shortest path") { store.select(.keepShortestPath) }
                Divider()
                Button("Deselect All") { store.selection = [] }
            }
            .fixedSize()
            Text(
                "Selected \(store.selection.count) · frees \(store.selectedFreedSpace.formatted(.byteCount(style: .file)))"
            )
            .monospacedDigit()
            .font(.headline)
            Button("Move to Trash…") { confirming = true }
                .prominentButton()
                .disabled(store.selection.isEmpty)
        }
        .controlSize(.large)
        .confirmationDialog("Move \(store.selection.count) duplicates to the Trash?", isPresented: $confirming) {
            Button("Move to Trash") { Task { await store.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("At least one copy of every file stays. You can restore the removed copies from the Trash.")
        }
    }
}

private struct DuplicateRow: View {
    let file: DuplicateFile
    let isSelected: Bool
    let canSelect: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CheckButton(state: isSelected ? .all : .none, isEnabled: canSelect, action: toggle)
                .help(canSelect ? "Select this copy for removal" : "The last copy always stays")
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: FinderActions.abbreviate(file.directory))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Modified \(file.modificationDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if file.privateSize == 0 {
                Badge(title: "Shares space", color: .blue)
                    .help("An APFS clone: it shares disk space with another copy.")
            }
            Spacer()
        }
        .contextMenu {
            Button("Show in Finder", systemImage: "folder") { FinderActions.reveal([file.path]) }
            Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(URL(filePath: file.path)) }
        }
    }
}
