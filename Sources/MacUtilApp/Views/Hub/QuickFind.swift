import SwiftUI

/// Type a few letters, press Return, you are there.
///
/// Without a sidebar every tool is two clicks away, which is right for finding something
/// and wrong for the one you open daily. This is the other way in, and it does not take
/// up any room until it is asked for.
struct QuickFind: View {
    @Environment(AppState.self) private var state
    @Binding var isShown: Bool
    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [Module] { Array(state.matches(text).prefix(7)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find a tool", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { open(results.indices.contains(highlighted) ? results[highlighted] : nil) }
                    .onChange(of: text) { _, _ in highlighted = 0 }
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            if !results.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element) { index, module in
                        row(module, isHighlighted: index == highlighted)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 460)
        .glassCard(cornerRadius: 16)
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        .onAppear { focused = true }
        // Up and down walk the list; Return opens what is lit.
        .onMoveCommand { direction in
            switch direction {
            case .up: highlighted = max(0, highlighted - 1)
            case .down: highlighted = min(results.count - 1, highlighted + 1)
            default: break
            }
        }
        .onExitCommand { close() }
    }

    private func row(_ module: Module, isHighlighted: Bool) -> some View {
        Button {
            open(module)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: module.symbol)
                    .frame(width: 20)
                    .foregroundStyle(module.isPlanned ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Palette.accent))
                Text(module.title)
                    .foregroundStyle(module.isPlanned ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if module.isPlanned {
                    Text("Coming soon")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(module.section.title)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHighlighted ? Palette.accent.opacity(0.22) : .clear)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func open(_ module: Module?) {
        if let module { state.open(module) }
        close()
    }

    private func close() {
        text = ""
        withAnimation(.easeOut(duration: 0.15)) { isShown = false }
    }
}
