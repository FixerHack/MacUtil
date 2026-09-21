import CleanerCore
import SwiftUI

struct TrashBinsView: View {
    let store: TrashStore
    @State private var confirmingEmpty = false

    var body: some View {
        VStack(spacing: 0) {
            FullDiskAccessHint()
            content
        }
        .navigationTitle("Trash Bins")
        .toolbar {
            ToolbarItem {
                Button("Rescan", systemImage: "arrow.clockwise") {
                    Task { await store.scan() }
                }
            }
        }
        .task {
            if case .idle = store.phase {
                await store.scan()
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .idle, .scanning:
            BusyView(title: "Checking the Trash…")
        case .emptying:
            BusyView(title: "Emptying the Trash…")
        case let .done(result):
            CleanupResultView(result: result) {
                Task { await store.scan() }
            }
        case .ready:
            List(store.bins) { bin in
                HStack(spacing: 12) {
                    Image(systemName: bin.items.isEmpty ? "trash" : "trash.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        if let volume = bin.volumeName {
                            Text("Trash on \(volume)")
                                .font(.headline)
                        } else {
                            Text("Trash")
                                .font(.headline)
                        }
                        if bin.isAccessDenied {
                            Text("No access. Grant Full Disk Access to see what is inside.")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        } else {
                            Text("\(bin.items.count) items")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !bin.isAccessDenied {
                        Text(verbatim: bin.size.formatted(.byteCount(style: .file)))
                            .monospacedDigit()
                            .font(.headline)
                    }
                }
                .padding(.vertical, 6)
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Button("Show Trash in Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash"))
                }
                Spacer()
                Button("Empty Trash…", role: .destructive) { confirmingEmpty = true }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(store.itemCount == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .confirmationDialog(
                "Permanently delete \(store.itemCount) items?",
                isPresented: $confirmingEmpty
            ) {
                Button("Empty Trash", role: .destructive) { Task { await store.empty() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This frees \(store.totalSize.formatted(.byteCount(style: .file))) and cannot be undone.")
            }
        }
    }
}
