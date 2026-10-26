import SwiftUI

/// What the app says the first time it is opened, and never again unasked.
///
/// Three short cards and a ring that draws itself. It exists to answer one question —
/// what is this and where do I start — not to be sat through, so every step is skippable
/// and the whole thing is over in well under a minute.
struct WelcomeView: View {
    static let seenKey = "welcomeSeen"

    let finish: () -> Void
    @State private var step = 0
    @State private var ringShown = false

    private struct Card {
        let title: LocalizedStringKey
        let text: LocalizedStringKey
    }

    private let cards: [Card] = [
        Card(
            title: "Everything in one ring",
            text: "The hub holds every tool, grouped by what you came to do. Choose a section, then a tool; the middle takes you back."
        ),
        Card(
            title: "Nothing happens unseen",
            text: "Every scan shows what it found before anything is removed, and what goes to the Trash can come back out of it."
        ),
        Card(
            title: "Yours, and only yours",
            text: "Nothing is uploaded and nothing is reported. The one exception asks first: a file you choose to check against VirusTotal."
        ),
    ]

    var body: some View {
        ZStack {
            Backdrop()

            VStack(spacing: 34) {
                ring
                    .frame(width: 168, height: 168)

                VStack(spacing: 12) {
                    Text(verbatim: "UniMacHub")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.accentGradient)

                    card
                        .frame(maxWidth: 440, minHeight: 112, alignment: .top)
                }

                HStack(spacing: 7) {
                    ForEach(cards.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == step ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.quaternary))
                            .frame(width: index == step ? 20 : 7, height: 7)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: step)

                HStack(spacing: 12) {
                    Button("Skip") { done() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Button(step == cards.count - 1 ? "Start" : "Next") {
                        if step == cards.count - 1 {
                            done()
                        } else {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { step += 1 }
                        }
                    }
                    .prominentButton()
                    .controlSize(.large)
                }
            }
            .padding(44)
        }
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.7)) { ringShown = true }
        }
    }

    /// The ring from the hub, drawn once as an introduction to itself.
    private var ring: some View {
        ZStack {
            ForEach(0 ..< 8, id: \.self) { index in
                AnnularSector(start: Double(index) * 45, sweep: 45, inner: 0.42, outer: 0.95)
                    .fill(Palette.accent.opacity(ringShown ? 0.28 : 0))
                    .overlay(
                        AnnularSector(start: Double(index) * 45, sweep: 45, inner: 0.42, outer: 0.95)
                            .stroke(Palette.accentLight.opacity(ringShown ? 0.55 : 0), lineWidth: 1.4)
                    )
                    .scaleEffect(ringShown ? 1 : 0.55)
                    .animation(
                        .spring(response: 0.7, dampingFraction: 0.68).delay(Double(index) * 0.06),
                        value: ringShown
                    )
            }
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(Palette.accentLight)
                .opacity(ringShown ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.45), value: ringShown)
        }
    }

    private var card: some View {
        VStack(spacing: 10) {
            Text(cards[step].title)
                .font(.title3.weight(.semibold))
            Text(cards[step].text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .id(step)
        .transition(.asymmetric(
            insertion: .offset(x: 26).combined(with: .opacity),
            removal: .offset(x: -26).combined(with: .opacity)
        ))
    }

    private func done() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        finish()
    }
}
