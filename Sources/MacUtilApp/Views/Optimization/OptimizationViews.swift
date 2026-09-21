import CleanerCore
import SecurityCore
import SwiftUI

// MARK: - Maintenance

struct MaintenanceView: View {
    @Bindable var store: MaintenanceStore

    var body: some View {
        VStack(spacing: 0) {
            List {
                Text(
                    "Fixes for common macOS problems. Tasks with a lock ask for your administrator password once for all of them."
                )
                .foregroundStyle(.secondary)
                ForEach(MaintenanceCatalog.all) { task in
                    MaintenanceRow(task: task, store: store)
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Button("Select All") { store.selection = Set(MaintenanceCatalog.all.map(\.id)) }
                Button("Deselect All") { store.selection = [] }
                Spacer()
                if store.running {
                    ProgressView().controlSize(.small)
                    Text("Running…").foregroundStyle(.secondary)
                }
                Button("Run \(store.selection.count) Tasks", systemImage: "play.fill") {
                    Task { await store.run() }
                }
                .buttonStyle(.glassProminent)
                .disabled(store.selection.isEmpty || store.running)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .navigationTitle("Maintenance")
    }
}

private struct MaintenanceRow: View {
    let task: MaintenanceTask
    let store: MaintenanceStore
    @State private var showsOutput = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CheckButton(state: store.selection.contains(task.id) ? .all : .none, isEnabled: !store.running) {
                if store.selection.contains(task.id) {
                    store.selection.remove(task.id)
                } else {
                    store.selection.insert(task.id)
                }
            }
            Image(systemName: task.symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title).font(.headline)
                    if task.requiresAdmin {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Needs administrator password")
                    }
                }
                Text(task.details).foregroundStyle(.secondary)
                if let result = store.results[task.id] {
                    HStack(spacing: 6) {
                        if result.wasCancelled {
                            Label("Cancelled", systemImage: "xmark.circle").foregroundStyle(.secondary)
                        } else if result.succeeded {
                            Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            if let followUp = task.followUp {
                                Text(followUp).foregroundStyle(.secondary)
                            }
                        } else {
                            Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(showsOutput ? "Hide Output" : "Show Output") { showsOutput.toggle() }
                                .buttonStyle(.link)
                        }
                    }
                    .font(.callout)
                    if showsOutput {
                        Text(verbatim: result.text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.fill.quaternary, in: .rect(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Hidden settings

struct HiddenSettingsView: View {
    let store: HiddenSettingsStore
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                Text(
                    "macOS options without a switch in System Settings. Every change can be undone; \"Default\" restores Apple's setting."
                )
                .foregroundStyle(.secondary)
            }
            ForEach(HiddenSetting.Section.allCases, id: \.self) { section in
                Section(section.title) {
                    ForEach(HiddenSettings.all.filter { $0.section == section }) { setting in
                        HiddenSettingRow(setting: setting, store: store)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Hidden Settings")
        .toolbar {
            ToolbarItem {
                Button("Restore Defaults", systemImage: "arrow.uturn.backward") { confirmingReset = true }
                    .disabled(store.changedCount == 0)
            }
        }
        .confirmationDialog(
            "Restore all \(store.changedCount) changed settings to the macOS defaults?",
            isPresented: $confirmingReset
        ) {
            Button("Restore Defaults") { Task { await store.resetAll() } }
            Button("Cancel", role: .cancel) {}
        }
        .task { store.load() }
    }
}

private struct HiddenSettingRow: View {
    let setting: HiddenSetting
    let store: HiddenSettingsStore

    var body: some View {
        if setting.isToggle {
            Toggle(isOn: Binding(
                get: { store.isOn(setting) },
                set: { on in Task { await store.set(on ? setting.options.first?.value : nil, for: setting) } }
            )) {
                label
            }
            .disabled(store.busy.contains(setting.id))
        } else {
            Picker(selection: Binding(
                get: { store.values[setting.id] },
                set: { value in Task { await store.set(value, for: setting) } }
            )) {
                Text("Default").tag(HiddenSetting.Value?.none)
                ForEach(setting.options, id: \.value) { option in
                    Text(option.title).tag(HiddenSetting.Value?.some(option.value))
                }
            } label: {
                label
            }
            .disabled(store.busy.contains(setting.id))
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(setting.title)
            Text(setting.details)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension HiddenSetting.Section {
    var title: LocalizedStringKey {
        switch self {
        case .finder: "Finder"
        case .dock: "Dock"
        case .screenshots: "Screenshots"
        case .typing: "Typing"
        case .general: "General"
        }
    }
}

// MARK: - Processes

struct ProcessesView: View {
    enum Scope: Hashable {
        case mine, all
    }

    let store: ProcessesStore
    @State private var scope = Scope.mine
    @State private var search = ""
    @State private var selection = Set<RunningProcess.ID>()
    @State private var sortOrder = [KeyPathComparator(\RunningProcess.cpu, order: .reverse)]
    @State private var confirmingForceQuit: RunningProcess?

    private var processes: [RunningProcess] {
        store.processes
            .filter { scope == .all || $0.isOwnedByUser }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    private var selected: RunningProcess? {
        store.processes.first { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let memory = store.memory {
                MemoryBar(memory: memory)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                Divider()
            }
            HStack {
                Picker("Show", selection: $scope) {
                    Text("My processes").tag(Scope.mine)
                    Text("All processes").tag(Scope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Search processes", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                Button("Quit") {
                    if let selected {
                        Task { await store.quit(selected, force: false) }
                    }
                }
                .disabled(selected?.isOwnedByUser != true)
                Button("Force Quit…") { confirmingForceQuit = selected }
                    .disabled(selected?.isOwnedByUser != true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Table(processes, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { process in
                    HStack(spacing: 6) {
                        if let icon = NSRunningApplication(processIdentifier: process.pid)?.icon {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 16)
                        }
                        Text(verbatim: process.name).lineLimit(1)
                    }
                    .help(process.path)
                }
                .width(min: 180, ideal: 260)
                TableColumn("CPU", value: \.cpu) { process in
                    Text(verbatim: String(format: "%.1f %%", process.cpu)).monospacedDigit()
                        .foregroundStyle(process.cpu > 80 ? .orange : .primary)
                }
                .width(min: 60, ideal: 70)
                TableColumn("Memory", value: \.memory) { process in
                    Text(verbatim: process.memory.formatted(.byteCount(style: .memory))).monospacedDigit()
                }
                .width(min: 80, ideal: 90)
                TableColumn("PID", value: \.pid) { process in
                    Text(verbatim: "\(process.pid)").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 60)
                TableColumn("User", value: \.user) { process in
                    Text(verbatim: process.user).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 90)
            }
            .contextMenu(forSelectionType: RunningProcess.ID.self) { pids in
                if let process = store.processes.first(where: { pids.contains($0.id) }) {
                    Button("Quit") { Task { await store.quit(process, force: false) } }
                        .disabled(!process.isOwnedByUser)
                    Button("Force Quit…") { confirmingForceQuit = process }
                        .disabled(!process.isOwnedByUser)
                    Divider()
                    Button("Show in Finder", systemImage: "folder") { FinderActions.reveal([process.path]) }
                }
            }
        }
        .navigationTitle("Processes")
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .confirmationDialog(
            "Force quit \(confirmingForceQuit?.name ?? "")?",
            isPresented: Binding(get: { confirmingForceQuit != nil }, set: {
                if !$0 {
                    confirmingForceQuit = nil
                }
            }),
            presenting: confirmingForceQuit
        ) { process in
            Button("Force Quit", role: .destructive) { Task { await store.quit(process, force: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Unsaved changes in this program will be lost.")
        }
    }
}

private struct MemoryBar: View {
    let memory: MemoryStats

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Memory").font(.headline)
                Spacer()
                Text(
                    "\(memory.used.formatted(.byteCount(style: .memory))) of \(memory.total.formatted(.byteCount(style: .memory))) used"
                )
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Gauge(value: memory.usedFraction) {}
                .gaugeStyle(.linearCapacity)
                .tint(memory.usedFraction > 0.85 ? .orange : .accentColor)
            HStack(spacing: 16) {
                Text("Wired \(memory.wired.formatted(.byteCount(style: .memory)))")
                Text("Compressed \(memory.compressed.formatted(.byteCount(style: .memory)))")
                Text("Cached files \(memory.cached.formatted(.byteCount(style: .memory)))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

// MARK: - Login items

struct LoginItemsView: View {
    let store: LoginItemsStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text(
                    "Background programs that start with your Mac. Turning one off stops it now and at the next login; turn it back on any time. Apps added under Login Items in System Settings are managed there."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open Login Items Settings") { NSWorkspace.shared.open(SettingsPane.loginItems) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            if let error = store.lastError {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
            }
            Divider()
            if store.loading, store.items.isEmpty {
                BusyView(title: "Looking for background items…")
            } else {
                List {
                    ForEach([PersistenceItem.Kind.userAgent, .agent, .daemon], id: \.self) { kind in
                        let items = store.items.filter { $0.kind == kind }
                        if !items.isEmpty {
                            Section(kind.title) {
                                ForEach(items) { item in
                                    LoginItemRow(item: item, store: store)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Login Items")
        .task { await store.load() }
    }
}

private struct LoginItemRow: View {
    let item: PersistenceItem
    let store: LoginItemsStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: item.label).font(.headline).lineLimit(1).truncationMode(.middle)
                    if item.risk >= .medium {
                        RiskBadge(risk: item.risk)
                    }
                    if item.kind == .daemon {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            .help("Needs administrator password")
                    }
                }
                if let signature = item.signature {
                    Text(signature.summary).font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: item.executable ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if store.busy.contains(item.id) {
                ProgressView().controlSize(.small)
            }
            Toggle("Enabled", isOn: Binding(
                get: { item.isEnabled },
                set: { enabled in Task { await store.setEnabled(enabled, for: item) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(store.busy.contains(item.id))
        }
        .contextMenu {
            if let location = item.location {
                Button("Show in Finder", systemImage: "folder") { FinderActions.reveal([location]) }
            }
        }
    }
}
