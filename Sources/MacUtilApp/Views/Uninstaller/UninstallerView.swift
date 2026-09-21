import CleanerCore
import SwiftUI

struct UninstallerView: View {
    enum SortOrder: Hashable {
        case name, size, lastUsed
    }

    @Bindable var store: UninstallerStore
    @State private var search = ""
    @State private var sortOrder = SortOrder.name

    private var apps: [AppRecord] {
        let filtered = search.isEmpty ? store.apps : store.apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || ($0.bundleID ?? "")
                .localizedCaseInsensitiveContains(search)
        }
        switch sortOrder {
        case .name: return filtered
        case .size: return filtered.sorted { $0.size > $1.size }
        case .lastUsed: return filtered.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                BusyView(title: "Looking for apps…")
            case .working:
                BusyView(title: "Removing…")
            case let .done(result):
                CleanupResultView(result: result) {
                    Task { await store.undo(result) }
                } done: {
                    Task { await store.finish() }
                }
            case .ready:
                HStack(spacing: 0) {
                    appList
                        .frame(width: 320)
                    Divider()
                    if let app = store.selectedApp {
                        AppDetail(app: app, store: store)
                    } else {
                        ContentUnavailableView(
                            "Choose an app",
                            systemImage: "trash.square",
                            description: Text("MacUtil shows the app together with the data it keeps in your Library.")
                        )
                    }
                }
            }
        }
        .navigationTitle("Uninstaller")
        .task {
            if case .idle = store.phase {
                await store.load()
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Rescan", systemImage: "arrow.clockwise") { Task { await store.load() } }
            }
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        Text("Name").tag(SortOrder.name)
                        Text("Size").tag(SortOrder.size)
                        Text("Least used").tag(SortOrder.lastUsed)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort")
            }
            .padding(10)
            List(apps, selection: $store.selectedAppID) { app in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: app.name)
                            .lineLimit(1)
                        Group {
                            if let lastUsed = app.lastUsed {
                                Text("Opened \(lastUsed, format: .relative(presentation: .named))")
                            } else {
                                Text("Never opened")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(verbatim: app.size.formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(app.id)
            }
            .listStyle(.inset)
        }
    }
}

private struct AppDetail: View {
    let app: AppRecord
    let store: UninstallerStore
    @State private var confirming: Action?

    enum Action: Identifiable {
        case uninstall, reset
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            leftoverList
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .confirmationDialog(
            confirming == .reset ? "Reset \(app.name)?" : "Uninstall \(app.name)?",
            isPresented: Binding(get: { confirming != nil }, set: {
                if !$0 {
                    confirming = nil
                }
            }),
            presenting: confirming
        ) { action in
            Button(action == .reset ? "Remove Data" : "Move to Trash", role: .destructive) {
                Task { await store.remove(app, includingApp: action == .uninstall) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action == .reset
                ? "The selected data moves to the Trash. The app stays and starts fresh, as on first launch."
                : "The app and the selected data move to the Trash. You can restore them until you empty it.")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: app.name).font(.title2.bold())
                    if app.isAppStore {
                        Badge(title: "App Store", color: .blue)
                    }
                }
                Text(verbatim: [app.version, app.bundleID].compactMap(\.self).joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(verbatim: FinderActions.abbreviate(app.path))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if store.runningApp(for: app) != nil {
                VStack(alignment: .trailing, spacing: 6) {
                    Label("The app is running", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Quit App") { Task { await store.quit(app) } }
                }
            }
        }
    }

    @ViewBuilder private var leftoverList: some View {
        if store.isLoadingLeftovers {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.leftovers.isEmpty {
            ContentUnavailableView("No data outside the app", systemImage: "checkmark.circle")
        } else {
            List {
                ForEach(Leftover.Kind.allCases, id: \.self) { kind in
                    let items = store.leftovers.filter { $0.kind == kind }
                    if !items.isEmpty {
                        Section(kind.title) {
                            ForEach(items) { item in
                                LeftoverRow(item: item, isSelected: store.selectedLeftovers.contains(item.id)) {
                                    if store.selectedLeftovers.contains(item.id) {
                                        store.selectedLeftovers.remove(item.id)
                                    } else {
                                        store.selectedLeftovers.insert(item.id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        let isRunning = store.runningApp(for: app) != nil
        return HStack {
            Text(
                "App \(app.size.formatted(.byteCount(style: .file))) · data \(store.selectedLeftoverSize.formatted(.byteCount(style: .file)))"
            )
            .monospacedDigit()
            .foregroundStyle(.secondary)
            Spacer()
            Button("Reset…") { confirming = .reset }
                .disabled(store.selectedLeftovers.isEmpty || isRunning)
                .help("Remove the app's data but keep the app")
            Button("Uninstall…") { confirming = .uninstall }
                .prominentButton()
                .disabled(isRunning)
        }
        .controlSize(.large)
    }
}

private struct LeftoverRow: View {
    let item: Leftover
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CheckButton(state: isSelected ? .all : .none, isEnabled: !item.requiresAdmin, action: toggle)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name).lineLimit(1).truncationMode(.middle)
                Text(verbatim: FinderActions.abbreviate(item.path))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if item.requiresAdmin {
                Badge(title: "Needs administrator rights", color: .secondary)
            } else if item.match == .name {
                Badge(title: "Matched by name", color: .orange)
                    .help("Named like the app, not by its identifier. Check before removing.")
            }
            Spacer()
            Text(verbatim: item.size.formatted(.byteCount(style: .file)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .opacity(item.requiresAdmin ? 0.6 : 1)
        .contextMenu {
            Button("Show in Finder", systemImage: "folder") { FinderActions.reveal([item.path]) }
        }
    }
}

extension Leftover.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .applicationSupport: "Application data"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .containers: "Containers"
        case .groupContainers: "Shared containers"
        case .savedState: "Saved window state"
        case .webData: "Web data and cookies"
        case .logs: "Logs"
        case .launchItems: "Launch agents and helpers"
        case .other: "Other"
        }
    }
}
