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
                        model.provider = ProviderSettings(kind: kind)
                        loadSecret()
                    }
                )) {
                    Text("claude-gateway").tag(ProviderKind.gateway)
                    Text("Anthropic API").tag(ProviderKind.anthropic)
                    Text("OpenAI-compatible (OpenAI, OpenRouter)").tag(ProviderKind.openAI)
                    Text("On this Mac (Ollama, LM Studio)").tag(ProviderKind.local)
                }
                TextField("Address", text: $model.provider.url)
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
                    Picker("Voice", selection: $model.voiceID) {
                        Text("Automatic").tag("")
                        ForEach(SpeechOutput.voices(for: model.language), id: \.identifier) { voice in
                            Text(verbatim: voice.name + (voice.quality == .enhanced || voice.quality == .premium ? " ★" : "")).tag(voice.identifier)
                        }
                    }
                    LabeledContent("Speed") {
                        Slider(value: $model.rate, in: 0.6 ... 1.6)
                    }
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

