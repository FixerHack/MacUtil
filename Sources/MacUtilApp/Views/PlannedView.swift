import SwiftUI

/// A screen for something not built yet: what it will do, and what it will cost.
///
/// Listing these in the sidebar rather than hiding them keeps the shape of the app honest.
/// Each one says plainly where it is harder than it looks — a permission it needs, or a
/// limit macOS puts on it — so nothing arrives as a surprise later.
struct PlannedView: View {
    let module: Module
    @State private var glow = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: module.symbol)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.4)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.accentColor.opacity(glow ? 0.5 : 0.15), radius: glow ? 22 : 8)
                .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: glow)

            VStack(spacing: 8) {
                Text(module.title)
                    .font(.title2.weight(.semibold))
                Text("Coming soon")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.18), in: .capsule)
                    .foregroundStyle(Color.accentColor)
            }

            if let note = module.plannedNote {
                Text(note)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .navigationTitle(module.title)
        .onAppear { glow = true }
    }
}
