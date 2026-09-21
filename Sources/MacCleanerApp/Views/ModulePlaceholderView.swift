import SwiftUI

/// Shown for modules that are on the roadmap but not built yet.
struct ModulePlaceholderView: View {
    let module: Module

    var body: some View {
        ContentUnavailableView {
            Label(module.title, systemImage: module.symbol)
        } description: {
            VStack(spacing: 8) {
                Text(module.summary)
                Text("Planned for phase \(module.plannedPhase)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .navigationTitle(module.title)
    }
}
