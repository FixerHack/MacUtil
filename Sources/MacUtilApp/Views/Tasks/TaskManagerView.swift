import CleanerCore
import SwiftUI

/// Everything running right now: what it costs, and what you can do about it.
struct TaskManagerView: View {
    @Bindable var store: TaskManagerStore
    @State private var confirmingForceQuit: TaskProcess?

    var body: some View {
        VStack(spacing: 0) {
            SystemLoadBar(load: store.load)
            Divider()
            controls
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            if let error = store.lastError {
                Text(verbatim: error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            Divider()
            HSplitView {
                processList
                    .frame(minWidth: 420)
                if let selected = store.selected {
                    ProcessDetails(process: selected, store: store)
                        .frame(minWidth: 280, idealWidth: 320)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Task Manager")
        .task {
            store.start()
            await store.refresh()
        }
        .onDisappear { store.stop() }
        .confirmationDialog(
            "Force quit \(confirmingForceQuit?.name ?? "")?",
            isPresented: Binding(get: { confirmingForceQuit != nil }, set: { if !$0 { confirmingForceQuit = nil } })
        ) {
            Button("Force Quit", role: .destructive) {
                if let process = confirmingForceQuit {
                    Task { await store.quit(process, force: true) }
                }
                confirmingForceQuit = nil
            }
            Button("Cancel", role: .cancel) { confirmingForceQuit = nil }
        } message: {
            Text("The program stops at once. Anything it has not saved is lost.")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TextField("Search", text: $store.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Picker("Show", selection: $store.filter) {
                Text("All").tag(TaskManagerStore.Filter.all)
                Text("Mine").tag(TaskManagerStore.Filter.mine)
                Text("Apps").tag(TaskManagerStore.Filter.apps)
                Text("Busy").tag(TaskManagerStore.Filter.busy)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("Sort by", selection: $store.sortBy) {
                Text("Processor").tag(TaskManagerStore.Column.cpu)
                Text("Memory").tag(TaskManagerStore.Column.memory)
                Text("Disk").tag(TaskManagerStore.Column.disk)
                Text("Name").tag(TaskManagerStore.Column.name)
                Text("PID").tag(TaskManagerStore.Column.pid)
            }
            .fixedSize()
            Spacer()
            Text("\(store.visible.count) of \(store.processes.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var processList: some View {
        List(selection: $store.selection) {
            ForEach(store.visible) { process in
                ProcessRow(process: process, store: store, forceQuit: { confirmingForceQuit = $0 })
                    .tag(process.pid)
            }
        }
        .listStyle(.inset)
        .onChange(of: store.selection) { _, new in
            guard let new, let process = store.processes.first(where: { $0.pid == new }) else { return }
            Task { await store.loadDetails(for: process) }
        }
    }
}

/// The strip along the top: cores, memory, swap and disk traffic.
private struct SystemLoadBar: View {
    let load: SystemLoad

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Processor").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(Array(load.cores.enumerated()), id: \.offset) { _, core in
                        Capsule()
                            .fill(core > 0.85 ? Color.orange : Color.accentColor)
                            .frame(width: 8, height: max(3, 26 * core))
                            .frame(height: 26, alignment: .bottom)
                    }
                }
                Text("\(Int((load.cpu * 100).rounded()))% · \(load.cores.count) cores")
                    .font(.callout).monospacedDigit()
            }
            if let memory = load.memory {
                meter(
                    title: "Memory",
                    detail: String(
                        localized: "\(memory.used.formatted(.byteCount(style: .memory))) of \(memory.total.formatted(.byteCount(style: .memory)))"
                    ),
                    fraction: memory.usedFraction,
                    note: String(localized: "Pressure \(Int((load.memoryPressure * 100).rounded()))%")
                )
            }
            if load.swapTotal > 0 {
                meter(
                    title: "Swap",
                    detail: load.swapUsed.formatted(.byteCount(style: .memory)),
                    fraction: Double(load.swapUsed) / Double(load.swapTotal),
                    note: nil
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Disk").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: "↓ \(Int64(load.diskRead).formatted(.byteCount(style: .file)))/s")
                    .font(.callout).monospacedDigit()
                Text(verbatim: "↑ \(Int64(load.diskWritten).formatted(.byteCount(style: .file)))/s")
                    .font(.callout).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Load").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: load.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                    .font(.callout).monospacedDigit()
                Text("\(load.processCount) processes · \(load.threadCount) threads")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func meter(title: LocalizedStringKey, detail: String, fraction: Double, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Gauge(value: min(max(fraction, 0), 1)) {}
                .gaugeStyle(.linearCapacity)
                .tint(fraction > 0.85 ? .orange : .accentColor)
                .frame(width: 130)
            Text(verbatim: note.map { "\(detail) · \($0)" } ?? detail)
                .font(.callout).monospacedDigit()
        }
    }
}

private struct ProcessRow: View {
    let process: TaskProcess
    let store: TaskManagerStore
    let forceQuit: (TaskProcess) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let bundle = process.appBundlePath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: bundle))
                    .resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "terminal")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: process.name).lineLimit(1).truncationMode(.middle)
                    if process.state == .stopped {
                        Badge(title: "Paused", color: .orange)
                    }
                }
                Text(verbatim: "\(process.pid) · \(process.user)")
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            Spacer(minLength: 8)
            CPUHistory(samples: store.history[process.pid] ?? [])
            Text(verbatim: String(format: "%.1f%%", process.cpu))
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
                .foregroundStyle(process.cpu > 50 ? .orange : .primary)
            Text(verbatim: process.memory.formatted(.byteCount(style: .memory)))
                .monospacedDigit()
                .frame(width: 74, alignment: .trailing)
            if store.busyPIDs.contains(process.pid) {
                ProgressView().controlSize(.small).frame(width: 18)
            } else {
                Menu {
                    Button("Quit") { Task { await store.quit(process, force: false) } }
                    Button("Force Quit", role: .destructive) { forceQuit(process) }
                    Divider()
                    if process.state == .stopped {
                        Button("Resume") { Task { await store.setPaused(false, process) } }
                    } else {
                        Button("Pause") { Task { await store.setPaused(true, process) } }
                    }
                    Menu("Priority") {
                        Button("Higher") { Task { await store.setPriority(-5, for: process) } }
                        Button("Normal") { Task { await store.setPriority(0, for: process) } }
                        Button("Lower") { Task { await store.setPriority(10, for: process) } }
                    }
                    Divider()
                    Button("Save a Sample…") { Task { await store.saveSample(of: process) } }
                    Button("Show in Finder") { FinderActions.reveal([process.path]) }
                    Button("Copy Path") { FinderActions.copy([process.path]) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }
}

/// A minute of processor use, drawn small enough to sit in a row.
private struct CPUHistory: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geometry in
            let peak = max(samples.max() ?? 1, 10)
            Path { path in
                for (index, sample) in samples.enumerated() {
                    let x = geometry.size.width * Double(index) / Double(max(samples.count - 1, 1))
                    let y = geometry.size.height * (1 - min(sample / peak, 1))
                    index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color.accentColor.opacity(0.8), lineWidth: 1.5)
        }
        .frame(width: 54, height: 18)
    }
}

private struct ProcessDetails: View {
    let process: TaskProcess
    let store: TaskManagerStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    if let bundle = process.appBundlePath {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: bundle))
                            .resizable().frame(width: 32, height: 32)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: process.name).font(.headline)
                        Text(verbatim: FinderActions.abbreviate(process.path))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Processor", String(format: "%.1f%%", process.cpu))
                    row("Memory", process.memory.formatted(.byteCount(style: .memory)))
                    row("Threads", "\(process.threads)")
                    row("Read from disk", process.diskRead.formatted(.byteCount(style: .file)))
                    row("Written to disk", process.diskWritten.formatted(.byteCount(style: .file)))
                    row("Wakeups", "\(process.wakeups)")
                    row("Priority", "\(process.niceness)")
                    row("User", process.user)
                    row("PID", "\(process.pid) · parent \(process.parentPID)")
                    if let started = process.startedAt {
                        row("Started", started.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.callout)

                if let arguments = store.details?.arguments, !arguments.isEmpty {
                    section("Command") {
                        Text(verbatim: arguments)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                let children = store.children(of: process)
                if !children.isEmpty {
                    section("Helpers") {
                        ForEach(children) { child in
                            HStack {
                                Text(verbatim: child.name).lineLimit(1)
                                Spacer()
                                Text(verbatim: String(format: "%.1f%%", child.cpu)).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }

                if let files = store.details?.openFiles, !files.isEmpty {
                    section("Open files: \(files.count)") {
                        ForEach(files.prefix(40), id: \.self) { file in
                            Text(verbatim: FinderActions.abbreviate(file))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(verbatim: value).monospacedDigit()
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
        }
    }
}
