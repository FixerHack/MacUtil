import CleanerCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            List(selection: $state.selection) {
                ForEach(SidebarSection.allCases) { section in
                    Section(section.title) {
                        ForEach(section.modules) { module in
                            Label(module.title, systemImage: module.symbol)
                                .tag(module)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            switch state.selection ?? .dashboard {
            case .dashboard:
                DashboardView()
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
            case .uninstaller:
                UninstallerView(store: state.uninstaller)
            case .leftovers:
                JunkView(module: .leftovers, store: state.leftovers)
            case .securityAnalyzer:
                SecurityView(store: state.security)
            case let module:
                ModulePlaceholderView(module: module)
            }
        }
        .sheet(isPresented: $state.showsPermissionsGuide) {
            PermissionsGuideView()
        }
    }
}
