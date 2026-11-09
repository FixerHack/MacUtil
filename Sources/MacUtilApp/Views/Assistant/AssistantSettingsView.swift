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
                Toggle("A shortcut that listens at once, from anywhere", isOn: $model.usesHotKey)
                    .disabled(!model.isEnabled)
                if model.usesHotKey {
                    LabeledContent("Shortcut") {
                        ShortcutRecorder(shortcut: $model.shortcut, fallback: .assistant, model: model)
                    }
                }
            } footer: {
                Text("Press \(model.hotKeyLabel) and speak: it listens at once, and acts when you pause. Or hold it while you speak and let go to send. Press it again to stop listening, or while it talks to interrupt. It also lives in the island's waveform tab, to type.")
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
                        LocalVoicesList(voices: LocalVoices.shared, chosen: $model.localVoice, language: model.language, rate: model.rate)
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
                Toggle("\(model.dictationKeyLabel) types what you say into any app", isOn: $model.usesDictation)
                if model.usesDictation {
                    LabeledContent("Dictation shortcut") {
                        ShortcutRecorder(shortcut: $model.dictationShortcut, fallback: .dictation, model: model)
                    }
                }
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

/// The downloadable voices: the voice in a menu on the right, marked by gender and
/// whether it is on this Mac, and what to do with it on the left.
private struct LocalVoicesList: View {
    let voices: LocalVoices
    @Binding var chosen: String
    let language: String
    let rate: Double
    @State private var confirmingFull = false
    @State private var confirmingHolos = false
    @State private var cloning = false
    private var holos: HolosEngine { HolosEngine.shared }

    private var choices: [LocalVoice] { voices.voices(for: language) }
    private var current: LocalVoice? { choices.first { $0.id == chosen } }

    var body: some View {
        HStack(spacing: 8) {
            if let voice = current {
                Button {
                    voices.isPlaying ? voices.stopPlaying() : voices.listen(voice, language: language, rate: rate)
                } label: {
                    Label(voices.isPlaying ? "Stop" : "Listen", systemImage: voices.isPlaying ? "stop.fill" : "play.fill")
                }
                .disabled(!voices.canListen(voice) && !voices.isPlaying)
                .help(voices.canListen(voice) ? Text("Hear this voice") : Text("This voice has no published sample: download it to hear it"))

                if let progress = voices.progress(of: voice) {
                    ProgressView(value: progress).frame(width: 90)
                    Button {
                        voices.cancelDownload(voice)
                    } label: {
                        Label("Stop", systemImage: "xmark.circle.fill")
                    }
                } else if voices.isInstalled(voice) {
                    if voice.full != nil, !voices.isFull(voice) {
                        Button("Full Quality…") { confirmingFull = true }
                    }
                    Button(role: .destructive) {
                        voices.delete(voice)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } else {
                    Button {
                        if voice.model == .holos { confirmingHolos = true } else { voices.download(voice) }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    if voice.full != nil {
                        Button("Full Quality…") { confirmingFull = true }
                    }
                }
            }
            Spacer(minLength: 12)
            Picker("Voice", selection: $chosen) {
                if current == nil { Text("Choose a voice").tag(chosen) }
                ForEach(choices) { voice in
                    Text(verbatim: label(voice)).tag(voice.id)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .alert("Install HolosTTS?", isPresented: $confirmingHolos) {
            Button("Install") { holos.install() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The most natural Ukrainian voices, and your own voice from a recording. It needs its own Python with PyTorch: about 2.6 GB on disk, and about 1.5 GB of memory while it speaks, given back after ten quiet minutes. It downloads from GitHub, PyPI and Hugging Face, takes a while, and can be stopped; deleting removes all of it.")
        }
        .sheet(isPresented: $cloning) {
            VoiceCloneSheet { voice in chosen = "holos-" + voice.name }
        }
        .alert("Download the full-quality voice?", isPresented: $confirmingFull, presenting: current) { voice in
            Button("Download") { voices.download(voice, full: true) }
            Button("Cancel", role: .cancel) {}
        } message: { voice in
            let size = (voice.full?.bytes ?? 0).formatted(.byteCount(style: .file))
            Text("It sounds more natural, but takes about \(size) on disk, about three times as much memory while it speaks, and a little longer to start each answer. It replaces the light version.")
        }
        if let voice = current {
            Text(status(of: voice))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let stage = holos.stage {
            Text(verbatim: stage).font(.caption).foregroundStyle(.secondary)
        }
        if let problem = holos.problem {
            Text(verbatim: problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
        if holos.isInstalled, language == "uk" {
            Button("Make My Voice…") { cloning = true }
        }
        if let problem = voices.problem {
            Text(verbatim: problem).font(.caption).foregroundStyle(.orange)
        }
        Text("Open voices spoken on this Mac by sherpa-onnx: Supertonic 3 (Ukrainian and English, five women and five men), Kokoro (natural English), Piper. No account, no key, nothing sent anywhere. The first voice also brings the speaking tool, about 20 MB; deleting the last voice removes it. Each download is checked against the checksum GitHub publishes for it. In use now: \(voices.usedBytes.formatted(.byteCount(style: .file))).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// "♀ Supertonic F1 · Supertonic 3 · 129 MB ✓"
    private func label(_ voice: LocalVoice) -> String {
        let sign = voice.gender == .female ? "♀" : "♂"
        let size = (voices.installedPackage(voice) ?? voice.light).bytes.formatted(.byteCount(style: .file))
        return "\(sign) \(voice.name) · \(voice.detail) · \(size)" + (voices.isInstalled(voice) ? " ✓" : "")
    }

    private func status(of voice: LocalVoice) -> String {
        let gender = voice.gender == .female ? String(localized: "female") : String(localized: "male")
        var parts = [gender, voice.detail]
        if let package = voices.installedPackage(voice) {
            parts.append(package == voice.full ? String(localized: "full quality, on this Mac") : String(localized: "light, on this Mac"))
        } else {
            parts.append(String(localized: "not downloaded: until it is, macOS's voice speaks"))
        }
        let others = voices.sharing(voice)
        if others > 0 { parts.append(String(localized: "downloads together with \(others) other voices")) }
        return parts.joined(separator: " · ")
    }
}

/// A voice of the person's own for HolosTTS: they read a passage aloud, or pick a recording.
private struct VoiceCloneSheet: View {
    let made: (HolosEngine.Voice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = String(localized: "My voice")
    @State private var recorder: AVAudioRecorder?
    @State private var recording: URL?
    @State private var working = false
    @State private var seconds = 0

    static let passage = "Добрий день! Мене звати так, як написано вище, і зараз я записую свій голос. Я говорю спокійно і чітко, як у звичайній розмові. Сьогодні гарна погода, тож після роботи я, мабуть, прогуляюся парком і вип'ю кави. А ввечері почитаю книжку або подивлюся фільм."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make my voice").font(.title2.weight(.semibold))
            Text("Read this aloud in a quiet room, at your usual pace, about 20 seconds. Or pick a clear recording of one voice, without music.")
                .foregroundStyle(.secondary)
            Text(verbatim: Self.passage)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            TextField("Name", text: $name)
            HStack {
                if recorder?.isRecording == true {
                    Button("Stop Recording") { finish() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    Text(verbatim: "● \(seconds) s").foregroundStyle(.red).monospacedDigit()
                } else {
                    Button("Record") { record() }
                    Button("Choose a Recording…") { choose() }
                }
                Spacer()
                if let recording {
                    Text(verbatim: recording.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let problem = HolosEngine.shared.problem {
                Text(verbatim: problem).font(.caption).foregroundStyle(.orange)
            }
            Text("The recording stays on this Mac; HolosTTS turns it into 256 numbers that describe the voice. Make voices only of yourself, or of someone who agreed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    create()
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Make the Voice") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(recording == nil || working || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func record() {
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return }
            let file = FileManager.default.temporaryDirectory.appending(path: "unimachub-voice-sample.wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ]
            guard let recorder = try? AVAudioRecorder(url: file, settings: settings) else { return }
            recorder.record()
            self.recorder = recorder
            recording = nil
            seconds = 0
            while recorder.isRecording {
                try? await Task.sleep(for: .seconds(1))
                seconds += 1
                if seconds >= 40 { finish() }
            }
        }
    }

    private func finish() {
        guard let recorder else { return }
        recorder.stop()
        recording = recorder.url
        self.recorder = nil
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK else { return }
        recording = panel.url
    }

    private func create() {
        guard let recording else { return }
        working = true
        Task {
            if let voice = await HolosEngine.shared.clone(recording, name: name.trimmingCharacters(in: .whitespaces)) {
                made(voice)
                dismiss()
            }
            working = false
        }
    }
}

/// Records a shortcut: click, then press the keys. Esc leaves it as it was.
private struct ShortcutRecorder: View {
    @Binding var shortcut: AssistantModel.Shortcut
    let fallback: AssistantModel.Shortcut
    let model: AssistantModel
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? String(localized: "Press the keys…") : shortcut.label)
                    .monospaced()
                    .frame(minWidth: 90)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if !recording {
                if shortcut != fallback {
                    Button("Reset") { shortcut = fallback }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        model.pauseHotKeys(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            if let recorded = AssistantModel.Shortcut(event: event) {
                shortcut = recorded
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { model.pauseHotKeys(false) }
        recording = false
    }
}

