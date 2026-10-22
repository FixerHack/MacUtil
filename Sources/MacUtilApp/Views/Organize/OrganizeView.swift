import CleanerCore
import SwiftUI

/// Folders kept in order by rules, with the plan shown before anything moves.
struct OrganizeView: View {
    @Bindable var store: OrganizeStore

    var body: some View {
        Group {
            if store.folders.isEmpty {
                empty
            } else {
                HSplitView {
                    folderList.frame(minWidth: 200, idealWidth: 240, maxWidth: 340)
                    detail.frame(minWidth: 430, maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Keep Folders Tidy")
        .task { store.load() }
        .toolbar {
            ToolbarItem {
                Button("Add Folder…", systemImage: "plus") { store.addFolder() }
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Keep Folders Tidy", systemImage: "folder.badge.gearshape")
        } description: {
            Text("Rules file what lands in a folder: pictures to one place, installers to another. Nothing moves until you have seen the whole plan.")
        } actions: {
            Button("Add Folder…") { store.addFolder() }
                .prominentButton()
                .controlSize(.large)
        }
    }

    private var folderList: some View {
        List(selection: $store.selection) {
            ForEach(store.folders) { folder in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: folder.name).lineLimit(1)
                    Text(folder.organizesAutomatically ? "Sorts itself" : "By hand")
                        .font(.caption)
                        .foregroundStyle(folder.organizesAutomatically ? Color.accentColor : .secondary)
                }
                .tag(folder.id)
                .contextMenu {
                    Button("Stop Watching", role: .destructive) { store.removeFolder(folder) }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let folder = store.current {
            VStack(spacing: 0) { content(folder) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Pick a folder", systemImage: "folder")
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func content(_ folder: WatchedFolder) -> some View {
        switch store.phase {
        case .planning:
            BusyView(title: "Working out what goes where…")
        case .working:
            BusyView(title: "Filing…")
        case let .done(result):
            OrganizeResultView(result: result) { Task { await store.undoLast() } } done: { store.finish() }
        case .preview:
            preview(folder)
        case .idle:
            RulesEditor(store: store, folder: folder)
        }
    }

    private func preview(_ folder: WatchedFolder) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(store.plan.count) files would move")
                    .font(.headline)
                Spacer()
                Button("Back to Rules") { store.finish() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()

            if store.plan.isEmpty {
                ContentUnavailableView(
                    "Nothing to file", systemImage: "checkmark.circle",
                    description: Text("Everything in \(folder.name) is already where the rules want it.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.planByFolder, id: \.folder) { group in
                        Section {
                            ForEach(group.moves) { move in
                                HStack(spacing: 8) {
                                    Text(verbatim: move.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if move.wasRenamed {
                                        Text("renamed to \(move.newName)")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                    Spacer()
                                    Text(verbatim: move.size.formatted(.byteCount(style: .file)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        } header: {
                            Label(group.folder, systemImage: "folder")
                                .font(.callout.weight(.semibold))
                        }
                    }
                }
                .listStyle(.inset)
                Divider()
                HStack {
                    Spacer()
                    Button("File \(store.plan.count) Files") { Task { await store.organize() } }
                        .prominentButton()
                        .controlSize(.large)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }
}

/// What happened, with a way back.
private struct OrganizeResultView: View {
    let result: OrganizeResult
    let undo: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(result.failures.isEmpty ? Color.green : .orange)
            Text("\(result.moved.count) files filed")
                .font(.title2.weight(.semibold))
            if !result.failures.isEmpty {
                Text("\(result.failures.count) could not be moved")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Put Everything Back") { undo() }
                    .disabled(result.moved.isEmpty)
                Button("Done") { done() }
                    .prominentButton()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
