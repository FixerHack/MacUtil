import AppKit
import CleanerCore
import SecurityCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Preferences.showsMenuBar) private var showsMenuBar = true
    @AppStorage(Preferences.lowDiskWarning) private var lowDiskWarning = false
    @AppStorage(Preferences.hardwareAlerts) private var hardwareAlerts = false
    @AppStorage(Preferences.cleanupSchedule) private var cleanupSchedule = ScheduledCleanup.Schedule.never.rawValue
    @AppStorage(Preferences.reminder) private var reminder = Notifications.Reminder.never.rawValue
    @AppStorage(Palette.key) private var scheme = Palette.Scheme.blue.rawValue
    @AppStorage(Preferences.collectsStats) private var collectsStats = true
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
                    Text("Restart UniMacHub to apply the new language.")
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

            Section("Menu bar and notifications") {
                Toggle("Show system monitor in the menu bar", isOn: $showsMenuBar)
                Toggle("Warn about heat, memory pressure and a busy processor", isOn: Binding(
                    get: { hardwareAlerts },
                    set: { enabled in
                        hardwareAlerts = enabled
                        if enabled {
                            Task { _ = await Notifications.requestPermission() }
                        }
                    }
                ))
                Toggle("Warn when disk space is low", isOn: Binding(
                    get: { lowDiskWarning },
                    set: { enabled in
                        lowDiskWarning = enabled
                        if enabled {
                            Task { _ = await Notifications.requestPermission() }
                        }
                    }
                ))
                Picker("Clean up by itself", selection: Binding(
                    get: { ScheduledCleanup.schedule },
                    set: { value in
                        cleanupSchedule = value.rawValue
                        if value != .never {
                            Task { _ = await Notifications.requestPermission() }
                        }
                    }
                )) {
                    Text("Never").tag(ScheduledCleanup.Schedule.never)
                    Text("Every week").tag(ScheduledCleanup.Schedule.weekly)
                    Text("Every month").tag(ScheduledCleanup.Schedule.monthly)
                }
                Text("Only caches and logs UniMacHub considers safe, and only from apps that are not running. Everything goes to the Trash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("Remind me to clean up", selection: Binding(
                    get: { Notifications.Reminder(rawValue: reminder) ?? .never },
                    set: { value in
                        reminder = value.rawValue
                        Task {
                            if value != .never {
                                _ = await Notifications.requestPermission()
                            }
                            Notifications.schedule(value)
                        }
                    }
                )) {
                    Text("Never").tag(Notifications.Reminder.never)
                    Text("Every week").tag(Notifications.Reminder.weekly)
                    Text("Every month").tag(Notifications.Reminder.monthly)
                }
            }

            Section("Appearance") {
                Picker("Colour", selection: $scheme) {
                    ForEach(Palette.Scheme.allCases) { option in
                        HStack(spacing: 7) {
                            Circle().fill(option.accent).frame(width: 11, height: 11)
                            Text(option.title)
                        }
                        .tag(option.rawValue)
                    }
                }
                Text("Everything the app draws in colour follows this. Red, orange and green keep their meanings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("What is measured") {
                Toggle("Read the sensors for the menu bar", isOn: $collectsStats)
                Text("Processor, memory, disk, network, temperature and fans, read a few times a minute while the menu bar item is shown. Switched off, the menu bar shows what it can without them and nothing is sampled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Protected places") {
                ProtectedPathsSettings()
            }

            Section("VirusTotal") {
                VirusTotalKeySettings()
            }

            Section("Updates") {
                UpdateSettings()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}


/// Files and folders MacUtil must never offer to remove.
private struct ProtectedPathsSettings: View {
    @State private var protected = ProtectedPaths.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anything listed here is left out of every scan, however safe UniMacHub thinks it is.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if protected.isEmpty {
                Text("Nothing is protected yet.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(protected.paths, id: \.self) { path in
                            HStack(spacing: 6) {
                                Image(systemName: "lock")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(verbatim: path)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .help(path)
                                Spacer()
                                Button("Remove", systemImage: "minus.circle") { remove(path) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                // Enough to read the list without the settings window growing without end.
                .frame(maxHeight: 140)
            }

            Button("Add…") { add() }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose what UniMacHub should never remove.")
        guard panel.runModal() == .OK else { return }
        var updated = protected
        for url in panel.urls {
            updated = updated.adding(url.path(percentEncoded: false))
        }
        apply(updated)
    }

    private func remove(_ path: String) {
        apply(protected.removing(path))
    }

    private func apply(_ updated: ProtectedPaths) {
        updated.save()
        protected = updated
    }
}

private struct VirusTotalKeySettings: View {
    @Environment(AppState.self) private var state
    @State private var key = ""
    @State private var hasKey = VirusTotalKey.exists()

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
