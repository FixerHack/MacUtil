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
            .safeAreaInset(edge: .bottom) {
                Text(verbatim: "MacCleaner \(MacCleanerInfo.version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
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
            case let module:
                ModulePlaceholderView(module: module)
            }
        }
    }
}
