import AppKit
import CleanerCore
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
    @State private var access = FullDiskAccess.status()
    /// The ring grows into the hub it is about to become.
    @State private var leaving = false

    private struct Card {
        let title: LocalizedStringKey
        let text: LocalizedStringKey
    }

    private var permissionsStep: Int { cards.count }
    private var lastStep: Int { cards.count }

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
                    .scaleEffect(leaving ? 3.4 : 1)
                    .opacity(leaving ? 0 : 1)

                VStack(spacing: 12) {
                    Text(verbatim: "UniMacHub")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.accentGradient)

                    Group {
                        if step == permissionsStep { permissions } else { card }
                    }
                    .frame(maxWidth: 460, minHeight: 150, alignment: .top)
                }

                HStack(spacing: 7) {
                    ForEach(0 ... cards.count, id: \.self) { index in
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
                    Button(step == lastStep ? "Start" : "Next") {
                        if step == lastStep {
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

    /// The ring swells and fades as the hub takes over, so the two read as one thing.
    private func done() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { leaving = true }
        Task {
            try? await Task.sleep(for: .milliseconds(430))
            finish()
        }
    }

    /// What the app will ask for, said before macOS asks it.
    private var permissions: some View {
        VStack(spacing: 12) {
            Text("What it will ask for")
                .font(.title3.weight(.semibold))
            Text("Nothing is asked for in advance. Each permission is requested by the tool that needs it, when you use it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                permission(
                    symbol: "externaldrive", title: "Full Disk Access",
                    detail: "To see caches, mail and browser data. Without it, part of what is there is simply missed.",
                    granted: access == .granted
                )
                permission(
                    symbol: "bell.badge", title: "Notifications",
                    detail: "Only for a scan that finished or a disk about to fill up.",
                    granted: nil
                )
                permission(
                    symbol: "key", title: "Your password",
                    detail: "Asked by macOS itself, each time, for the few things that need an administrator.",
                    granted: nil
                )
            }

            if access != .granted {
                Button("Set Up Full Disk Access…") {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .prominentButton()
            }
        }
        .onAppear { access = FullDiskAccess.status() }
    }

    private func permission(
        symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey, granted: Bool?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.accentLight)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.medium))
                    if granted == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}
