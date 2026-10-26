import CleanerCore
import SwiftUI

/// What has been copied, so the thing copied three things ago is not lost.
struct ClipboardView: View {
    @Bindable var store: ClipboardStore
    @State private var confirmingForget = false

    var body: some View {
        VStack(spacing: 0) {
            if store.isEnabled {
                header
                Divider()
                list
            } else {
                invitation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Clipboard History")
        .task { store.start() }
        .toolbar {
            ToolbarItem {
                Button("Forget Everything", systemImage: "trash") { confirmingForget = true }
                    .disabled(store.entries.isEmpty)
            }
        }
        .confirmationDialog("Forget everything copied?", isPresented: $confirmingForget) {
            Button("Forget Everything", role: .destructive) { store.forgetEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The list goes, and the file it is kept in with it.")
        }
    }

    private var invitation: some View {
        ContentUnavailableView {
            Label("Clipboard History", systemImage: "doc.on.clipboard")
        } description: {
            Text("macOS keeps only the last thing you copied. With this on, UniMacHub remembers the last 100, so you can reach back for one.\n\nAnything a password manager marks as concealed is skipped, and the list is kept on this Mac alone.")
        } actions: {
            Button("Start Remembering") { store.setEnabled(true) }
                .prominentButton()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Search", text: $store.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Text("\(store.entries.count) kept")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Toggle("Remember what I copy", isOn: Binding(
                get: { store.isEnabled }, set: { store.setEnabled($0) }
            ))
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var list: some View {
        if store.shown.isEmpty {
            ContentUnavailableView(
                store.entries.isEmpty ? "Nothing copied yet" : "Nothing matches",
                systemImage: store.entries.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                description: Text(store.entries.isEmpty
                    ? "Copy something and it appears here."
                    : "Try fewer words.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.shown) { entry in
                    row(entry)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        Button {
            store.copy(entry)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol(for: entry.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: entry.preview)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        if let source = entry.source {
                            Text(verbatim: source)
                        }
                        Text(verbatim: entry.copiedAt.formatted(date: .omitted, time: .shortened))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Copy this again")
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { store.copy(entry) }
            Button("Forget This", systemImage: "xmark", role: .destructive) { store.remove(entry) }
        }
    }

    private func symbol(for kind: ClipboardEntry.Kind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .url: "link"
        case .file: "doc"
        }
    }
}
