import AppKit
import ApplicationServices
import SwiftUI

/// What the island shows and may do, and the one permission it asks for.
struct IslandSettingsView: View {
    @Bindable var model: IslandModel
    @State private var trusted = AXIsProcessTrusted()
    @State private var confirmsConnection = false
    @State private var connectionError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show the island", isOn: $model.isEnabled)
                Toggle("On screens without a notch, as a tab at the top", isOn: $model.onPlainScreens)
                    .disabled(!model.isEnabled)
            } footer: {
                Text("It rests in the notch, or as a small tab in the middle of the menu bar, and opens when you point at it or drop a file on it. It never takes the keyboard from the app you are in.")
            }

            Section {
                Toggle("What is playing", isOn: $model.showsNowPlaying)
                Toggle("File shelf", isOn: $model.showsShelf)
            } header: {
                Text("What it shows")
            } footer: {
                Text("Music, Spotify, a video in the browser, anything that shows in Control Centre's Now Playing. With several at once, swipe sideways in the opened island to go from one to the next. Files on the shelf stay where they are; the shelf only remembers where.")
            }

            Section {
                Toggle("Volume and brightness in the island", isOn: $model.replacesIndicators)
                    .onChange(of: model.replacesIndicators) { _, on in
                        if on, !AXIsProcessTrusted() { askForAccessibility() }
                    }
                Toggle("Volume keys change Music or Spotify while it plays", isOn: $model.playerVolume)
                    .disabled(!model.replacesIndicators)
                if model.replacesIndicators, !trusted {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Waiting for Accessibility. Until then macOS shows its own indicators.")
                            .font(.callout)
                        Spacer()
                        Button("Open Settings") { askForAccessibility() }
                    }
                }
            } header: {
                Text("Keys")
            } footer: {
                Text("To show its own indicator, UniMacHub has to take the key before macOS does, which needs Accessibility. A key it cannot act on, such as the volume of HDMI speakers or keyboard light, is passed on to macOS unchanged. Speakers on AirPlay follow the player's own volume, which is why the keys change that while music plays.")
            }

            agentsSection
            calendarSection
        }
        .formStyle(.grouped)
        .alert("Connect Claude Code?", isPresented: $confirmsConnection) {
            Button("Connect") { connect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("UniMacHub adds its hooks and a status line to ~/.claude/settings.json. Hooks other apps put there stay as they are. A status line you already have keeps showing; UniMacHub runs it and only reads the usage limits on the way. A copy of the file is kept next to it, and Disconnect takes out exactly what was added. Sessions that are already open pick this up when they start again.")
        }
        .alert("Claude Code was not changed", isPresented: Binding(get: { connectionError != nil }, set: { if !$0 { connectionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: connectionError ?? "")
        }
        .navigationTitle("Dynamic Island")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
        }
    }

    @ViewBuilder private var agentsSection: some View {
        let agents = model.agents
        Section {
            Toggle("Show coding agents", isOn: Bindable(agents).showsAgents)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Claude Code")
                    Text(agents.claudeConnected ? "Connected: sessions, questions and limits" : "Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if agents.claudeConnected {
                    Button("Disconnect") { disconnect() }
                } else {
                    Button("Connect…") { confirmsConnection = true }
                }
            }
            .disabled(!agents.showsAgents)
            Toggle("Answer Claude Code's permission requests in the island", isOn: Bindable(agents).answersInIsland)
                .disabled(!agents.showsAgents || !agents.claudeConnected)
            Toggle("Codex", isOn: Bindable(agents).readsCodex)
                .disabled(!agents.showsAgents)
        } header: {
            Text("Coding agents")
        } footer: {
            Text("The island shows which sessions are at work, which have finished and which wait for you, with Claude Code's and Codex's usage limits. A question goes to the island only when the terminal it comes from is not in front; otherwise Claude Code asks it there, as always. Codex is read from the logs it keeps anyway, and nothing is added to it.")
        }
    }

    @ViewBuilder private var calendarSection: some View {
        let calendar = model.calendar
        Section {
            Toggle("Next calendar event", isOn: Bindable(calendar).isEnabled)
            if calendar.isEnabled, calendar.access == .denied {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("UniMacHub may not read your calendars.").font(.callout)
                    Spacer()
                    Button("Open Settings") { calendar.openSettings() }
                }
            }
            Toggle("Battery of this Mac and what is paired with it", isOn: Bindable(model.batteries).isEnabled)
        } header: {
            Text("Calendar and batteries")
        } footer: {
            Text("The next event shows in the opened island, and beside the notch ten minutes before it starts. Batteries cover this Mac, Bluetooth keyboards, mice and trackpads, and AirPods with each side and the case.")
        }
    }

    private func connect() {
        do {
            try model.agents.connectClaude()
        } catch {
            connectionError = Self.describe(error)
        }
    }

    private func disconnect() {
        do {
            try model.agents.disconnectClaude()
        } catch {
            connectionError = Self.describe(error)
        }
    }

    private static func describe(_ error: AgentsModel.ConnectionError) -> String {
        switch error {
        case .noTool:
            String(localized: "The command-line tool inside UniMacHub is missing. Reinstall UniMacHub and try again.")
        case .settings(.unreadable):
            String(localized: "~/.claude/settings.json is not plain JSON, so UniMacHub leaves it alone.")
        case let .settings(.unwritable(reason)):
            reason
        }
    }

    private func askForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
