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
            case let module:
                ModulePlaceholderView(module: module)
            }
        }
    }
}
