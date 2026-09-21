import CleanerCore
import SwiftUI

/// System Junk and Developer Junk: scan, review by category, clean, undo.
struct JunkView: View {
    let module: Module
    let store: JunkStore
    @State private var confirmingClean = false

    var body: some View {
        VStack(spacing: 0) {
            FullDiskAccessHint()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(module.title)
        .toolbar {
            ToolbarItem {
                Button("Rescan", systemImage: "arrow.clockwise") {
                    Task { await store.scan() }
                }
                .disabled(store.isBusy)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .idle:
            ContentUnavailableView {
                Label(module.title, systemImage: module.symbol)
            } description: {
                Text(module.summary)
            } actions: {
                Button("Scan") { Task { await store.scan() } }
                    .prominentButton()
                    .controlSize(.large)
            }
        case .scanning:
            BusyView(title: "Looking for junk…")
        case .cleaning:
            BusyView(title: "Cleaning…")
        case .ready where store.categories.isEmpty:
            ContentUnavailableView {
                Label("Nothing to clean", systemImage: "checkmark.circle")
            } description: {
                Text("No junk found in this category.")
            }
        case .ready:
            JunkList(store: store)
            Divider()
            footer
        case let .done(result):
            CleanupResultView(result: result) {
                Task { await store.undo(result) }
            } done: {
                Task { await store.scan() }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Found \(store.totalSize.formatted(.byteCount(style: .file)))")
                .foregroundStyle(.secondary)
            Spacer()
            Text("Selected \(store.selectedSize.formatted(.byteCount(style: .file)))")
                .monospacedDigit()
                .font(.headline)
            Button("Clean…") { confirmingClean = true }
                .prominentButton()
                .controlSize(.large)
                .disabled(store.selection.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .confirmationDialog(
            "Clean \(store.selectedSize.formatted(.byteCount(style: .file)))?",
            isPresented: $confirmingClean
        ) {
            Button("Move to Trash") { Task { await store.clean(mode: .trash) } }
            Button("Delete Permanently", role: .destructive) { Task { await store.clean(mode: .delete) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Items moved to the Trash can be restored until you empty it. Deleting permanently frees the space right away and cannot be undone."
            )
        }
    }
}

private struct JunkList: View {
    @Bindable var store: JunkStore

    var body: some View {
        List {
            ForEach(store.categories) { category in
                DisclosureGroup(isExpanded: Binding(
                    get: { store.expanded.contains(category.id) },
                    set: { expanded in
                        if expanded {
                            store.expanded.insert(category.id)
                        } else {
                            store.expanded.remove(category.id)
                        }
                    }
                )) {
                    ForEach(category.items) { item in
                        JunkItemRow(item: item, isSelected: store.selection.contains(item.id)) {
                            store.toggle(item)
                        }
                    }
                } label: {
                    JunkCategoryRow(category: category, state: store.state(of: category)) {
                        store.toggle(category)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct JunkCategoryRow: View {
    let category: JunkCategory
    let state: JunkStore.SelectionState
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CheckButton(state: state, isEnabled: category.removableSize > 0, action: toggle)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(category.rule.title)
                        .font(.headline)
                    if category.rule.safety == .review {
                        Text("Review")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: .capsule)
                            .foregroundStyle(.orange)
                    }
                    if category.removableSize == 0 {
                        Label("App is running", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Quit the app to clean this item")
                    }
                }
                Text(category.rule.details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(verbatim: category.size.formatted(.byteCount(style: .file)))
                .monospacedDigit()
                .font(.headline)
        }
        .padding(.vertical, 4)
    }
}

private struct JunkItemRow: View {
    let item: JunkItem
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CheckButton(state: isSelected ? .all : .none, isEnabled: !item.isInUse, action: toggle)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: FinderActions.abbreviate(item.path))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if item.isInUse {
                Label("App is running", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Quit the app to clean this item")
            }
            Spacer(minLength: 12)
            Text(verbatim: item.size.formatted(.byteCount(style: .file)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .opacity(item.isInUse ? 0.6 : 1)
        .contextMenu {
            Button("Show in Finder", systemImage: "folder") { FinderActions.reveal([item.path]) }
            Button("Copy Path", systemImage: "doc.on.clipboard") { FinderActions.copy([item.path]) }
        }
    }
}

/// A checkbox with a mixed state for partially selected categories.
struct CheckButton: View {
    let state: JunkStore.SelectionState
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var symbol: String {
        switch state {
        case .all: "checkmark.square.fill"
        case .some: "minus.square.fill"
        case .none: "square"
        }
    }
}

struct BusyView: View {
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.title2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Summary after a cleanup, with undo while the items are still in the Trash.
struct CleanupResultView: View {
    let result: CleanupResult
    var undo: (() -> Void)?
    let done: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(result.failures.isEmpty ? .green : .orange)
            Text("Freed \(result.freedBytes.formatted(.byteCount(style: .file)))")
                .font(.largeTitle.bold())
            if result.mode == .trash, !result.removed.isEmpty {
                Text("The items are in the Trash. Empty it to get the space back.")
                    .foregroundStyle(.secondary)
            }
            if !result.failures.isEmpty {
                GroupBox {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(result.failures, id: \.path) { failure in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: FinderActions.abbreviate(failure.path))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(verbatim: failure.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                } label: {
                    Text("\(result.failures.count) items could not be removed")
                }
                .frame(maxWidth: 520)
            }
            HStack {
                if result.canUndo, let undo {
                    Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                        .glassButton()
                }
                Button("Done", action: done)
                    .prominentButton()
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One-line reminder shown on cleaning screens while Full Disk Access is missing.
struct FullDiskAccessHint: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.fullDiskAccess == .denied {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.orange)
                Text("Without Full Disk Access some locations are skipped.")
                    .font(.callout)
                Spacer()
                Button("Show Me How") {
                    state.showsPermissionsGuide = true
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.08))
            Divider()
        }
    }
}
