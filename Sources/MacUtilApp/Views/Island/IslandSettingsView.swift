import AppKit
import ApplicationServices
import SwiftUI

/// What the island shows and may do, and the one permission it asks for.
struct IslandSettingsView: View {
    @Bindable var model: IslandModel
    @State private var trusted = AXIsProcessTrusted()

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
                Toggle("Music and Spotify", isOn: $model.showsNowPlaying)
                Toggle("File shelf", isOn: $model.showsShelf)
            } header: {
                Text("What it shows")
            } footer: {
                Text("Music and Spotify announce what they play to any app that listens, so nothing private is used. Sound from a browser tab is not covered. Files on the shelf stay where they are; the shelf only remembers where.")
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
        }
        .formStyle(.grouped)
        .navigationTitle("Dynamic Island")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
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
