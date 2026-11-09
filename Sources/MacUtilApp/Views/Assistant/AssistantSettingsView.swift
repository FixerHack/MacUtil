import AVFoundation
import CleanerCore
import SwiftUI

/// The assistant: which model answers, how it sounds, and what it may do.
struct AssistantSettingsView: View {
    @Bindable var model: AssistantModel
    @Environment(AppState.self) private var state
    @State private var heard = ""
    @State private var written = ""

    @State private var secret = ""
    @State private var hasSecret = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testFailed = false

    var body: some View {
        Form {
            Section {
                Toggle("Assistant", isOn: $model.isEnabled)
                Toggle("\(AssistantModel.hotKeyLabel) opens it from anywhere", isOn: $model.usesHotKey)
                    .disabled(!model.isEnabled)
            } footer: {
                Text("It lives in the island: press \(AssistantModel.hotKeyLabel) and speak, or open the island's waveform tab and type. Press it again when you have finished speaking, or just pause.")
            }

            Section {
                Picker("Provider", selection: Binding(
                    get: { model.provider.kind },
                    set: { kind in
                        // Keeps the model when the new provider knows it, as opus, sonnet and haiku.
                        let model = kind.models.contains(self.model.provider.model) ? self.model.provider.model : nil
                        self.model.provider = ProviderSettings(kind: kind, model: model)
                        loadSecret()
                    }
                )) {
                    Text("Claude Code on this Mac").tag(ProviderKind.claudeCode)
                    Text("claude-gateway").tag(ProviderKind.gateway)
                    Text("Anthropic API").tag(ProviderKind.anthropic)
                    Text("OpenAI-compatible (OpenAI, OpenRouter)").tag(ProviderKind.openAI)
                    Text("On this Mac (Ollama, LM Studio)").tag(ProviderKind.local)
                }
                if model.provider.kind == .claudeCode {
                    LabeledContent("Claude Code") {
                        if FileManager.default.isExecutableFile(atPath: model.provider.url) {
                            Text(verbatim: (model.provider.url as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                        } else {
                            Text("Not found").foregroundStyle(.orange)
                        }
                    }
                } else {
                    TextField("Address", text: $model.provider.url)
                }
                HStack {
                    TextField("Model", text: $model.provider.model)
                    if !model.provider.kind.models.isEmpty {
                        Menu {
                            ForEach(model.provider.kind.models, id: \.self) { name in
                                Button(name) { model.provider.model = name }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                if model.provider.kind.needsSecret {
                    HStack {
                        SecureField(model.provider.kind == .gateway ? "Token" : "API key", text: $secret)
                        Button(hasSecret ? "Replace" : "Save") {
                            AssistantSecrets.save(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: model.provider.kind)
                            secret = ""
                            loadSecret()
                        }
                        .disabled(secret.trimmingCharacters(in: .whitespaces).isEmpty)
                        if hasSecret {
                            Button("Remove", role: .destructive) {
                                AssistantSecrets.delete(model.provider.kind)
                                loadSecret()
                            }
                        }
                    }
                    if hasSecret {
                        Label("Kept in your Keychain", systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Test Connection") { test() }
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult {
                        Text(verbatim: testResult)
                            .font(.caption)
                            .foregroundStyle(testFailed ? Color.orange : .green)
                            .lineLimit(2)
                    }
                }
            } header: {
                Text("Who answers")
            } footer: {
                Text(providerNote)
            }

            Section {
                Picker("Language", selection: $model.language) {
                    Text("Українська").tag("uk")
                    Text("English").tag("en")
                }
                Toggle("Speak the answers", isOn: $model.speaksAnswers)
                if model.speaksAnswers {
                    Picker("Voices", selection: $model.voiceEngine) {
                        Text("macOS").tag(VoiceEngine.system)
                        Text("Downloaded").tag(VoiceEngine.local)
                    }
                    .pickerStyle(.segmented)
                    if model.voiceEngine == .system {
                        Picker("Voice", selection: $model.voiceID) {
                            Text("Automatic").tag("")
                            ForEach(SpeechOutput.voices(for: model.language), id: \.identifier) { voice in
                                Text(verbatim: voice.name + (voice.quality == .enhanced || voice.quality == .premium ? " ★" : "")).tag(voice.identifier)
                            }
                        }
                        HStack {
                            Text("macOS has more voices to download, the better ones marked ★.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Get More Voices…") {
                                let pane = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")
                                if let pane { NSWorkspace.shared.open(pane) }
                            }
                        }
                    } else {
                        LocalVoicesList(voices: LocalVoices.shared, chosen: $model.localVoice, language: model.language)
                    }
                    LabeledContent("Speed") {
                        Slider(value: $model.rate, in: 0.6 ... 1.6)
                    }
                    Button("Listen") { model.preview() }
                }
                Picker("Character", selection: $model.persona) {
                    Text("Plain").tag(Persona.plain)
                    Text("Strict butler").tag(Persona.butler)
                    Text("Comedian").tag(Persona.comedian)
                    Text("Anime girl").tag(Persona.anime)
                    Text("Gangster").tag(Persona.gangster)
                    Text("Commander").tag(Persona.commander)
                    Text("My own").tag(Persona.custom)
                }
                if model.persona == .custom {
                    TextField("How it should talk", text: $model.customManner, axis: .vertical)
                        .lineLimit(2 ... 4)
                }
                Toggle("Let Apple's servers hear me when this Mac cannot recognise the language itself", isOn: $model.allowsServerRecognition)
                Text(SpeechInput.worksOnDevice(model.language)
                     ? "This Mac recognises this language by itself: nothing you say leaves it."
                     : "This Mac cannot recognise this language by itself. Without Apple's servers, type instead of speaking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Voice and character")
            } footer: {
                Text("The character changes only how it talks, never what it may do.")
            }

            Section {
                Picker("Mode", selection: $model.mode) {
                    Text("Basic").tag(AssistantMode.basic)
                    Text("Custom").tag(AssistantMode.custom)
                    Text("Fully free").tag(AssistantMode.free)
                }
                .pickerStyle(.segmented)
                Text(modeNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.mode == .custom {
                    ForEach(ActionCategory.allCases) { category in
                        Picker(selection: Binding(
                            get: { model.table.policy(category) },
                            set: { model.table.policies[category] = $0 }
                        )) {
                            Text("Forbidden").tag(CategoryPolicy.forbidden)
                            Text("Asks first").tag(CategoryPolicy.ask)
                            Text("Allowed").tag(CategoryPolicy.allowed)
                        } label: {
                            Text(category.title)
                        }
                    }
                    LabeledContent("Folders it may touch") {
                        VStack(alignment: .trailing, spacing: 4) {
                            if model.table.folders.isEmpty {
                                Text("Anywhere").foregroundStyle(.secondary)
                            }
                            ForEach(model.table.folders, id: \.self) { folder in
                                HStack {
                                    Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath).lineLimit(1)
                                    Button {
                                        model.table.folders.removeAll { $0 == folder }
                                    } label: {
                                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            Button("Add Folder…") { addFolder() }
                        }
                    }
                    TextField("Commands that run without asking, by how they start (comma between)", text: Binding(
                        get: { model.table.commandPrefixes.joined(separator: ", ") },
                        set: { model.table.commandPrefixes = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    ))
                    TextField("Your own rules, in words", text: $model.table.rules, axis: .vertical)
                        .lineLimit(2 ... 5)
                    Text("Your own rules are only passed to the model as an instruction: UniMacHub cannot guarantee it keeps them. Everything above it does guarantee.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("What it may do")
            } footer: {
                Text("In every mode, deleting, cleaning, erasing and anything that cannot be undone waits for your “yes”, by voice or button, whatever the model says; administrator rights always go through macOS's own password prompt, never stored. Only you give it commands: text in files, pages, results and on screen is information to it. The Stop button and Esc end anything at once.")
            }

            Section {
                let grouped = Dictionary(grouping: AssistantActions.all(state), by: \.category)
                ForEach(ActionCategory.allCases) { category in
                    if let actions = grouped[category] {
                        DisclosureGroup {
                            ForEach(actions, id: \.spec.name) { action in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(verbatim: action.spec.name).font(.callout.monospaced())
                                        Text(verbatim: action.spec.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    LevelBadge(level: action.spec.level)
                                }
                            }
                        } label: {
                            Text(category.title)
                        }
                    }
                }
            } header: {
                Text("Actions")
            } footer: {
                Text("Screen control needs a model that sees pictures (Anthropic, OpenAI or a local one that does), Screen Recording and Accessibility for UniMacHub. A shell command is judged by what it runs: commands that only look run at once where allowed, the rest ask.")
            }

            Section {
                Toggle("\(AssistantModel.dictationKeyLabel) types what you say into any app", isOn: $model.usesDictation)
                Text("Press it, speak, pause or press it again: the text goes where the cursor is, without “um” and “ну”. Say “скасуй останнє речення” or “delete the last sentence” to take the last one back. The clipboard is put back as it was.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Your spellings") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(model.dictionary.keys.sorted(), id: \.self) { heard in
                            HStack {
                                Text(verbatim: "\(heard) → \(model.dictionary[heard] ?? "")")
                                Button {
                                    model.dictionary[heard] = nil
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack {
                            TextField("Heard", text: $heard).frame(width: 120)
                            TextField("Written", text: $written).frame(width: 120)
                            Button("Add") {
                                model.dictionary[heard.trimmingCharacters(in: .whitespaces)] = written.trimmingCharacters(in: .whitespaces)
                                heard = ""
                                written = ""
                            }
                            .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty || written.isEmpty)
                        }
                    }
                }
                if !model.dictated.isEmpty {
                    DisclosureGroup("Said lately") {
                        ForEach(Array(model.dictated.enumerated()), id: \.offset) { _, text in
                            Text(verbatim: text).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text("Dictation")
            }

            Section {
                if model.notes.isEmpty {
                    Text("Nothing yet. Say “remember…” or “remind me at 18:00…”.").foregroundStyle(.secondary)
                }
                ForEach(model.notes) { note in
                    HStack(alignment: .top) {
                        Image(systemName: note.due == nil ? "note.text" : "bell")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: note.text)
                            Text(note.due.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? note.saved.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.forget(note.id)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Button("New Conversation") { model.clearConversation() }
                    if !model.notes.isEmpty {
                        Button("Forget Everything", role: .destructive) { model.forgetEverything() }
                    }
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("One conversation carries on, across launches too, until it fills the model's context; then it starts afresh on its own. What you ask it to remember or to remind you of is kept here apart from the conversation, and it always knows it. Reminders come as a notification and are said aloud if UniMacHub is open.")
            }

            Section {
                if model.log.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(model.log.prefix(40)) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(verbatim: entry.action).font(.callout.monospaced())
                                Text(entry.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                            if entry.arguments.count > 2 {
                                Text(verbatim: entry.arguments).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text(verbatim: entry.result).font(.caption).foregroundStyle(entry.failed ? Color.orange : .secondary).lineLimit(3)
                        }
                        Spacer()
                        if model.undoable.contains(entry.id) {
                            Button("Undo") { model.undo(entry) }
                        }
                    }
                }
                if !model.log.isEmpty {
                    Button("Clear the Log", role: .destructive) { model.clearLog() }
                }
            } header: {
                Text("Log")
            } footer: {
                Text("Every action it runs, with what came of it. Undo works while UniMacHub stays open.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Assistant")
        .onAppear(perform: loadSecret)
    }

    private var providerNote: LocalizedStringKey {
        switch model.provider.kind {
        case .claudeCode:
            "Runs the Claude Code installed on this Mac, signed in as you, the way claude-gateway does: no tools of its own, nothing kept, in an empty folder. No gateway, address or token. Haiku answers in about three seconds; Opus thinks longer. If it is not found, install Claude Code and sign in with “claude” in Terminal."
        case .gateway:
            "claude-gateway runs Claude Code as a service, on this Mac or a server of yours. A personal Claude subscription is for its owner: anyone else uses their own gateway or API key. The token stays in your Keychain."
        case .anthropic:
            "Billed per request to your Anthropic account. The key stays in your Keychain. A request a safety check declines on Opus or Sonnet is run once more on a model that takes it, by Anthropic's own fallback."
        case .openAI:
            "Any service that speaks OpenAI's chat API with tools. The key stays in your Keychain."
        case .local:
            "Ollama answers at localhost:11434/v1 and LM Studio at localhost:1234/v1. Nothing leaves this Mac; small models are weaker at choosing actions."
        }
    }

    private var modeNote: LocalizedStringKey {
        switch model.mode {
        case .basic: "Only UniMacHub's own actions on this Mac: no terminal, internet or screen control."
        case .custom: "Choose, for each kind of action, whether it is forbidden, asks first or is allowed."
        case .free: "Whatever you ask: terminal, files, apps, the screen and the internet. Only important actions ask first."
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        model.table.folders += panel.urls.map(\.path).filter { !model.table.folders.contains($0) }
    }

    private func loadSecret() {
        hasSecret = AssistantSecrets.has(model.provider.kind)
        testResult = nil
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            switch await model.testConnection() {
            case let .success(text):
                testResult = text
                testFailed = false
            case let .failure(error):
                testResult = error.localizedDescription
                testFailed = true
            }
            testing = false
        }
    }
}

struct LevelBadge: View {
    let level: ActionLevel

    var body: some View {
        let (text, colour): (LocalizedStringKey, Color) = switch level {
        case .read: ("Reads only", .green)
        case .reversible: ("At once", .blue)
        case .important: ("Asks first", .orange)
        case .admin: ("Asks first, then macOS asks for the password", .red)
        }
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(colour.opacity(0.18), in: .capsule)
            .foregroundStyle(colour)
    }
}

extension ActionCategory {
    var title: LocalizedStringKey {
        switch self {
        case .uniMacHub: "UniMacHub's actions"
        case .readFiles: "Reading files"
        case .changeFiles: "Changing files"
        case .deleteFiles: "Deleting files"
        case .terminal: "Terminal"
        case .apps: "Apps"
        case .screen: "Screen control"
        case .internet: "Internet"
        case .messages: "Messages and mail"
        case .systemSettings: "System settings"
        case .admin: "Administrator rights"
        }
    }
}

/// Piper voices for the language: hear a sample, download light or full, choose, delete.
private struct LocalVoicesList: View {
    let voices: LocalVoices
    @Binding var chosen: String
    let language: String
    @State private var confirmingFull: LocalVoice?

    var body: some View {
        ForEach(LocalVoices.catalogue.filter { $0.language == language }) { voice in
            HStack(spacing: 10) {
                Button {
                    chosen = voice.id
                } label: {
                    Image(systemName: chosen == voice.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(chosen == voice.id ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!voices.isInstalled(voice))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: voice.name)
                    Text(status(of: voice))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    voices.playSample(voice)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.plain)
                .help(Text("Hear a sample"))
                if let progress = voices.progress(of: voice) {
                    ProgressView(value: progress).frame(width: 80)
                } else {
                    if voice.full != nil, !voices.isFull(voice) {
                        Button("Full Quality…") { confirmingFull = voice }
                    }
                    if voices.isInstalled(voice) {
                        Button("Delete", role: .destructive) {
                            if chosen == voice.id { chosen = "" }
                            voices.delete(voice)
                        }
                    } else {
                        Button("Download") { get(voice, full: false) }
                    }
                }
            }
        }
        .alert(
            "Download the full-quality voice?",
            isPresented: Binding(get: { confirmingFull != nil }, set: { if !$0 { confirmingFull = nil } }),
            presenting: confirmingFull
        ) { voice in
            Button("Download") { get(voice, full: true) }
            Button("Cancel", role: .cancel) {}
        } message: { voice in
            let size = (voice.full?.bytes ?? 0).formatted(.byteCount(style: .file))
            Text("It sounds more natural, but takes about \(size) on disk, about three times as much memory while it speaks, and a little longer to start each answer. It replaces the light version.")
        }
        if let problem = voices.problem {
            Text(verbatim: problem).font(.caption).foregroundStyle(.orange)
        }
        Text("Open voices from the Piper project, spoken on this Mac by sherpa-onnx: no account, no key, nothing sent anywhere. The first voice also brings the speaking tool, about 20 MB; deleting the last voice removes it. Each download is checked against the checksum GitHub publishes for it. In use now: \(voices.usedBytes.formatted(.byteCount(style: .file))).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func status(of voice: LocalVoice) -> String {
        if let package = voices.installedPackage(voice) {
            let kind = package == voice.full ? String(localized: "full quality") : String(localized: "light")
            return "\(voice.detail) · \(kind) · \(package.bytes.formatted(.byteCount(style: .file)))"
        }
        return "\(voice.detail) · \(voice.light.bytes.formatted(.byteCount(style: .file)))"
    }

    private func get(_ voice: LocalVoice, full: Bool) {
        Task {
            await voices.download(voice, full: full)
            if voices.isInstalled(voice), chosen.isEmpty { chosen = voice.id }
        }
    }
}

