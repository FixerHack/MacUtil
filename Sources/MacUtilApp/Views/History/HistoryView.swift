import CleanerCore
import SwiftUI

/// A record of every cleanup, so it is always possible to see what was removed.
struct HistoryView: View {
    @Bindable var store: HistoryStore
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("History")
            .task {
                if !store.hasLoaded { await store.load() }
            }
            .toolbar {
                ToolbarItem {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.load() } }
                        .disabled(store.isLoading)
                }
                ToolbarItem {
                    Button("Clear History", systemImage: "trash") { confirmingClear = true }
                        .disabled(store.isEmpty)
                }
            }
            .confirmationDialog("Clear the history?", isPresented: $confirmingClear) {
                Button("Clear History", role: .destructive) { Task { await store.clear() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only the record goes. Files already removed stay removed, and anything in the Trash stays there.")
            }
    }

    @ViewBuilder private var content: some View {
        if store.isLoading, store.isEmpty {
            BusyView(title: "Reading the history…")
        } else if store.isEmpty {
            ContentUnavailableView {
                Label("Nothing cleaned yet", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Once UniMacHub removes something, it is listed here with the date, the size and every path.")
            }
            .frame(maxWidth: .infinity)
        } else {
            header
            Divider()
            list
        }
    }

    private var header: some View {
        HStack(spacing: 20) {
            total(
                title: "Freed up", value: store.freedBytes.formatted(.byteCount(style: .file)),
                symbol: "internaldrive"
            )
            total(title: "Items removed", value: store.itemCount.formatted(), symbol: "doc")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func total(title: LocalizedStringKey, value: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: value).font(.headline).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(store.days) { day in
                Section {
                    ForEach(day.records) { record in
                        row(record)
                    }
                } header: {
                    HStack {
                        Text(verbatim: day.date.formatted(date: .complete, time: .omitted))
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text(verbatim: day.freedBytes.formatted(.byteCount(style: .file)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder private func row(_ record: HistoryStore.Record) -> some View {
        let entry = record.entry
        let isOpen = store.expanded.contains(record.id)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                store.toggle(record)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: entry.symbol)
                        .foregroundStyle(entry.action == "restore" ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.sourceTitle).lineLimit(1)
                        // A record with nothing removed is one where everything failed;
                        // saying "0 items" would leave that unsaid.
                        if entry.removed.isEmpty, !entry.failures.isEmpty {
                            Text("\(entry.failures.count) could not be removed")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("\(Text(entry.actionTitle)) · \(entry.removed.count) items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(verbatim: entry.freedBytes.formatted(.byteCount(style: .file)))
                            .monospacedDigit()
                        Text(verbatim: entry.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isOpen { details(entry) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func details(_ entry: ActionLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(entry.removed.prefix(200), id: \.path) { item in
                HStack(spacing: 8) {
                    Text(verbatim: item.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Text(verbatim: item.size.formatted(.byteCount(style: .file)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if entry.removed.count > 200 {
                Text("and \(entry.removed.count - 200) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(entry.failures.prefix(50), id: \.path) { failure in
                Text(verbatim: "\(failure.path) — \(failure.reason)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.leading, 30)
        .padding(.bottom, 4)
    }
}
