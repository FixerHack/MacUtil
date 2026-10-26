import CleanerCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            List(selection: $state.selection) {
                ForEach(SidebarSection.allCases) { section in
                    Section {
                        ForEach(section.modules) { module in
                            SidebarRow(module: module, isSelected: state.selection == module)
                                .tag(module)
                        }
                    } header: {
                        // Text alone: a header icon collides with the first row as the
                        // list scrolls underneath it.
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 215, ideal: 235)
        } detail: {
            Group {
                switch state.selection ?? .hub {
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
            // Screens whose content is shorter than the window stay at the top.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Moving between screens fades rather than cutting, which makes a sidebar
            // of thirty entries feel like one place instead of thirty.
            .transition(.opacity.combined(with: .offset(y: 6)))
            .animation(.easeOut(duration: 0.18), value: state.selection)
        }
        .sheet(isPresented: $state.showsPermissionsGuide) {
            PermissionsGuideView()
        }
    }
}

/// One entry in the sidebar: an icon that takes the accent colour when chosen, and a
/// mark on the screens that are not built yet.
private struct SidebarRow: View {
    let module: Module
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label(module.title, systemImage: module.symbol)
                .foregroundStyle(module.isPlanned ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .symbolVariant(isSelected ? .fill : .none)
            if module.isPlanned {
                Spacer()
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help(Text("Coming soon"))
            }
        }
    }
}
