import CleanerCore
import SwiftUI

/// Pictures, videos and documents messaging apps have downloaded and kept.
struct MessengerView: View {
    @Bindable var store: MessengerStore
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Messenger Downloads")
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
                Label("Messenger Downloads", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Telegram, WhatsApp, Viber and the rest keep every picture and video you open. Nothing here is unique: the chat still has it.")
            } actions: {
                Button("Look for Files") { Task { await store.scan() } }
                    .prominentButton()
                    .controlSize(.large)
            }
        case .scanning:
            BusyView(title: "Looking through messaging apps…")
        case .cleaning:
            BusyView(title: "Moving to Trash…")
        case let .done(result):
            CleanupResultView(result: result) {
                Task { await store.finish() }
            } done: {
                Task { await store.finish() }
            }
        case .ready where store.files.isEmpty:
            ContentUnavailableView(
                "Nothing older than that", systemImage: "checkmark.circle",
                description: Text("Try a shorter age to see more.")
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
        HStack(spacing: 12) {
            Picker("Older than", selection: $store.age) {
                Text("Everything").tag(MessengerStore.Age.everything)
                Text("A week").tag(MessengerStore.Age.week)
                Text("A month").tag(MessengerStore.Age.month)
                Text("Three months").tag(MessengerStore.Age.threeMonths)
                Text("A year").tag(MessengerStore.Age.year)
            }
            .fixedSize()
            .onChange(of: store.age) { _, _ in Task { await store.scan() } }
            Spacer()
            Text("\(store.files.count) files · \(store.totalSize.formatted(.byteCount(style: .file)))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var list: some View {
        List {
            ForEach(store.byApp, id: \.app) { group in
                Section {
                    ForEach(group.files.prefix(300)) { file in
                        HStack(spacing: 10) {
                            CheckButton(
                                state: store.selection.contains(file.id) ? .all : .none,
                                isEnabled: true
                            ) { store.toggle(file) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: file.name).lineLimit(1).truncationMode(.middle)
                                Text(verbatim: file.modified?.formatted(date: .abbreviated, time: .omitted) ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(verbatim: file.size.formatted(.byteCount(style: .file)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                    }
                    if group.files.count > 300 {
                        Text("and \(group.files.count - 300) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Button {
                            store.toggle(app: group.app)
                        } label: {
                            Text(verbatim: group.app).font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        Text(verbatim: group.files.reduce(0) { $0 + $1.size }.formatted(.byteCount(style: .file)))
                            .foregroundStyle(.secondary)
                        Spacer()
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
            Button("Move to Trash…") { confirming = true }
                .prominentButton()
                .controlSize(.large)
                .disabled(store.selection.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .confirmationDialog(
            "Move \(store.selection.count) files to the Trash?", isPresented: $confirming
        ) {
            Button("Move to Trash") { Task { await store.clean() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The chats keep their copies, so anything needed later can be downloaded again.")
        }
    }
}
