import AppKit
import CleanerCore
import SwiftUI

/// What the app says the first time it is opened, and whenever it is asked for again.
///
/// Four steps. The ring builds itself as they go, a quarter at a time, and opens into the
/// hub at the end. The last step is the only one that asks for anything, and it will not
/// let go until the asking is done — a permission granted later, from a screen that no
/// longer explains why, is a permission granted blind. Full Disk Access is the exception:
/// it can be put off, and the tools that need it stay locked until it is given.
struct WelcomeView: View {
    static let seenKey = "welcomeSeen"

    let finish: () -> Void
    @State private var step = 0
    @State private var shown = false
    @State private var leaving = false
    @State private var accepted = false
    @State private var setup = SetupState()

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

    private var lastStep: Int { cards.count }
    private var onSetup: Bool { step == lastStep }
    private var canContinue: Bool { !onSetup || (setup.isComplete && accepted) }

    var body: some View {
        ZStack {
            Backdrop()

            VStack(spacing: 26) {
                ring
                    .frame(width: 190, height: 190)
                    .scaleEffect(leaving ? 3.6 : 1)
                    .opacity(leaving ? 0 : 1)

                Text(verbatim: "UniMacHub")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.accentGradient)
                    .opacity(leaving ? 0 : 1)

                Group {
                    if onSetup { SetupStep(setup: $setup, accepted: $accepted) } else { card }
                }
                .frame(maxWidth: 520, alignment: .top)
                .opacity(leaving ? 0 : 1)

                dots
                    .opacity(leaving ? 0 : 1)

                Button(onSetup ? "Start" : "Next") { advance() }
                    .prominentButton()
                    .controlSize(.large)
                    .disabled(!canContinue)
                    .opacity(leaving ? 0 : 1)
            }
            .padding(40)
        }
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.7)) { shown = true }
        }
    }

    // MARK: - The ring

    /// How much of the ring is drawn: a quarter more at every step, whole at the end.
    private var segments: Int {
        guard shown else { return 0 }
        return min(8, (step + 1) * 2)
    }

    private var ring: some View {
        ZStack {
            ForEach(0 ..< 8, id: \.self) { index in
                let drawn = index < segments
                AnnularSector(start: Double(index) * 45, sweep: 45, inner: 0.44, outer: 0.96)
                    .fill(Palette.accent.opacity(drawn ? 0.3 : 0.04))
                    .overlay(
                        AnnularSector(start: Double(index) * 45, sweep: 45, inner: 0.44, outer: 0.96)
                            .stroke(Palette.accentLight.opacity(drawn ? 0.6 : 0.08), lineWidth: 1.4)
                    )
                    .scaleEffect(drawn ? 1 : 0.9)
                    .animation(
                        .spring(response: 0.55, dampingFraction: 0.7).delay(Double(index % 2) * 0.07),
                        value: segments
                    )
            }
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(Palette.accentLight)
                .opacity(shown ? 1 : 0)
        }
        // The last press spins it once as it opens out into the hub.
        .rotationEffect(.degrees(leaving ? 45 : 0))
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: leaving)
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

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0 ... cards.count, id: \.self) { index in
                Capsule()
                    .fill(index == step ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.quaternary))
                    .frame(width: index == step ? 20 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: step)
    }

    // MARK: - Moving on

    private func advance() {
        if onSetup {
            done()
        } else {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { step += 1 }
        }
    }

    private func done() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { leaving = true }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            finish()
        }
    }
}

/// What has been set up, and what is still waiting — as macOS has it, not as we last left it.
struct SetupState {
    var fullDisk = FullDiskAccess.status() == .granted
    var notifications = Grant.notAsked
    var automation = Grant.notAsked

    /// Every question answered, whichever way. Full Disk Access is not part of it: without
    /// it the app still opens, with the tools that need it locked and saying so.
    var isComplete: Bool { notifications.isAnswered && automation.isAnswered }

    static func current() async -> SetupState {
        SetupState(
            fullDisk: FullDiskAccess.status() == .granted,
            notifications: await Permissions.notifications(),
            automation: await Permissions.automation()
        )
    }
}

/// The last step: three things to arrange, and one line to agree to.
private struct SetupStep: View {
    @Binding var setup: SetupState
    @Binding var accepted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Before you start")
                .font(.title3.weight(.semibold))

            VStack(spacing: 8) {
                SetupRow(
                    symbol: "externaldrive",
                    title: "Full Disk Access",
                    hint: "Caches, mail and browser data live where macOS asks before letting anything look. Without this, part of what is there is simply missed.",
                    grant: setup.fullDisk ? .granted : .notAsked,
                    action: "Open Settings",
                    later: "Can wait. Until then the tools that need it are locked, and each one says how to unlock it."
                ) {
                    NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                } settings: {
                    NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                }
                SetupRow(
                    symbol: "bell.badge",
                    title: "Notifications",
                    hint: "Only for a scan that finished while you were elsewhere, or a disk about to fill up.",
                    grant: setup.notifications,
                    action: "Allow"
                ) {
                    Task { setup.notifications = await Permissions.requestNotifications() }
                } settings: {
                    NSWorkspace.shared.open(Permissions.notificationSettingsURL)
                }
                SetupRow(
                    symbol: "wand.and.rays",
                    title: "Automation",
                    hint: "To ask Finder to move an app that belongs to an administrator. Finder asks for your password itself.",
                    grant: setup.automation,
                    action: "Allow"
                ) {
                    Task { setup.automation = await Permissions.requestAutomation() }
                } settings: {
                    NSWorkspace.shared.open(Permissions.automationSettingsURL)
                }
            }

            Toggle(isOn: $accepted) {
                Text("I understand that UniMacHub removes and changes things on this Mac at my direction, and that I am responsible for what I tell it to do.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .padding(.top, 2)
        }
        .task { setup = await .current() }
        // Coming back from System Settings is the moment to look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { setup = await .current() }
        }
    }
}

/// One thing to arrange: what it is, why, and a button that arranges it.
private struct SetupRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let hint: LocalizedStringKey
    let grant: Grant
    let action: LocalizedStringKey
    /// What happens if this is left for now, for the one step that may be.
    var later: LocalizedStringKey?
    let perform: () -> Void
    /// Where to change an answer already given; macOS will not ask a second time.
    let settings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if grant == .denied {
                    Label("Turned off. macOS asks only once, so it is switched on in System Settings.", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                } else if let later, grant != .granted {
                    Label(later, systemImage: "lock")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            switch grant {
            case .granted:
                EmptyView()
            case .denied:
                Button("Open Settings", action: settings).controlSize(.small)
            case .notAsked:
                Button(action, action: perform).controlSize(.small)
            }
        }
        .padding(10)
        .glassCard(cornerRadius: 10)
        .animation(.easeOut(duration: 0.2), value: grant)
    }

    private var icon: String {
        switch grant {
        case .granted: "checkmark.circle.fill"
        case .denied: "exclamationmark.circle"
        case .notAsked: symbol
        }
    }

    private var tint: AnyShapeStyle {
        switch grant {
        case .granted: AnyShapeStyle(.green)
        case .denied: AnyShapeStyle(.orange)
        case .notAsked: AnyShapeStyle(Palette.accentLight)
        }
    }
}
