import CleanerCore
import SwiftUI

struct SettingsView: View {
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
                    Text("Restart MacCleaner to apply the new language.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Now") {
                        AppLanguage.relaunch()
                    }
                }
            }

            LabeledContent("Version") {
                Text(verbatim: MacCleanerInfo.version)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
