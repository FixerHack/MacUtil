import AppKit
import CleanerCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// UniMacHub's Dock: turning it on, with a plain word first about the system Dock, and how it
/// looks and what is in it.
struct DockSettingsView: View {
    @Bindable var model: DockModel
    @State private var confirmsEnabling = false
    @State private var town = ""
    @State private var problem: DockService.Problem?

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UniMacHub's Dock")
                        Text(model.isEnabled ? "On: it stays when UniMacHub is closed, and starts at login" : "Off: the system Dock works as usual")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isEnabled {
                        Button("Turn Off") { DockService.turnOff(model) }
                    } else {
                        Button("Turn On…") { confirmsEnabling = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let problem {
                    problemView(problem)
                }
            } footer: {
                Text("The Dock runs on its own, as a small background part of UniMacHub, so quitting UniMacHub leaves it in place. The system Dock comes back exactly as it was when you turn this off. Should it ever be stuck hidden, in Terminal: defaults delete com.apple.dock autohide-delay; killall Dock")
                    .textSelection(.enabled)
            }

            Section {
                LabeledContent("Icon size") {
                    HStack {
                        Slider(value: $model.iconSize, in: DockModel.iconSizes, step: 2)
                        Text(verbatim: "\(Int(model.iconSize))").monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                }
                Toggle("Magnify icons under the pointer", isOn: $model.magnifies)
                if model.magnifies {
                    LabeledContent("Magnification") {
                        HStack {
                            Slider(value: $model.magnification, in: 1.05 ... 2, step: 0.005)
                            Text(verbatim: String(format: "%.3f×", model.magnification)).monospacedDigit().frame(width: 54, alignment: .trailing)
                        }
                    }
                }
                Toggle("Hide and show automatically", isOn: $model.autohides)
                Picker("Position on screen", selection: $model.position) {
                    Text("Bottom").tag(DockModel.Position.bottom)
                    Text("Left").tag(DockModel.Position.left)
                    Text("Right").tag(DockModel.Position.right)
                }
                Toggle("Dots under open apps", isOn: $model.showsIndicators)
                Picker("Minimising windows", selection: Binding(get: { MinimizeEffect.current }, set: { MinimizeEffect.set($0) })) {
                    Text("Genie").tag(MinimizeEffect.genie)
                    Text("Scale").tag(MinimizeEffect.scale)
                }
            } header: {
                Text("Look")
            } footer: {
                Text("When everything does not fit along the edge, the whole Dock shrinks to fit, as the system one does. Windows that fill the screen go under the Dock when it stays out, as there is no way for another app to keep them clear of it; hiding it automatically avoids that. The minimising effect is macOS's own and applies at once.")
            }

            Section {
                Toggle("Apps that are open but not kept in the Dock", isOn: $model.showsRunningApps)
                Toggle("UniMacHub's tools, one button per section", isOn: $model.showsTools)
                ForEach(model.pinned, id: \.self) { url in
                    HStack {
                        Image(nsImage: model.icon(for: url)).resizable().frame(width: 20, height: 20)
                        Text(verbatim: FileManager.default.displayName(atPath: url.path))
                        Spacer()
                        Button {
                            model.unpin(url)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(Text("Remove from Dock"))
                    }
                }
                HStack {
                    Button("Add App…") { addApp() }
                    Button("Take the Apps from the System Dock") { model.useSystemDockApps() }
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("Drag an app from Finder onto the Dock to keep it there, or one icon onto another to reorder. Files dropped on an app open in it; dropped on the Trash, they go to the Trash.")
            }

            Section {
                ForEach(DockModel.Widget.allCases) { widget in
                    Toggle(isOn: Binding(
                        get: { model.widgets.contains(widget) },
                        set: { on in
                            if on { model.widgets.insert(widget) } else { model.widgets.remove(widget) }
                        }
                    )) {
                        Label { Text(widget.title) } icon: { Image(systemName: widget.symbol) }
                    }
                }
                if model.widgets.contains(.weather) {
                    HStack {
                        TextField("Town for the weather", text: $town)
                            .onSubmit { saveTown() }
                        if model.isLookingUpTown {
                            ProgressView().controlSize(.small)
                        }
                        Button("Save") { saveTown() }
                            .disabled(town.trimmingCharacters(in: .whitespaces).isEmpty || model.isLookingUpTown)
                    }
                    if model.weatherError {
                        Text("Open-Meteo did not answer, or does not know this town.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Widgets")
            } footer: {
                Text("Clock and system sit at the start of the Dock; music, calendar and weather at the end. While the music widget is on, Music and Spotify keep out of the Dock: a click on the cover opens the one playing. The weather comes from Open-Meteo, which needs no account: only the town, then its coordinates, are sent, at most every half hour. The calendar asks for access the first time, for the Dock's own part of UniMacHub.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dock & Widgets")
        .onAppear { town = model.weatherTown }
        .onChange(of: model.weatherTown) { _, name in town = name }
        .alert("Turn on UniMacHub's Dock?", isPresented: $confirmsEnabling) {
            Button("Turn On") { problem = DockService.turnOn(model) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS's own Dock cannot be removed, as it also runs Mission Control and ⌘Tab, so UniMacHub hides it with a delay so long it never comes up. Only Mission Control still shows it, on the same edge as this Dock, which steps aside there. Its settings are written down first and put back exactly when you turn this off. The apps now in the system Dock move across. macOS will say that UniMacHub added a background item: that is this Dock, which starts at login and keeps running when UniMacHub is closed.")
        }
    }

    @ViewBuilder
    private func problemView(_ problem: DockService.Problem) -> some View {
        switch problem {
        case .needsApproval:
            VStack(alignment: .leading, spacing: 6) {
                Label("macOS has UniMacHub's background items switched off", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Open Login Items, turn UniMacHub on under “Allow in the Background”, then turn the Dock on here again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
        case .missing:
            Label("This copy of UniMacHub was built without the Dock's part. Install it with scripts/install.sh.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case let .failed(reason):
            Label("macOS did not start the Dock: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func saveTown() {
        let name = town
        Task { await model.lookUpTown(name) }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(filePath: "/Applications")
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(model.pin)
    }
}

extension DockModel.Widget {
    var title: LocalizedStringKey {
        switch self {
        case .clock: "Clock"
        case .system: "System: processor, memory, network, temperature"
        case .music: "Music"
        case .calendar: "Calendar"
        case .weather: "Weather"
        }
    }

    var symbol: String {
        switch self {
        case .clock: "clock"
        case .system: "cpu"
        case .music: "music.note"
        case .calendar: "calendar"
        case .weather: "cloud.sun"
        }
    }
}

/// macOS's effect for minimising windows, which belongs to the system Dock and applies to
/// windows whichever Dock is showing.
enum MinimizeEffect: String {
    case genie, scale

    static var current: MinimizeEffect {
        MinimizeEffect(rawValue: UserDefaults(suiteName: SystemDock.domain)?.string(forKey: "mineffect") ?? "") ?? .genie
    }

    static func set(_ effect: MinimizeEffect) {
        guard effect != current else { return }
        Task.detached {
            SystemDock.apply([["write", SystemDock.domain, "mineffect", "-string", effect.rawValue]])
        }
    }
}
