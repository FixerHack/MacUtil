import CleanerCore
import SecurityCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var language = AppLanguage.current
    @State private var needsRestart = false

    var body: some View {
        Form {
            Picker("Language", selection: $language) {
                Text("System").tag(AppLanguage.system)
                // Language names are always shown in their own language.
                Text(verbatim: "English").tag(AppLanguage.english)
                Text(verbatim: "Українська").tag(AppLanguage.ukrainian)
            }
            .onChange(of: language) { _, newValue in
                newValue.apply()
                needsRestart = true
            }

            if needsRestart {
                HStack {
                    Text("Restart MacUtil to apply the new language.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Now") {
                        AppLanguage.relaunch()
                    }
                }
            }

            LabeledContent("Full Disk Access") {
                if state.fullDiskAccess == .granted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Set Up…") {
                        openWindow(id: "main")
                        state.showsPermissionsGuide = true
                    }
                }
            }

            Section("VirusTotal") {
                VirusTotalKeySettings()
            }

            LabeledContent("Version") {
                Text(verbatim: MacUtilInfo.version)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct VirusTotalKeySettings: View {
    @Environment(AppState.self) private var state
    @State private var key = ""
    @State private var hasKey = VirusTotalKey.load() != nil

    var body: some View {
        if hasKey {
            LabeledContent("API key") {
                HStack {
                    Label("Saved in Keychain", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Remove") {
                        VirusTotalKey.delete()
                        hasKey = false
                        state.security.refreshKey()
                    }
                }
            }
        } else {
            SecureField("API key", text: $key)
            HStack {
                Link("Get a free key", destination: URL(string: "https://www.virustotal.com/gui/join-us")!)
                Spacer()
                Button("Save") {
                    hasKey = VirusTotalKey.save(key)
                    key = ""
                    state.security.refreshKey()
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        Text(
            "Only file hashes are sent to VirusTotal. A file is uploaded only when you confirm it. The free key allows 4 lookups a minute and 500 a day."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
