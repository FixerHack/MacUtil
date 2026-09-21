import CleanerCore
import SwiftUI

struct SpaceLensView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            ScanHeader()
            Divider()
            if let result = state.scans.result {
                LensBrowser(root: result.root)
                    .id(result.id)
            } else {
                ScanPlaceholder(module: .spaceLens)
            }
        }
        .navigationTitle("Space Lens")
    }
}

/// Treemap plus list for one folder, with breadcrumb navigation.
private struct LensBrowser: View {
    let root: DirectoryNode
    @State private var current: DirectoryNode?
    @State private var hovered: LensItem.ID?

    var body: some View {
        let node = current ?? root
        let items = LensItem.items(in: node)

        VStack(spacing: 0) {
            Breadcrumb(node: node) { current = $0 }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

            HStack(spacing: 0) {
                Group {
                    if items.isEmpty {
                        ContentUnavailableView("This folder is empty", systemImage: "folder")
                    } else {
                        TreemapView(items: items, hovered: $hovered, open: open)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                LensList(node: node, items: items, hovered: $hovered, open: open)
                    .frame(width: 320)
            }
        }
    }

    private func open(_ item: LensItem) {
        if let directory = item.directory, !directory.directories.isEmpty || !directory.files.isEmpty {
            current = directory
            hovered = nil
        }
    }
}

private struct Breadcrumb: View {
    let node: DirectoryNode
    let select: (DirectoryNode) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button("Up", systemImage: "chevron.up") {
                if let parent = node.parent {
                    select(parent)
                }
            }
            .labelStyle(.iconOnly)
            .disabled(node.parent == nil)
            .keyboardShortcut(.upArrow, modifiers: .command)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(node.lineage.enumerated()), id: \.element.id) { index, ancestor in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            select(ancestor)
                        } label: {
                            Text(verbatim: index == 0 ? FinderActions.abbreviate(ancestor.path) : ancestor.name)
                                .fontWeight(ancestor === node ? .semibold : .regular)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(ancestor === node ? .primary : .secondary)
                    }
                }
            }
            Spacer()
            Text("\(node.allocatedSize.formatted(.byteCount(style: .file))) · \(node.fileCount.formatted()) files")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct LensList: View {
    let node: DirectoryNode
    let items: [LensItem]
    @Binding var hovered: LensItem.ID?
    let open: (LensItem) -> Void

    var body: some View {
        List {
            ForEach(items) { item in
                LensRow(item: item, total: node.allocatedSize, isHovered: hovered == item.id)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            hovered = item.id
                        } else if hovered == item.id {
                            hovered = nil
                        }
                    }
                    .onTapGesture { open(item) }
                    .contextMenu {
                        if let path = item.path {
                            LensItemMenu(item: item, path: path, open: open)
                        }
                    }
            }
            let skipped = node.directories.filter { $0.status != .scanned }
            if !skipped.isEmpty {
                Section("Not scanned") {
                    ForEach(skipped) { directory in
                        SkippedRow(directory: directory)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct LensRow: View {
    let item: LensItem
    let total: Int64
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(item.color)
                    .frame(width: 18)
                name
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(verbatim: item.size.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: total > 0 ? Double(item.size) / Double(total) : 0)
                .progressViewStyle(.linear)
                .tint(item.color)
                .controlSize(.mini)
        }
        .padding(.vertical, 2)
        .listRowBackground(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    @ViewBuilder private var name: some View {
        switch item.content {
        case let .others(count):
            Text("\(count) smaller items")
        default:
            Text(verbatim: item.name)
        }
    }

    private var symbol: String {
        switch item.content {
        case let .directory(node): node.isPackage ? "shippingbox.fill" : "folder.fill"
        case let .file(file): file.kind.symbol
        case .others: "ellipsis.circle"
        }
    }
}

private struct SkippedRow: View {
    let directory: DirectoryNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(verbatim: directory.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            reason
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        switch directory.status {
        case .denied, .unreadable: "lock.fill"
        case .mountPoint: "externaldrive"
        case .dataless: "icloud"
        case .excluded, .scanned: "minus.circle"
        }
    }

    @ViewBuilder private var reason: some View {
        switch directory.status {
        case .denied: Text("No access")
        case .unreadable: Text("Unreadable")
        case .mountPoint: Text("Other volume")
        case .dataless: Text("In iCloud")
        case .excluded, .scanned: Text("Excluded")
        }
    }
}
