import SwiftUI

/// The screen the app opens on: everything it can do, in one ring.
struct HubView: View {
    @Environment(AppState.self) private var state
    @State private var opened: SidebarSection?

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            RadialMenu(opened: $opened) { module in
                state.open(module)
            }
            .padding(28)

            Text(opened?.summary ?? "Everything this Mac can be told, in one place.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .id(opened)
                .transition(.opacity)

            if !state.favourites.isEmpty {
                favourites
                    .padding(.top, 14)
            }
        }
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Hub")
        .animation(.easeOut(duration: 0.25), value: opened)
    }

    /// Tools kept to hand, under the ring. Pinned from a tool's own screen, so the list
    /// is whatever turned out to be worth returning to rather than what we guessed.
    private var favourites: some View {
        HStack(spacing: 8) {
            ForEach(state.favourites) { module in
                Button {
                    state.open(module)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: module.symbol)
                            .font(.caption)
                            .foregroundStyle(Palette.accent)
                        Text(module.title)
                            .font(.caption)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .glassCard(cornerRadius: 9)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(Text("Open \(module.titleText)"))
            }
        }
        .transition(.opacity)
    }
}
