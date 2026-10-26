import SwiftUI

/// The screen the app opens on: everything it can do, in one ring.
struct HubView: View {
    @Environment(AppState.self) private var state
    @State private var opened: SidebarSection?

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            RadialMenu(opened: $opened) { module in
                state.selection = module
            }
            .padding(28)

            Text(opened?.summary ?? "Everything this Mac can be told, in one place.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)
                .id(opened)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Hub")
        .animation(.easeOut(duration: 0.25), value: opened)
    }
}
