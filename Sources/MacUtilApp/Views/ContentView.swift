import CleanerCore
import SwiftUI

/// The window: the hub, and whatever tool was chosen from it.
///
/// There is no sidebar. Thirty-odd names down one side is a table of contents, not a way
/// in, and it was the thing that would not scroll. The ring is the way in, and the back
/// button is the way out.
struct ContentView: View {
    @Environment(AppState.self) private var state

    @State private var welcoming = !UserDefaults.standard.bool(forKey: WelcomeView.seenKey)
    @State private var finding = false

    var body: some View {
        @Bindable var state = state

        if welcoming {
            WelcomeView {
                withAnimation(.easeOut(duration: 0.4)) { welcoming = false }
            }
            .transition(.opacity)
        } else {
            main
        }
    }

    private var main: some View {
        @Bindable var state = state

        return ZStack(alignment: .top) {
            stack
            if finding {
                QuickFind(isShown: $finding)
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
    }

    private var stack: some View {
        @Bindable var state = state

        return NavigationStack(path: $state.path) {
            HubView()
                .navigationDestination(for: Module.self) { module in
                    screen(for: module)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .toolbar { toolbar }
                }
                .toolbar { toolbar }
        }
        .sheet(isPresented: $state.showsPermissionsGuide) {
            PermissionsGuideView()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let module = state.path.last {
            ToolbarItem {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        state.toggleFavourite(module)
                    }
                } label: {
                    Image(systemName: state.isFavourite(module) ? "star.fill" : "star")
                        .foregroundStyle(state.isFavourite(module) ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.secondary))
                }
                .help(state.isFavourite(module) ? Text("Remove from the hub") : Text("Keep on the hub"))
            }
        }
        ToolbarItem {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { finding = true }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .help(Text("Find a tool"))
        }
        ToolbarItem {
            Menu {
                Button("Dashboard", systemImage: "gauge.with.dots.needle.67percent") {
                    state.open(.dashboard)
                }
                Button("Settings…", systemImage: "gearshape") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                Divider()
                Button("Quit UniMacHub", systemImage: "power") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
        }
    }

    /// The screen each tool lives on.
    @ViewBuilder private func screen(for module: Module) -> some View {
        switch module {
        case .hub:
            HubView()
        case .dashboard:
            DashboardView()
        case .history:
            HistoryView(store: state.history)
        case .clipboard:
            ClipboardView(store: state.clipboard)
        case .spaceLens:
            SpaceLensView()
        case .largeFiles:
            LargeFilesView()
        case .systemJunk:
            JunkView(module: .systemJunk, store: state.systemJunk)
        case .developerJunk:
            JunkView(module: .developerJunk, store: state.developerJunk)
        case .trash:
            TrashBinsView(store: state.trash)
        case .updater:
            UpdaterView(store: state.updater)
        case .privacy:
            JunkView(module: .privacy, store: state.privacy)
        case .messengers:
            MessengerView(store: state.messengers)
        case .installers:
            InstallerView(store: state.installers)
        case .projectBuilds:
            ProjectBuildsView(store: state.projectBuilds)
        case .maintenance:
            MaintenanceView(store: state.maintenance)
        case .hiddenSettings:
            HiddenSettingsView(store: state.hiddenSettings)
        case .taskManager:
            TaskManagerView(store: state.taskManager)
        case .disks:
            DisksView(store: state.disks)
        case .folderOrganizer:
            OrganizeView(store: state.organize)
        case .fileRecovery:
            RecoveryView(store: state.recovery)
        case .loginItems:
            LoginItemsView(store: state.loginItems)
        case .deepSearch:
            DeepSearchView(store: state.search)
        case .duplicates:
            DuplicatesView(store: state.duplicates)
        case .uninstaller:
            UninstallerView(store: state.uninstaller)
        case .leftovers:
            JunkView(module: .leftovers, store: state.leftovers)
        case .slimming:
            SlimmingView(store: state.slimming)
        case .addOns:
            AddOnsView(store: state.addOns)
        case .terminal:
            TerminalView(store: state.terminal)
        case .networkAdapters:
            NetworkView(store: state.network)
        case .securityAnalyzer:
            SecurityView(store: state.security)
        case let module:
            // Everything built has a case above; what is left is on the way.
            PlannedView(module: module)
        }
    }
}
