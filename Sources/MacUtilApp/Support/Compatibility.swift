import SwiftUI

/// Liquid Glass styles on macOS 26, the classic look on macOS 14 and 15.
extension View {
    @ViewBuilder func prominentButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// A panel that takes the glass treatment where the system has it, and a plain
    /// material where it does not. Used for the cards the app is built out of.
    @ViewBuilder func glassCard(cornerRadius: CGFloat = 14) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        }
    }

    /// Fades a view in and lifts it slightly, for content that arrives after a scan.
    func appears(_ delay: Double = 0) -> some View {
        modifier(Appears(delay: delay))
    }

    /// A number that counts up to its new value instead of jumping.
    func settles<Value: Equatable>(on value: Value) -> some View {
        animation(.easeOut(duration: 0.35), value: value)
    }
}

/// Content that arrives rather than appearing: a short fade and a small rise.
///
/// Kept deliberately brief. An animation that draws attention once is pleasant; the same
/// animation on every scan of a hundred rows is in the way.
private struct Appears: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .onAppear {
                withAnimation(.easeOut(duration: 0.28).delay(delay)) { shown = true }
            }
    }
}

/// A bar that fills to a fraction, with the colour saying how close to full it is.
struct MeterBar: View {
    let fraction: Double
    var height: CGFloat = 6

    private var colour: Color {
        switch fraction {
        case ..<0.75: .accentColor
        case ..<0.9: .orange
        default: .red
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [colour.opacity(0.75), colour],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}
