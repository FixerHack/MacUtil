import AppKit
import CleanerCore
import Foundation
import Observation

/// Coding agents for the island: which are at work, which wait for you, and how much of the
/// subscription is left.
///
/// Claude Code reports through hooks UniMacHub adds to its settings, only once the person
/// connects it; Codex is read from the logs it keeps anyway. A permission request can be
/// answered in the island, but only when you are not already looking at the agent: if its
/// terminal is in front, the question goes straight to the terminal as usual.
@MainActor
@Observable
final class AgentsModel {
    enum Keys {
        static let shows = "islandAgents"
        static let codex = "islandAgentsCodex"
        static let answers = "islandAgentsAnswerMode"
    }

    /// Where Claude Code's permission requests are answered.
    enum AnswerMode: String, CaseIterable {
        /// They wait in the island, with buttons; the terminal asks only when you send them there.
        case island
        /// In the island only while the agent's app is not in front.
        case whenAway
        /// Always in the terminal; the island only shows that one is waiting.
        case terminal
    }

    var showsAgents: Bool { didSet { UserDefaults.standard.set(showsAgents, forKey: Keys.shows) } }
    var readsCodex: Bool { didSet { UserDefaults.standard.set(readsCodex, forKey: Keys.codex) } }
    var answerMode: AnswerMode { didSet { UserDefaults.standard.set(answerMode.rawValue, forKey: Keys.answers) } }

    /// Sessions that need you first, then the most recent.
    private(set) var sessions: [AgentSession] = []
    /// Sessions whose permission question waits for an answer in the island.
    private(set) var questions: Set<String> = []
    private(set) var claudeLimits: AgentLimits?
    private(set) var codexLimits: AgentLimits?
    private(set) var claudeConnected = false
    /// A session that has just finished, shown for a moment.
    private(set) var justFinished: AgentSession?

    @ObservationIgnored private var replies: [String: AgentReply] = [:]
    @ObservationIgnored private var server: AgentSocketServer?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var finishedTask: Task<Void, Never>?
    @ObservationIgnored private var codexRead: [URL: Date] = [:]
    @ObservationIgnored private var claudeSessions: [String: AgentSession] = [:]
    @ObservationIgnored private var codexSessions: [String: AgentSession] = [:]

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.shows: true, Keys.codex: true, Keys.answers: AnswerMode.island.rawValue])
        showsAgents = defaults.bool(forKey: Keys.shows)
        readsCodex = defaults.bool(forKey: Keys.codex)
        answerMode = defaults.string(forKey: Keys.answers).flatMap(AnswerMode.init) ?? .island
        claudeConnected = (try? ClaudeSettings.isConnected(ClaudeSettings.read())) ?? false
    }

    /// Something worth the island's wings: a question, or work going on.
    var attention: AgentSession? {
        guard showsAgents else { return nil }
        return sessions.first(where: \.needsYou) ?? justFinished ?? sessions.first(where: \.isWorking)
    }

    // MARK: - Running

    func setRunning(_ running: Bool) {
        if running {
            guard loop == nil else { return }
            startServer()
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.poll()
                    try? await Task.sleep(for: .seconds(4))
                }
            }
        } else {
            loop?.cancel()
            loop = nil
            server?.stop()
            server = nil
            for reply in replies.values { reply.send() }
            replies = [:]
            questions = []
        }
    }

    private func startServer() {
        guard server == nil else { return }
        let server = AgentSocketServer(path: AgentPaths.socket.path) { [weak self] line, reply in
            Task { @MainActor in self?.received(line, reply: reply) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            self.server = nil
        }
    }

    // MARK: - Claude Code

    private func received(_ line: Data, reply: AgentReply) {
        guard let event = ClaudeHookEvent(json: line) else { return reply.send() }
        let id = AgentKind.claude.rawValue + ":" + event.sessionID
        let now = Date()
        // The agent moving on means an open question was answered some other way. A notice
        // that it is waiting, which Claude Code sends as the question goes up, is not that.
        if Self.movesOn.contains(event.name), let open = replies.removeValue(forKey: id) {
            open.send()
            questions.remove(id)
        }
        if var session = claudeSessions[id] {
            if session.apply(event, at: now) {
                claudeSessions[id] = session
            } else {
                claudeSessions[id] = nil
            }
            if case .done = session.state, event.name == "Stop" { finished(session) }
        } else if event.name != "SessionEnd" {
            claudeSessions[id] = AgentSession(event: event, at: now)
        }
        publish()

        let inIsland = switch answerMode {
        case .island: true
        case .whenAway: !isInFront(event.host)
        case .terminal: false
        }
        guard event.isPermissionRequest, showsAgents, inIsland else {
            return reply.send()
        }
        replies[id]?.send()
        replies[id] = reply
        questions.insert(id)
        // Left unanswered, the question goes back to the terminal before Claude Code gives up.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ClaudeSettings.questionWait - 10))
            guard let self, let open = self.replies[id], open === reply else { return }
            self.answerInTerminal(id)
        }
    }

    /// Whether the person is looking at the agent already.
    private func isInFront(_ host: String?) -> Bool {
        guard let host, let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return front == host
    }

    /// Events that only come once the agent has gone past a question.
    static let movesOn: Set<String> = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "SessionEnd",
    ]

    func allow(_ id: String) {
        answer(id, decision: ["behavior": "allow"])
    }

    func deny(_ id: String) {
        answer(id, decision: ["behavior": "deny", "message": "The person said no from UniMacHub's island."])
    }

    /// Hands the question back, so Claude Code asks it in the terminal, and goes there.
    func answerInTerminal(_ id: String) {
        replies.removeValue(forKey: id)?.send()
        questions.remove(id)
        if let session = sessions.first(where: { $0.id == id }) { open(session) }
    }

    private func answer(_ id: String, decision: [String: Any]) {
        guard let reply = replies.removeValue(forKey: id) else { return }
        let output: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision],
        ]
        reply.send((try? JSONSerialization.data(withJSONObject: output)) ?? Data())
        questions.remove(id)
        if var session = claudeSessions[id] {
            session.state = .working(nil)
            session.updated = Date()
            claudeSessions[id] = session
            publish()
        }
    }

    private func finished(_ session: AgentSession) {
        justFinished = session
        finishedTask?.cancel()
        finishedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.justFinished = nil
        }
    }

    // MARK: - Connecting Claude Code

    enum ConnectionError: Error {
        case noTool
        case settings(ClaudeSettings.Failure)
    }

    /// The command-line tool inside the app, which the hooks run.
    private var mucli: String? {
        Bundle.main.resourceURL.map { $0.appending(path: "mucli").path }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    func connectClaude() throws(ConnectionError) {
        guard let mucli else { throw .noTool }
        do {
            let settings = try ClaudeSettings.read()
            try ClaudeSettings.write(ClaudeSettings.connecting(settings, mucli: mucli))
        } catch {
            throw .settings(error)
        }
        claudeConnected = true
    }

    func disconnectClaude() throws(ConnectionError) {
        do {
            let settings = try ClaudeSettings.read()
            try ClaudeSettings.write(ClaudeSettings.disconnecting(settings))
        } catch {
            throw .settings(error)
        }
        claudeConnected = false
        claudeSessions = [:]
        publish()
    }

    // MARK: - Polling

    /// Every few seconds: Codex's logs, Claude Code's limits, and sessions gone quiet.
    private func poll() async {
        let now = Date()
        if readsCodex {
            let known = codexRead
            let result = await Task.detached { Self.readCodex(known: known, now: now) }.value
            codexRead = result.read
            for (id, session) in result.sessions {
                if codexSessions[id]?.isWorking == true, case .done = session.state { finished(session) }
                codexSessions[id] = session
            }
            codexSessions = codexSessions.filter { now.timeIntervalSince($0.value.updated) < CodexSessions.recent }
            if let limits = result.limits { codexLimits = limits }
        } else if !codexSessions.isEmpty {
            codexSessions = [:]
            codexLimits = nil
        }
        readClaudeLimits()
        // A session that has said nothing for a long while is put away.
        claudeSessions = claudeSessions.filter { _, session in
            let quiet = now.timeIntervalSince(session.updated)
            return session.isWorking ? quiet < 60 * 60 : quiet < 30 * 60 || replies[session.id] != nil
        }
        publish()
    }

    private nonisolated static func readCodex(known: [URL: Date], now: Date)
        -> (read: [URL: Date], sessions: [String: AgentSession], limits: AgentLimits?)
    {
        var read: [URL: Date] = [:]
        var sessions: [String: AgentSession] = [:]
        var limits: AgentLimits?
        for (url, modified) in CodexSessions.recentFiles(now: now) {
            read[url] = modified
            guard known[url] != modified, let text = CodexSessions.headAndTail(of: url) else { continue }
            let reading = CodexSessions.read(head: text.head, tail: text.tail, modified: modified, now: now)
            if let session = reading.session { sessions[session.id] = session }
            if limits == nil, let found = reading.limits { limits = found }
        }
        return (read, sessions, limits)
    }

    /// The newer of two sources: the status line of a terminal session, which is live, and
    /// what the Claude app last recorded for its own sessions, which may be a while old.
    private func readClaudeLimits() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let fromStatusLine = (try? Data(contentsOf: AgentPaths.claudeLimits))
            .flatMap { try? decoder.decode(AgentLimits.self, from: $0) }?
            .current(at: Date())
        let fromApp = (try? Data(contentsOf: ClaudeAppUsage.file)).flatMap { ClaudeAppUsage.limits(from: $0) }
        let candidates = [fromStatusLine, fromApp].compactMap { $0 }.filter { !$0.isEmpty }
        let newest = candidates.max { $0.updated < $1.updated }
        if newest != claudeLimits { claudeLimits = newest }
    }

    private func publish() {
        let all = Array(claudeSessions.values) + Array(codexSessions.values)
        let sorted = all.sorted { first, second in
            if first.needsYou != second.needsYou { return first.needsYou }
            return first.updated > second.updated
        }
        if sorted != sessions { sessions = sorted }
    }

    // MARK: - Going to it

    /// Brings forward the app the agent runs in.
    func open(_ session: AgentSession) {
        guard let host = session.host ?? (session.kind == .codex ? "com.openai.codex" : nil) else { return }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: host).first {
            running.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
