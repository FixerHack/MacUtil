import SwiftUI

/// The screen the app opens on: everything it can do, in one ring.
struct HubView: View {
    @Environment(AppState.self) private var state
    @State private var opened: SidebarSection?
    @State private var pointedAt: RingHint?

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            RadialMenu(opened: $opened, pointedAt: $pointedAt) { module in
                state.open(module)
            }
            .padding(28)

            caption
                .frame(height: 58)

            if !state.favourites.isEmpty {
                favourites
                    .padding(.top, 14)
            }
        }
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Hub")
        .animation(.easeOut(duration: 0.25), value: opened)
        .animation(.easeOut(duration: 0.14), value: pointedAt == nil)
    }

    /// One line under the ring: what the cursor is over, or else where you are.
    ///
    /// Both live in the same place, and only one is ever drawn. Laid over each other, the
    /// plaque's glass let the line beneath read straight through it.
    @ViewBuilder
    private var caption: some View {
        if let pointedAt {
            VStack(spacing: 2) {
                Text(pointedAt.title).font(.callout.weight(.semibold))
                Text(pointedAt.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 360)
            .glassCard(cornerRadius: 10)
            .transition(.opacity)
        } else {
            Text(opened?.summary ?? "Everything this Mac can be told, in one place.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .id(opened)
                .transition(.opacity)
        }
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
