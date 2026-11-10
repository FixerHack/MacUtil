import AppKit
import Carbon.HIToolbox
import CleanerCore
import Observation
import UserNotifications

/// The assistant: its settings, the conversation, the loop that runs actions, the log of
/// what it did, and dictation into other apps.
///
/// Commands come only from the person, typed or spoken. What an action returns goes back to
/// the model as information; whether an action runs, waits for "yes" or is refused is
/// decided here, from the action's level and kind and the mode, whatever the model says.
@MainActor
@Observable
final class AssistantModel {
    enum Phase: Equatable {
        case idle, listening, thinking, speaking
        case confirming(String)
    }

    struct Line: Identifiable, Equatable, Codable {
        enum Kind: String, Codable { case person, assistant, action, problem }
        var id = UUID()
        let kind: Kind
        let text: String
    }

    /// One action it ran, for the log.
    struct LogEntry: Identifiable, Codable, Equatable {
        var id = UUID()
        let date: Date
        let action: String
        let arguments: String
        let result: String
        let failed: Bool
    }

    enum Keys {
        static let enabled = "assistantEnabled"
        static let provider = "assistantProvider"
        static let language = "assistantLanguage"
        static let speaks = "assistantSpeaks"
        static let voice = "assistantVoice"
        static let rate = "assistantRate"
        static let persona = "assistantPersona"
        static let manner = "assistantCustomManner"
        static let server = "assistantServerRecognition"
        static let hotKey = "assistantHotKey"
        static let mode = "assistantMode"
        static let table = "assistantPermissions"
        static let dictation = "assistantDictation"
        static let dictionary = "assistantDictionary"
        static let engine = "assistantVoiceEngine"
        static let localVoice = "assistantLocalVoice"
        static let shortcut = "assistantShortcut"
        static let pitch = "assistantPitch"
        static let dictationShortcut = "assistantDictationShortcut"
    }

    // MARK: - Settings

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled); updateHotKeys() } }
    var provider: ProviderSettings { didSet { defaults.set(try? JSONEncoder().encode(provider), forKey: Keys.provider) } }
    /// "uk" or "en", for hearing and for answering.
    var language: String { didSet { defaults.set(language, forKey: Keys.language) } }
    var speaksAnswers: Bool { didSet { defaults.set(speaksAnswers, forKey: Keys.speaks) } }
    var voiceID: String { didSet { defaults.set(voiceID, forKey: Keys.voice) } }
    var voiceEngine: VoiceEngine { didSet { defaults.set(voiceEngine.rawValue, forKey: Keys.engine) } }
    /// The downloaded voice chosen, by its catalogue id.
    var localVoice: String { didSet { defaults.set(localVoice, forKey: Keys.localVoice) } }
    /// Semitones above the voice's own: a few up gives the bright, light voice of anime.
    var pitch: Double { didSet { defaults.set(pitch, forKey: Keys.pitch); output.pitch = pitch } }
    var rate: Double { didSet { defaults.set(rate, forKey: Keys.rate) } }
    var persona: Persona { didSet { defaults.set(persona.rawValue, forKey: Keys.persona) } }
    var customManner: String { didSet { defaults.set(customManner, forKey: Keys.manner) } }
    /// Apple's servers may hear the person when this Mac cannot do the language itself.
    var allowsServerRecognition: Bool { didSet { defaults.set(allowsServerRecognition, forKey: Keys.server) } }
    var usesHotKey: Bool { didSet { defaults.set(usesHotKey, forKey: Keys.hotKey); updateHotKeys() } }
    var mode: AssistantMode { didSet { defaults.set(mode.rawValue, forKey: Keys.mode) } }
    var table: PermissionTable { didSet { defaults.set(try? JSONEncoder().encode(table), forKey: Keys.table) } }
    var usesDictation: Bool { didSet { defaults.set(usesDictation, forKey: Keys.dictation); updateHotKeys() } }
    /// Words macOS hears one way and the person writes another: heard → written.
    var dictionary: [String: String] { didSet { defaults.set(dictionary, forKey: Keys.dictionary) } }

    // MARK: - The conversation

    private(set) var phase = Phase.idle
    private(set) var lines: [Line] = []
    /// What is being heard right now.
    private(set) var hearing = ""
    var draft = ""
    /// Bumped to put the typing field in focus.
    private(set) var focusRequest = 0
    private(set) var log: [LogEntry] = []
    /// Entries that can still be undone, this session.
    private(set) var undoable: Set<UUID> = []
    private(set) var isDictating = false
    /// The microphone's loudness, 0…1, for the animation.
    private(set) var level: Double = 0
    /// What it was asked to remember, and reminders.
    private(set) var notes: [AssistantContext.Note] = []
    private(set) var dictated: [String] = []

    var isBusy: Bool { phase != .idle }

    /// Opens the island on the assistant; set by the island's controller.
    @ObservationIgnored var present: (() -> Void)?
    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var turns: [ConversationTurn] = []
    @ObservationIgnored private var reminderTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var answer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let input = SpeechInput()
    @ObservationIgnored private let output = SpeechOutput()
    @ObservationIgnored private var undos: [UUID: @MainActor () async -> String] = [:]
    @ObservationIgnored private var hotKeys: [EventHotKeyRef] = []
    @ObservationIgnored private var hotKeyHandler: EventHandlerRef?
    @ObservationIgnored private var lastInserted = ""

    static let logFile = AppPaths.file("assistant-log.json")
    static let chatFile = AppPaths.file("assistant-chat.json")
    static let memoryFile = AppPaths.file("assistant-memory.json")

    private struct Chat: Codable {
        var turns: [ConversationTurn]
        var lines: [Line]
    }

    init() {
        defaults.register(defaults: [
            Keys.enabled: true, Keys.speaks: true, Keys.rate: 1.0, Keys.hotKey: true, Keys.dictation: true,
            Keys.language: Locale.current.language.languageCode?.identifier == "uk" ? "uk" : "en",
            Keys.mode: AssistantMode.basic.rawValue,
        ])
        isEnabled = defaults.bool(forKey: Keys.enabled)
        provider = defaults.data(forKey: Keys.provider).flatMap { try? JSONDecoder().decode(ProviderSettings.self, from: $0) }
            ?? ProviderSettings(kind: ClaudeCodeRunner.find() != nil ? .claudeCode : .gateway)
        language = defaults.string(forKey: Keys.language) ?? "en"
        speaksAnswers = defaults.bool(forKey: Keys.speaks)
        voiceID = defaults.string(forKey: Keys.voice) ?? ""
        voiceEngine = VoiceEngine(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .system
        localVoice = defaults.string(forKey: Keys.localVoice) ?? ""
        pitch = defaults.double(forKey: Keys.pitch)
        shortcut = defaults.data(forKey: Keys.shortcut).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .assistant
        dictationShortcut = defaults.data(forKey: Keys.dictationShortcut).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .dictation
        rate = defaults.double(forKey: Keys.rate)
        persona = Persona(rawValue: defaults.string(forKey: Keys.persona) ?? "") ?? .plain
        customManner = defaults.string(forKey: Keys.manner) ?? ""
        allowsServerRecognition = defaults.bool(forKey: Keys.server)
        usesHotKey = defaults.bool(forKey: Keys.hotKey)
        mode = AssistantMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .basic
        table = defaults.data(forKey: Keys.table).flatMap { try? JSONDecoder().decode(PermissionTable.self, from: $0) } ?? PermissionTable()
        usesDictation = defaults.bool(forKey: Keys.dictation)
        dictionary = defaults.dictionary(forKey: Keys.dictionary) as? [String: String] ?? [:]
        log = (try? Data(contentsOf: Self.logFile)).flatMap { try? JSONDecoder().decode([LogEntry].self, from: $0) } ?? []
        // One conversation that carries on across launches.
        if let chat = (try? Data(contentsOf: Self.chatFile)).flatMap({ try? JSONDecoder().decode(Chat.self, from: $0) }) {
            turns = chat.turns
            lines = chat.lines
        }
        notes = (try? Data(contentsOf: Self.memoryFile)).flatMap { try? JSONDecoder().decode([AssistantContext.Note].self, from: $0) } ?? []
        for note in notes where note.due.map({ $0 > Date() }) == true { scheduleSpoken(note) }
        output.pitch = pitch
        input.onText = { [weak self] text, final in self?.heard(text, final: final) }
        input.onFailure = { [weak self] problem in
            guard let self else { return }
            if problem.contains("kLSRErrorDomain 201") || problem.localizedCaseInsensitiveContains("Dictation are disabled") {
                // macOS lets an app hear speech only with Dictation on: say so, and open the place.
                self.say(String(localized: "macOS lets apps hear speech only with Dictation on. Turn on Dictation in the window that opened (Keyboard → Dictation), then press the shortcut again."), kind: .problem)
                if let pane = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(pane) }
            } else {
                self.say(String(localized: "Listening stopped: \(problem)"), kind: .problem)
            }
        }
        input.onLevel = { [weak self] level in
            guard let self else { return }
            // Quick to rise, slower to fall, so the wave breathes rather than flickers.
            self.level = level > self.level ? level : self.level * 0.75 + level * 0.25
        }
        output.onFinished = { [weak self] in
            guard let self, self.phase == .speaking else { return }
            self.phase = .idle
        }
    }

    func attach(_ state: AppState) {
        self.state = state
        updateHotKeys()
    }

    // MARK: - Asking

    /// From the hot key or the island: listens, or stops listening and sends what was heard.
    func activate() {
        guard isEnabled else { return }
        if isDictating { input.finish(); return }
        present?()
        switch phase {
        case .listening: input.finish()
        case .speaking: output.stop(); phase = .idle
        case .idle: listen()
        default: break
        }
    }

    func listen() {
        output.stop()
        Task {
            guard await startHearing() else { return }
            hearing = ""
            phase = .listening
        }
    }

    /// Starts the microphone, or says why it cannot.
    private func startHearing() async -> Bool {
        if !SpeechInput.isAuthorised, !(await SpeechInput.authorise()) {
            say(String(localized: "I need the microphone and speech recognition: allow them in System Settings → Privacy & Security."), kind: .problem)
            focusRequest += 1
            return false
        }
        do {
            try input.start(language: language, allowServer: allowsServerRecognition)
            return true
        } catch SpeechInput.Problem.needsServer {
            say(String(localized: "This Mac cannot recognise this language by itself. Allow Apple's speech servers in the Assistant's settings, or type instead."), kind: .problem)
        } catch {
            SpeechInput.note("did not start: \(error)")
            say(String(localized: "Listening did not start. Type instead, or check the microphone.") + " (\(error.localizedDescription))", kind: .problem)
        }
        focusRequest += 1
        return false
    }

    private func heard(_ text: String, final: Bool) {
        hearing = text
        guard final else { return }
        hearing = ""
        if isDictating {
            isDictating = false
            insertDictation(text)
            return
        }
        if case .confirming = phase {
            answerByVoice(text)
            return
        }
        phase = .idle
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { ask(said) }
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        ask(text)
    }

    /// The standing instructions for the mode, with what it remembers and, in custom mode,
    /// the person's own rules.
    private var system: String {
        var text = AssistantPrompt.system(language: language, persona: persona, customManner: customManner)
        let memory = AssistantContext.memory(notes)
        if !memory.isEmpty { text += "\n" + memory }
        if mode == .custom, !table.rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\nThe person's own rules, which you follow:\n" + table.rules
        }
        return text
    }

    /// The person's words, to the model, and round the loop until it has nothing more to run.
    func ask(_ text: String) {
        guard let state else { return }
        stop()
        // One conversation throughout; when it would fill the model's context, it starts over.
        // What should outlive that belongs in the notes, which are always sent.
        if AssistantContext.size(of: turns) + text.count > AssistantContext.limit(for: provider.kind) {
            turns = []
            lines.append(Line(kind: .action, text: String(localized: "The conversation filled the model's memory, so it starts afresh. Notes are kept.")))
        }
        lines.append(Line(kind: .person, text: text))
        turns.append(.user(text))
        saveChat()
        phase = .thinking
        let client = AssistantClient(settings: provider, secret: AssistantSecrets.load(provider.kind))
        let system = system
        work = Task { [weak self] in
            for _ in 0 ..< 12 {
                guard let self, !Task.isCancelled else { return }
                let actions = AssistantActions.available(state, mode: self.mode, table: self.table, seesImages: self.provider.kind.seesImages)
                let reply: ModelReply
                do {
                    reply = try await client.reply(system: system, turns: self.turns, actions: actions.map(\.spec))
                } catch {
                    guard !Task.isCancelled else { return }
                    self.say(error.localizedDescription, kind: .problem)
                    self.phase = .idle
                    return
                }
                guard !Task.isCancelled else { return }
                if reply.refused {
                    self.say(String(localized: "The model declined this request."), kind: .problem)
                    self.phase = .idle
                    return
                }
                self.turns.append(.assistant(text: reply.text, calls: reply.calls, raw: reply.raw))
                if !reply.text.isEmpty { self.say(reply.text, kind: .assistant) }
                guard !reply.calls.isEmpty else { break }
                for call in reply.calls {
                    let outcome = await self.perform(call, actions: actions, state: state)
                    guard !Task.isCancelled else { return }
                    self.turns.append(.result(callID: call.id, name: call.name, text: outcome.text, failed: outcome.failed, image: outcome.image))
                }
                self.phase = .thinking
            }
            guard let self else { return }
            if self.phase == .thinking { self.phase = self.output.isSpeaking ? .speaking : .idle }
            self.saveChat()
        }
    }

    private func saveChat() {
        try? FileManager.default.createDirectory(at: Self.chatFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Pictures are dropped from what is kept: they are large, and old screens say little.
        let kept = turns.map { turn -> ConversationTurn in
            if case let .result(id, name, text, failed, image) = turn, image != nil {
                return .result(callID: id, name: name, text: text + " [screenshot not kept]", failed: failed)
            }
            return turn
        }
        try? JSONEncoder().encode(Chat(turns: kept, lines: Array(lines.suffix(60)))).write(to: Self.chatFile, options: .atomic)
    }

    // MARK: - Memory

    @discardableResult
    func remember(_ text: String, due: Date? = nil) -> AssistantContext.Note {
        let note = AssistantContext.Note(text: text, due: due)
        notes.append(note)
        saveNotes()
        if due != nil { schedule(note) }
        return note
    }

    func forget(_ id: UUID) {
        notes.removeAll { $0.id == id }
        reminderTasks.removeValue(forKey: id)?.cancel()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        saveNotes()
    }

    func forgetEverything() {
        for note in notes { forget(note.id) }
    }

    private func saveNotes() {
        try? FileManager.default.createDirectory(at: Self.memoryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(notes).write(to: Self.memoryFile, options: .atomic)
    }

    /// A notification at the time, and said aloud too if UniMacHub is open then.
    private func schedule(_ note: AssistantContext.Note) {
        guard let due = note.due else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Reminder")
            content.body = note.text
            content.sound = .default
            let seconds = max(1, due.timeIntervalSinceNow)
            try? await center.add(UNNotificationRequest(
                identifier: note.id.uuidString, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            ))
        }
        scheduleSpoken(note)
    }

    private func scheduleSpoken(_ note: AssistantContext.Note) {
        guard let due = note.due else { return }
        reminderTasks[note.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.present?()
            self.say(String(localized: "Reminder: \(note.text)"), kind: .assistant)
            self.reminderTasks[note.id] = nil
        }
    }

    private func perform(_ call: ActionCall, actions: [AssistantAction], state: AppState) async -> ActionOutcome {
        guard let action = actions.first(where: { $0.spec.name == call.name }) else {
            return ActionOutcome(text: "There is no action called \(call.name) in this mode.", failed: true)
        }
        let arguments = call.arguments
        switch AssistantPolicy.decide(
            level: action.levelFor(arguments), category: action.category, mode: mode, table: table,
            command: action.command(arguments), paths: action.paths(arguments)
        ) {
        case let .refuse(reason):
            lines.append(Line(kind: .problem, text: "\(call.name): \(reason)"))
            return ActionOutcome(text: "Refused by the person's settings: \(reason)", failed: true)
        case .ask:
            guard await confirm(action.question(arguments)) else {
                lines.append(Line(kind: .action, text: String(localized: "Not done: you said no.")))
                return ActionOutcome(text: "The person said no; nothing was done.")
            }
        case .run:
            break
        }
        lines.append(Line(kind: .action, text: "→ \(call.name)"))
        let outcome = await action.run(arguments, state)
        if outcome.failed { lines.append(Line(kind: .problem, text: outcome.text)) }
        record(call, outcome)
        return outcome
    }

    // MARK: - The log

    private func record(_ call: ActionCall, _ outcome: ActionOutcome) {
        let entry = LogEntry(date: Date(), action: call.name, arguments: call.arguments.text, result: outcome.text, failed: outcome.failed)
        log.insert(entry, at: 0)
        if log.count > 300 { log.removeLast(log.count - 300) }
        if let undo = outcome.undo {
            undos[entry.id] = undo
            undoable.insert(entry.id)
        }
        saveLog()
    }

    func undo(_ entry: LogEntry) {
        guard let undo = undos.removeValue(forKey: entry.id) else { return }
        undoable.remove(entry.id)
        Task {
            let text = await undo()
            let undone = LogEntry(date: Date(), action: "undo " + entry.action, arguments: "", result: text, failed: false)
            log.insert(undone, at: 0)
            lines.append(Line(kind: .action, text: "↩︎ " + text))
            saveLog()
        }
    }

    func clearLog() {
        log = []
        undos = [:]
        undoable = []
        saveLog()
    }

    private func saveLog() {
        try? FileManager.default.createDirectory(at: Self.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(log).write(to: Self.logFile, options: .atomic)
    }

    // MARK: - Asking first

    private func confirm(_ question: String) async -> Bool {
        say(question, kind: .assistant)
        phase = .confirming(question)
        present?()
        return await withCheckedContinuation { continuation in
            answer = continuation
            // Said aloud, the answer can be said aloud too.
            if speaksAnswers {
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    if case .confirming = self.phase, await self.startHearing() {}
                }
            }
        }
    }

    /// The "yes" or "no" buttons.
    func answer(_ yes: Bool) {
        input.stop()
        guard let answer else { return }
        self.answer = nil
        phase = .thinking
        answer.resume(returning: yes)
    }

    private func answerByVoice(_ text: String) {
        let words = text.lowercased()
        let yes = ["так", "да", "yes", "yeah", "звісно", "давай", "ok", "окей", "роби"].contains { words.contains($0) }
        let no = ["ні", "no", "не треба", "скасуй", "cancel", "стоп"].contains { words.contains($0) }
        if yes != no {
            answer(yes)
        } else {
            Task { _ = await startHearing() }
        }
    }

    // MARK: - Stopping

    /// The stop button and Esc: whatever is happening ends.
    func stop() {
        work?.cancel()
        work = nil
        input.stop()
        output.stop()
        isDictating = false
        if let answer {
            self.answer = nil
            answer.resume(returning: false)
        }
        hearing = ""
        phase = .idle
    }

    func clearConversation() {
        stop()
        turns = []
        lines = []
        saveChat()
    }

    private func say(_ text: String, kind: Line.Kind) {
        lines.append(Line(kind: kind, text: text))
        if lines.count > 60 { lines.removeFirst(lines.count - 60) }
        guard speaksAnswers, kind != .action else { return }
        phase = .speaking
        output.speak(text, language: language, engine: voiceEngine, voiceID: currentVoice, rate: Float(rate))
    }

    private var currentVoice: String? {
        switch voiceEngine {
        case .system: voiceID.isEmpty ? nil : voiceID
        case .local: localVoice
        }
    }

    /// Says a line in the chosen voice, to hear it.
    func preview() {
        output.speak(
            language == "uk" ? "Привіт! Я асистент UniMacHub." : "Hi! I'm UniMacHub's assistant.",
            language: language, engine: voiceEngine, voiceID: currentVoice, rate: Float(rate)
        )
    }

    /// Checks the provider with one short request.
    func testConnection() async -> Result<String, Error> {
        let started = Date()
        do {
            let client = AssistantClient(settings: provider, secret: AssistantSecrets.load(provider.kind))
            let reply = try await client.reply(system: "Answer with one word.", turns: [.user("Say OK.")], actions: [])
            return .success("\(reply.text.prefix(40)) · \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Dictation into any app

    /// ⌃⌥D: listens, then types what was said where the cursor is.
    func dictate() {
        guard isEnabled, usesDictation else { return }
        if isDictating {
            input.finish()
            return
        }
        guard ScreenControl.canControl else {
            present?()
            say(String(localized: "Dictation types for you, which needs Accessibility for UniMacHub: allow it in System Settings → Privacy & Security."), kind: .problem)
            return
        }
        Task {
            guard await startHearing() else { return }
            isDictating = true
            NSSound(named: "Tink")?.play()
        }
    }

    private func insertDictation(_ text: String) {
        if Dictation.command(in: text) == .removeLastSentence {
            let count = Dictation.lastSentenceLength(of: lastInserted)
            for _ in 0 ..< count { ScreenControl.press("delete", modifiers: []) }
            lastInserted = String(lastInserted.dropLast(count))
            return
        }
        let cleaned = Dictation.clean(text, language: language, dictionary: dictionary)
        guard !cleaned.isEmpty else { return }
        let piece = (lastInserted.isEmpty ? "" : " ") + cleaned
        paste(piece)
        lastInserted += piece
        dictated.insert(cleaned, at: 0)
        if dictated.count > 50 { dictated.removeLast() }
        NSSound(named: "Pop")?.play()
    }

    /// Through the clipboard and ⌘V, which every app takes; the clipboard comes back as it was.
    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in result[type] = item.data(forType: type) }
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Marked so clipboard histories, UniMacHub's included, leave it out.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        ScreenControl.press("v", modifiers: ["command"])
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            pasteboard.clearContents()
            let items = saved.map { contents -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    // MARK: - Hot keys

    /// A global key: Carbon's key code and modifiers, which need no permission.
    struct Shortcut: Codable, Equatable {
        var key: UInt32
        var modifiers: UInt32

        /// ⌥Space: ⌃⌥Space is macOS's own for switching the input language.
        static let assistant = Shortcut(key: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        static let dictation = Shortcut(key: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))

        var label: String {
            var text = ""
            if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
            return text + Self.name(of: key)
        }

        static func name(of key: UInt32) -> String {
            let names: [Int: String] = [
                kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
                kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
                kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
                kVK_F19: "F19", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
                kVK_ANSI_Slash: "/", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[",
                kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
            ]
            if let name = names[Int(key)] { return name }
            let letters: [Int: String] = [
                kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
                kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
                kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
                kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
                kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
                kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            ]
            return letters[Int(key)] ?? "#\(key)"
        }

        /// From a key press in a window, as the settings page records it.
        init?(event: NSEvent) {
            var carbon: UInt32 = 0
            if event.modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
            if event.modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
            let key = UInt32(event.keyCode)
            // A bare key would fire while typing; function keys may stand alone.
            let function = (Int(kVK_F1) ... Int(kVK_F20)).contains(Int(key)) || [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19].contains(Int(key))
            guard carbon != 0 || function else { return nil }
            self.init(key: key, modifiers: carbon)
        }

        init(key: UInt32, modifiers: UInt32) {
            self.key = key
            self.modifiers = modifiers
        }
    }

    var shortcut: Shortcut { didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: Keys.shortcut); updateHotKeys() } }
    var dictationShortcut: Shortcut { didSet { defaults.set(try? JSONEncoder().encode(dictationShortcut), forKey: Keys.dictationShortcut); updateHotKeys() } }
    var hotKeyLabel: String { shortcut.label }
    var dictationKeyLabel: String { dictationShortcut.label }

    /// Held down this long, the key works as press-to-talk: talking ends when it is let go.
    @ObservationIgnored private var pressedAt: Date?

    private func hotKeyDown() {
        pressedAt = Date()
        guard isEnabled else { return }
        if isDictating { input.finish(); return }
        present?()
        switch phase {
        case .listening: input.finish()
        case .thinking: break
        case .confirming: listen()
        case .speaking, .idle: listen()
        }
    }

    private func hotKeyUp() {
        defer { pressedAt = nil }
        guard let pressedAt, Date().timeIntervalSince(pressedAt) > 0.45 else { return }
        // Held, then let go: what was said goes at once.
        if phase == .listening { input.finish() }
    }

    private func updateHotKeys() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
        guard isEnabled, state != nil else { return }
        if hotKeyHandler == nil {
            var handler: EventHandlerRef?
            var types = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
            ]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
                guard let data, let event else { return noErr }
                var key = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
                let model = Unmanaged<AssistantModel>.fromOpaque(data).takeUnretainedValue()
                let id = key.id
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                MainActor.assumeIsolated {
                    switch (id, pressed) {
                    case (2, true): model.dictate()
                    case (2, false): break
                    case (_, true): model.hotKeyDown()
                    case (_, false): model.hotKeyUp()
                    }
                }
                return noErr
            }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
            hotKeyHandler = handler
        }
        if usesHotKey { register(shortcut.key, shortcut.modifiers, id: 1) }
        if usesDictation { register(dictationShortcut.key, dictationShortcut.modifiers, id: 2) }
    }

    private func register(_ key: UInt32, _ modifiers: UInt32, id: UInt32) {
        var reference: EventHotKeyRef?
        RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: OSType(0x554D_4841), id: id), GetApplicationEventTarget(), 0, &reference)
        if let reference { hotKeys.append(reference) }
    }

    /// While the settings page records a shortcut, the old one must not fire.
    func pauseHotKeys(_ paused: Bool) {
        if paused {
            hotKeys.forEach { UnregisterEventHotKey($0) }
            hotKeys = []
        } else {
            updateHotKeys()
        }
    }
}
