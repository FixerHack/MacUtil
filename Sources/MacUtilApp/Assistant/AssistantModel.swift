import AppKit
import AVFoundation
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
        static let conversation = "assistantKeepsListening"
        static let wake = "assistantWakeWordOn"
        static let wakeWord = "assistantWakeWord"
        static let dictationShortcut = "assistantDictationShortcut"
        static let whisper = "assistantWhisper"
        static let recordings = "assistantKeepsRecordings"
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
    /// Spoken to, it listens again after answering, so it goes on like a conversation.
    var keepsListening: Bool { didSet { defaults.set(keepsListening, forKey: Keys.conversation) } }
    /// In a spoken conversation now: it will listen again after it answers.
    private(set) var conversing = false
    /// Listens all the time for a word that wakes it, on this Mac only.
    var usesWakeWord: Bool { didSet { defaults.set(usesWakeWord, forKey: Keys.wake); if !usesWakeWord { stopWaking() } } }
    var wakeWord: String { didSet { defaults.set(wakeWord, forKey: Keys.wakeWord) } }
    /// Listening for the wake word now.
    private(set) var isWaking = false
    /// Why the wake word cannot be listened for.
    private(set) var wakeProblem: String?
    @ObservationIgnored private var wakeLoop: Task<Void, Never>?
    /// The wake word was heard: what follows it in the same breath is the request.
    @ObservationIgnored private var woken = false
    var rate: Double { didSet { defaults.set(rate, forKey: Keys.rate) } }
    var persona: Persona { didSet { defaults.set(persona.rawValue, forKey: Keys.persona) } }
    var customManner: String { didSet { defaults.set(customManner, forKey: Keys.manner) } }
    /// Apple's servers may hear the person when this Mac cannot do the language itself.
    var allowsServerRecognition: Bool { didSet { defaults.set(allowsServerRecognition, forKey: Keys.server) } }
    /// Whisper, once downloaded, listens to each request again on this Mac.
    var usesWhisper: Bool { didSet { defaults.set(usesWhisper, forKey: Keys.whisper) } }
    /// Recordings of each request, with what was heard, kept on this Mac to find out why a word was missed.
    var keepsRecordings: Bool { didSet { defaults.set(keepsRecordings, forKey: Keys.recordings) } }
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
    /// Lines waiting to be spoken, so one answer never cuts off another.
    @ObservationIgnored private var speechQueue: [String] = []
    /// Set while a question waits to be heard until it has been said.
    @ObservationIgnored private var listenAfterSpeaking = false
    /// For the log: what it is saying and since when, and since when it has been listening.
    @ObservationIgnored private var nowSpeaking = ""
    @ObservationIgnored private var screenIsOff = false
    @ObservationIgnored private var screenObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var speakingSince = Date()
    @ObservationIgnored private var listeningSince = Date()

    static let traceFile = AppPaths.file("assistant-trace.log")

    /// The Mac's own time, with the date, so a line can be matched with what the person remembers.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Everything the assistant does, step by step, to find out later what went wrong.
    func trace(_ text: String) {
        let line = "\(Self.stamp.string(from: Date())) \(text.replacingOccurrences(of: "\n", with: " ⏎ "))\n"
        let file = Self.traceFile
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 2_000_000 {
            try? FileManager.default.removeItem(at: file.deletingPathExtension().appendingPathExtension("old.log"))
            try? FileManager.default.moveItem(at: file, to: file.deletingPathExtension().appendingPathExtension("old.log"))
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

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
        keepsListening = defaults.object(forKey: Keys.conversation) as? Bool ?? true
        usesWakeWord = defaults.bool(forKey: Keys.wake)
        wakeWord = defaults.string(forKey: Keys.wakeWord) ?? (Locale.current.language.languageCode?.identifier == "uk" ? "Хабе" : "Hey Hub")
        shortcut = defaults.data(forKey: Keys.shortcut).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .assistant
        dictationShortcut = defaults.data(forKey: Keys.dictationShortcut).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .dictation
        rate = defaults.double(forKey: Keys.rate)
        persona = Persona(rawValue: defaults.string(forKey: Keys.persona) ?? "") ?? .plain
        customManner = defaults.string(forKey: Keys.manner) ?? ""
        allowsServerRecognition = defaults.bool(forKey: Keys.server)
        usesWhisper = defaults.object(forKey: Keys.whisper) as? Bool ?? true
        keepsRecordings = defaults.bool(forKey: Keys.recordings)
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
        input.onEvent = { [weak self] event in self?.trace(event) }
        input.refine = { [weak self] sound, heard in
            await self?.listenAgain(sound, heard: heard) ?? heard
        }
        input.onLevel = { [weak self] level in
            guard let self else { return }
            // Quick to rise, slower to fall, so the wave breathes rather than flickers.
            self.level = level > self.level ? level : self.level * 0.75 + level * 0.25
        }
        output.onFinished = { [weak self] in
            guard let self else { return }
            if !self.speechQueue.isEmpty {
                self.speakNow(self.speechQueue.removeFirst())
                return
            }
            self.trace("spoken")
            if self.listenAfterSpeaking, case .confirming = self.phase {
                self.listenAfterSpeaking = false
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if case .confirming = self.phase { _ = await self.startHearing() }
                }
                return
            }
            guard self.phase == .speaking else { return }
            self.phase = .idle
            self.followUp()
        }
    }

    func attach(_ state: AppState) {
        self.state = state
        updateHotKeys()
        // With the screen locked or asleep nobody is there to call it: the microphone goes off,
        // and with it macOS's orange dot.
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for (center, name, off) in [
            (workspace, NSWorkspace.screensDidSleepNotification, true), (workspace, NSWorkspace.screensDidWakeNotification, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), true), (distributed, Notification.Name("com.apple.screenIsUnlocked"), false),
        ] as [(NotificationCenter, Notification.Name, Bool)] {
            screenObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.screenIsOff = off
                    if off, self.isWaking {
                        self.trace("screen locked or asleep: the wake word stops listening")
                        self.stopWaking()
                    }
                }
            })
        }
        // Every couple of seconds: back to listening for the wake word whenever it is idle.
        wakeLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if self.usesWakeWord, self.isEnabled, self.phase == .idle, !self.isWaking, !self.isDictating,
                   !self.conversing, !self.output.isSpeaking, !self.screenIsOff {
                    self.startWaking()
                }
            }
        }
    }

    // MARK: - The wake word

    private func startWaking() {
        guard SpeechInput.isAuthorised else {
            wakeProblem = String(localized: "Allow the microphone and speech recognition first: press the shortcut once.")
            return
        }
        // Listening all the time is only done on this Mac, never through Apple's servers.
        guard SpeechInput.worksOnDevice(language) else {
            wakeProblem = String(localized: "This Mac cannot recognise this language by itself, and the wake word never goes to Apple's servers.")
            return
        }
        do {
            try input.start(language: language, allowServer: false, hints: [wakeWord] + recognitionHints)
            wakeProblem = nil
            isWaking = true
            woken = false
        } catch {
            wakeProblem = error.localizedDescription
        }
    }

    private func stopWaking() {
        guard isWaking else { return }
        isWaking = false
        woken = false
        input.stop()
    }

    /// The words after the wake word, if it was said.
    private func afterWakeWord(_ text: String) -> String? {
        WakeWord.request(in: text, word: wakeWord)
    }

    // MARK: - Asking

    /// From the hot key or the island: listens, or stops listening and sends what was heard.
    func activate() {
        guard isEnabled else { return }
        if isDictating { input.finish(); return }
        present?()
        switch phase {
        case .listening:
            trace("the person ended listening with the microphone button after \(Self.seconds(since: listeningSince))")
            input.finish()
        case .speaking:
            traceInterruption("with the microphone button")
            output.stop()
            phase = .idle
        case .idle: listen()
        default: break
        }
    }

    /// After an answer, in a spoken conversation: listens again, a moment later so it does
    /// not hear the end of its own voice.
    private func followUp() {
        guard conversing, keepsListening, phase == .idle, work == nil || work?.isCancelled == true else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard self.conversing, self.phase == .idle else { return }
            self.listen(conversation: true)
        }
    }

    func listen(conversation: Bool = true) {
        stopWaking()
        output.stop()
        if conversation { conversing = true }
        Task {
            guard await startHearing() else { return }
            hearing = ""
            phase = .listening
            listeningSince = Date()
            trace(conversation && conversing ? "listening (conversation)" : "listening")
        }
    }

    /// Whisper's turn: the whole request once more, on this Mac, and its words used when it
    /// heard any. Kept as a recording too, when the person asked for that.
    private func listenAgain(_ sound: [AVAudioPCMBuffer], heard: String) async -> String {
        // Listening for the wake word alone: nothing is kept and nothing more runs.
        if isWaking, !woken { return heard }
        let whisper = usesWhisper && WhisperEngine.shared.isInstalled
        guard whisper || keepsRecordings else { return heard }
        let wave = FileManager.default.temporaryDirectory.appending(path: "unimachub-heard-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wave) }
        nonisolated(unsafe) let buffers = sound
        guard await Task.detached(operation: { WhisperEngine.writeWave(buffers, to: wave) }).value else {
            trace("the recording could not be written for Whisper")
            return heard
        }
        var better: String?
        if whisper {
            if let result = await WhisperEngine.transcribe(wave, language: language) {
                better = result.text
                trace(String(format: "macOS heard: \"%@\"; Whisper heard: \"%@\" in %.1f s", heard, result.text, result.seconds))
            } else {
                trace("Whisper did not run; macOS's words are used")
            }
        }
        if keepsRecordings { SpeechRecordings.keep(wave, apple: heard, whisper: better) }
        guard let better, !better.isEmpty else { return heard }
        // In near silence Whisper makes up a video's sign-off; that is not the person speaking.
        let madeUp = ["дякую за перегляд", "субтитр", "продовження далі", "thanks for watching", "thank you for watching"]
        if heard.isEmpty, madeUp.contains(where: { better.lowercased().contains($0) }) { return heard }
        // Whisper's words, without a word it said twice ("фейсіт. Фейсіт.").
        return Transcript.collapseRepeats(better)
    }

    /// Names macOS's recogniser would not guess in Ukrainian speech: the apps on this Mac and
    /// a few well-known words, so "Телеграм" comes out as Telegram.
    private var recognitionHints: [String] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
        let installed = ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        let words = ["Telegram", "YouTube", "UniMacHub", "Safari", "Chrome", "Brave", "Discord", "Spotify", "Finder", "Dock",
                     "Wi-Fi", "Bluetooth", "Claude", "GitHub", "Google", "Terminal", "Xcode", "Steam", "WhatsApp", "Instagram"]
        let profiles: [String] = state?.dock.profiles.map(\.name) ?? []
        var all: [String] = running
        all += installed
        all += words
        all += profiles
        return Array(Array(Set(all)).prefix(100))
    }

    /// Starts the microphone, or says why it cannot.
    private func startHearing() async -> Bool {
        if !SpeechInput.isAuthorised, !(await SpeechInput.authorise()) {
            say(String(localized: "I need the microphone and speech recognition: allow them in System Settings → Privacy & Security."), kind: .problem)
            focusRequest += 1
            return false
        }
        do {
            try input.start(language: language, allowServer: allowsServerRecognition, hints: recognitionHints)
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
        if isWaking {
            heardWhileWaking(text, final: final)
            return
        }
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
        // Nothing said: the conversation has ended on its own.
        guard !said.isEmpty else {
            conversing = false
            return
        }
        // The person's own spellings: "телеграм" heard, Telegram written.
        let request = dictionary.isEmpty ? said : Dictation.clean(said, language: language, dictionary: dictionary)
        trace("heard: \(said)\(request == said ? "" : " → \(request)")")
        // "Thanks", "rest", "bye": a short goodbye ends it without asking the model.
        if Goodbye.isGoodbye(said) {
            endConversation()
            say(language == "uk" ? "Добре, відпочиваю." : "Okay, I'll rest.", kind: .assistant)
            return
        }
        ask(request)
    }

    /// Listening for the wake word: nothing is shown until it is heard; then what follows is
    /// the request, as if the shortcut had been pressed.
    private func heardWhileWaking(_ text: String, final: Bool) {
        if !woken, afterWakeWord(text) != nil {
            woken = true
            trace("wake word heard")
            conversing = true
            phase = .listening
            NSSound(named: "Tink")?.play()
        }
        if woken {
            hearing = afterWakeWord(text) ?? ""
        }
        guard final else { return }
        if woken { trace("wake phrase: \(text)") }
        isWaking = false
        let request = woken ? (afterWakeWord(text) ?? "") : ""
        let wasWoken = woken
        woken = false
        hearing = ""
        phase = .idle
        guard wasWoken else { return }
        // Only the word: now it listens for the request.
        if request.isEmpty { listen(conversation: true) } else { heardRequest(request) }
    }

    /// A request heard after the wake word, handled as one heard after the shortcut.
    private func heardRequest(_ text: String) {
        heard(text, final: true)
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
        text += "\nUniMacHub's own screens open with open_tool; macOS apps such as Terminal open with open_app."
        text += "\nWhen you have run actions, end with one short sentence saying what you did and whether it worked."
        text += "\nWhen the person says goodbye, tells you to rest or that they need nothing more, call end_conversation and say a short goodbye."
        text += "\n«Системні параметри», «системні налаштування» or the settings of the Mac or MacBook mean macOS System Settings: open_app \"System Settings\". UniMacHub's own settings only when the person names UniMacHub."
        text += "\nFor Wi-Fi (on, off, the network's name, the networks around) use the wifi action, never the terminal: macOS hides network names from commands."
        text += "\nWhen the person asks for several things that do not depend on each other, call all the actions in one reply instead of one per reply: each reply costs seconds."
        text += "\nThe request comes from speech recognition and may be garbled: a phrase said twice is one request, and a word may be misheard (\"Face\" may be FACEIT). When a guess is risky, ask briefly."
        if mode == .basic {
            text += "\nYou are in the basic mode: the terminal, the internet and the screen are off. If asked for them, say they can be allowed in the assistant's settings (Custom or Fully free mode)."
        }
        if mode == .custom, !table.rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\nThe person's own rules, which you follow:\n" + table.rules
        }
        return text
    }

    /// The person's words, to the model, and round the loop until it has nothing more to run.
    func ask(_ text: String) {
        guard let state else { return }
        halt()
        // One conversation throughout; when it would fill the model's context, it starts over.
        // What should outlive that belongs in the notes, which are always sent.
        if AssistantContext.size(of: turns) + text.count > AssistantContext.limit(for: provider.kind) {
            turns = []
            lines.append(Line(kind: .action, text: String(localized: "The conversation filled the model's memory, so it starts afresh. Notes are kept.")))
        }
        lines.append(Line(kind: .person, text: text))
        turns.append(.user(text))
        trace("asked: \(text) | mode \(mode.rawValue), provider \(provider.kind.rawValue) \(provider.model), turns \(turns.count)")
        saveChat()
        phase = .thinking
        let client = AssistantClient(settings: provider, secret: AssistantSecrets.load(provider.kind))
        let system = system
        work = Task { [weak self] in
            for _ in 0 ..< 12 {
                guard let self, !Task.isCancelled else { return }
                let actions = AssistantActions.available(state, mode: self.mode, table: self.table, seesImages: self.provider.kind.seesImages)
                let reply: ModelReply
                let asked = Date()
                do {
                    let turns = self.turns, specs = actions.map(\.spec)
                    reply = try await Self.withTimeout(seconds: 120) {
                        try await client.reply(system: system, turns: turns, actions: specs)
                    }
                } catch {
                    guard !Task.isCancelled else {
                        self.trace("model call cancelled after \(Self.seconds(since: asked))")
                        return
                    }
                    self.trace("model error after \(Self.seconds(since: asked)): \(String(describing: error))")
                    self.say(error.localizedDescription, kind: .problem)
                    if self.phase == .thinking { self.phase = .idle }
                    return
                }
                guard !Task.isCancelled else { return }
                if reply.refused {
                    self.say(String(localized: "The model declined this request."), kind: .problem)
                    self.phase = .idle
                    return
                }
                self.turns.append(.assistant(text: reply.text, calls: reply.calls, raw: reply.raw))
                self.trace("model (\(Self.seconds(since: asked))): \(reply.text) | calls: \(reply.calls.map { "\($0.name) \($0.arguments.text)" }.joined(separator: "; "))")
                // On the way, words are shown; only the last answer, the summary, is spoken. A
                // goodbye with end_conversation is the last answer too: no further round for it.
                let ending = reply.calls.contains { $0.name == "end_conversation" }
                if !reply.text.isEmpty { self.say(reply.text, kind: .assistant, aloud: reply.calls.isEmpty || ending) }
                guard !reply.calls.isEmpty else { break }
                for call in reply.calls {
                    let started = Date()
                    self.trace("action \(call.name) starts: \(call.arguments.text.prefix(300))")
                    let outcome = await self.perform(call, actions: actions, state: state)
                    self.trace("action \(call.name) (\(Self.seconds(since: started))): \(outcome.failed ? "FAILED " : "")\(outcome.text.prefix(400))")
                    guard !Task.isCancelled else {
                        self.trace("cancelled after \(call.name)")
                        return
                    }
                    self.turns.append(.result(callID: call.id, name: call.name, text: outcome.text, failed: outcome.failed, image: outcome.image))
                }
                if ending {
                    // The turns close on the assistant's words, as every provider expects.
                    self.turns.append(.assistant(text: reply.text.isEmpty ? "Goodbye." : reply.text, calls: [], raw: nil))
                    break
                }
                self.phase = .thinking
            }
            guard let self else { return }
            if self.phase == .thinking { self.phase = self.output.isSpeaking ? .speaking : .idle }
            self.saveChat()
            self.work = nil
            self.followUp()
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
        trace("asks first: \(question)")
        // Only the question is said; the command or the files under it are on the screen.
        let firstLine = question.components(separatedBy: "\n").first ?? question
        say(question, kind: .assistant, spokenAs: firstLine)
        phase = .confirming(question)
        present?()
        return await withCheckedContinuation { continuation in
            answer = continuation
            // Said aloud, the answer can be said aloud too, once the question has been said:
            // listening sooner would hear the question itself.
            if speaksAnswers {
                if output.isSpeaking {
                    listenAfterSpeaking = true
                } else {
                    Task { if case .confirming = self.phase { _ = await self.startHearing() } }
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
        trace("answered by voice: \(text)")
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
        switch phase {
        case .speaking: traceInterruption("with Stop or Esc")
        case .thinking: trace("the person stopped it with Stop or Esc while it was thinking")
        case .listening: trace("the person stopped listening with Stop or Esc after \(Self.seconds(since: listeningSince))")
        default: break
        }
        conversing = false
        stopWaking()
        halt()
    }

    /// Ends whatever is happening without ending the conversation, before the next request.
    static func seconds(since date: Date) -> String {
        String(format: "%.1f s", Date().timeIntervalSince(date))
    }

    struct ModelTimeout: LocalizedError {
        var errorDescription: String? { String(localized: "The model did not answer in two minutes. Try again, or pick another model in the settings.") }
    }

    /// Runs the model's call, giving up after a while so a stuck answer does not hang the assistant.
    static func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ModelTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ModelTimeout() }
            return first
        }
    }

    private func halt() {
        if work != nil { trace("stopped what was running (phase \(phase))") }
        work?.cancel()
        work = nil
        isWaking = false
        woken = false
        input.stop()
        speechQueue = []
        listenAfterSpeaking = false
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

    /// Shows a line and, unless told not to, says it: `spokenAs` when the written line is too
    /// long to listen to, such as a whole command after its question.
    private func say(_ text: String, kind: Line.Kind, aloud: Bool = true, spokenAs: String? = nil) {
        lines.append(Line(kind: kind, text: text))
        if lines.count > 60 { lines.removeFirst(lines.count - 60) }
        guard aloud, speaksAnswers, kind != .action else { return }
        let spoken = spokenAs ?? text
        if output.isSpeaking {
            speechQueue.append(spoken)
        } else {
            speakNow(spoken)
        }
    }

    private func speakNow(_ text: String) {
        trace("speaking: \(text.prefix(200))")
        nowSpeaking = text
        speakingSince = Date()
        if case .confirming = phase {} else { phase = .speaking }
        output.speak(text, language: language, engine: voiceEngine, voiceID: currentVoice, rate: Float(rate))
    }

    /// The model, or the person, has said goodbye: no more listening after this answer.
    func endConversation() {
        trace("conversation ended")
        conversing = false
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
        stopWaking()
        if isDictating { input.finish(); return }
        // No chat: the island's light shows it listens; the chat is a tab away.
        trace("shortcut pressed in \(phase)")
        switch phase {
        case .listening:
            trace("the person ended listening with the shortcut after \(Self.seconds(since: listeningSince))")
            input.finish()
        case .thinking:
            trace("the person pressed the shortcut while it was thinking: ignored, the answer is on its way")
        case .confirming: listen()
        case .speaking, .idle:
            if phase == .speaking { traceInterruption("with the shortcut") }
            listen()
        }
    }

    /// The person cut the answer short: how far it had got, for finding out what it said too long.
    private func traceInterruption(_ how: String) {
        let spoken = Self.seconds(since: speakingSince)
        trace("the person interrupted \(how) after \(spoken) of speaking: \"\(nowSpeaking.prefix(120))\"\(speechQueue.isEmpty ? "" : ", \(speechQueue.count) more waiting")")
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
