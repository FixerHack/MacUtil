import SwiftUI

/// A word about a tool, the first time it is opened.
///
/// The same idea as the welcome, in miniature: the thing in front of you, explained once,
/// before you press anything. It is shown exactly once per tool and can be brought back
/// from Settings for all of them at once.
struct FirstVisit: ViewModifier {
    static let key = "visitedModules"

    let module: Module
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .task { showing = !Self.wasVisited(module) }
            .overlay {
                if showing {
                    card
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: showing)
    }

    private var card: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 16) {
                Image(systemName: module.symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Palette.accentGradient)

                VStack(spacing: 7) {
                    Text(module.title)
                        .font(.title3.weight(.semibold))
                    Text(module.summary)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let note = module.firstVisitNote {
                    Text(note)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(11)
                        .frame(maxWidth: .infinity)
                        .background(Palette.accent.opacity(0.12), in: .rect(cornerRadius: 9))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Got it") { dismiss() }
                    .prominentButton()
                    .controlSize(.large)
            }
            .padding(28)
            .frame(maxWidth: 420)
            .glassCard(cornerRadius: 16)
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        }
    }

    private func dismiss() {
        Self.markVisited(module)
        showing = false
    }

    // MARK: - What has been seen

    static func wasVisited(_ module: Module) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(module.key)
    }

    static func markVisited(_ module: Module) {
        var seen = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !seen.contains(module.key) else { return }
        seen.append(module.key)
        UserDefaults.standard.set(seen, forKey: key)
    }

    /// Forgets every tool that has been introduced, so they introduce themselves again.
    static func forgetAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

extension View {
    /// Introduces a tool the first time it is opened.
    func introduces(_ module: Module) -> some View {
        modifier(FirstVisit(module: module))
    }
}
