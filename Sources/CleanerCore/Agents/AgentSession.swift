import Foundation

/// A coding agent the island keeps an eye on.
public enum AgentKind: String, Sendable, Codable, CaseIterable {
    case claude, codex

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// One conversation with a coding agent, and what it is doing now.
public struct AgentSession: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        /// Started, nothing asked of it yet.
        case ready
        /// Thinking or running a tool, named when known.
        case working(String?)
        /// Wants to do something and waits for a yes or no: what it wants to do.
        case needsPermission(String)
        /// Has a question, or waits for the next message.
        case needsInput(String?)
        /// Finished its turn; its last words, when known.
        case done(String?)
        case failed(String?)
    }

    public let kind: AgentKind
    public let sessionID: String
    public var directory: String
    public var state: State
    public var updated: Date
    /// The app it runs in, a terminal or an editor, to bring forward.
    public var host: String?

    public var id: String { kind.rawValue + ":" + sessionID }

    /// The project's folder name.
    public var project: String {
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? directory : name
    }

    /// Waiting for the person, one way or another.
    public var needsYou: Bool {
        switch state {
        case .needsPermission, .needsInput: true
        default: false
        }
    }

    public var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    public init(kind: AgentKind, sessionID: String, directory: String, state: State, updated: Date, host: String? = nil) {
        self.kind = kind
        self.sessionID = sessionID
        self.directory = directory
        self.state = state
        self.updated = updated
        self.host = host
    }
}

/// One hook call from Claude Code, as `mucli agent-hook claude` passes it on.
public struct ClaudeHookEvent: Sendable, Equatable {
    public let name: String
    public let sessionID: String
    public let directory: String
    /// The app Claude Code runs in, added by mucli from its environment.
    public let host: String?
    public let toolName: String?
    /// The gist of what the tool would do: the command, the file, the address.
    public let toolSummary: String?
    public let notificationType: String?
    public let message: String?
    public let lastAssistantMessage: String?

    public init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let name = object["hook_event_name"] as? String,
              let session = object["session_id"] as? String, !session.isEmpty
        else { return nil }
        self.name = name
        sessionID = session
        directory = object["cwd"] as? String ?? ""
        host = (object["umh_host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        toolName = object["tool_name"] as? String
        toolSummary = Self.summary(of: object["tool_input"] as? [String: Any], tool: toolName)
        notificationType = object["notification_type"] as? String
        message = (object["message"] as? String).map { Self.clip($0) }
        lastAssistantMessage = (object["last_assistant_message"] as? String).map { Self.clip($0) }
    }

    public var isPermissionRequest: Bool { name == "PermissionRequest" }

    /// What a tool call is about, in one short line.
    static func summary(of input: [String: Any]?, tool: String?) -> String? {
        let tool = tool ?? ""
        guard let input else { return tool.isEmpty ? nil : tool }
        if let command = input["command"] as? String { return clip(command) }
        if let path = input["file_path"] as? String ?? input["notebook_path"] as? String {
            return clip("\(tool) \((path as NSString).lastPathComponent)")
        }
        if let url = input["url"] as? String { return clip("\(tool) \(url)") }
        if let pattern = input["pattern"] as? String { return clip("\(tool) \(pattern)") }
        if let description = input["description"] as? String { return clip(description) }
        return tool.isEmpty ? nil : tool
    }

    /// The first line, no longer than fits in the island.
    static func clip(_ text: String, to limit: Int = 140) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }
}

public extension AgentSession {
    /// A session as its first event shows it.
    init(event: ClaudeHookEvent, at date: Date) {
        self.init(kind: .claude, sessionID: event.sessionID, directory: event.directory, state: .ready, updated: date, host: event.host)
        _ = apply(event, at: date)
    }

    /// Moves the session on by one event. False when the session has ended.
    mutating func apply(_ event: ClaudeHookEvent, at date: Date) -> Bool {
        if !event.directory.isEmpty { directory = event.directory }
        if let host = event.host { self.host = host }
        updated = date
        switch event.name {
        case "SessionStart":
            state = .ready
        case "UserPromptSubmit":
            state = .working(nil)
        case "PreToolUse":
            state = .working(event.toolName)
        case "PostToolUse", "PostToolUseFailure":
            state = .working(nil)
        case "PermissionRequest":
            state = .needsPermission(event.toolSummary ?? event.toolName ?? "")
        case "Notification":
            switch event.notificationType {
            case "permission_prompt":
                if case .needsPermission = state { break }
                state = .needsPermission(event.message ?? "")
            case "idle_prompt":
                // It has been waiting a while; after a finished turn that is nothing new.
                if case .done = state { break }
                state = .needsInput(event.message)
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                state = .needsInput(event.message)
            default:
                break
            }
        case "Stop":
            state = .done(event.lastAssistantMessage)
        case "StopFailure":
            state = .failed(event.message ?? event.lastAssistantMessage)
        case "SessionEnd":
            return false
        default:
            break
        }
        return true
    }
}

/// How much of a subscription's allowance is used, per window.
public struct UsageWindow: Equatable, Sendable, Codable {
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// Still meaningful: a window that has reset says nothing any more.
    public func isCurrent(at date: Date) -> Bool {
        resetsAt.map { $0 > date } ?? true
    }
}

public struct AgentLimits: Equatable, Sendable, Codable {
    public var fiveHour: UsageWindow?
    public var week: UsageWindow?
    public var updated: Date

    public init(fiveHour: UsageWindow?, week: UsageWindow?, updated: Date) {
        self.fiveHour = fiveHour
        self.week = week
        self.updated = updated
    }

    public var isEmpty: Bool { fiveHour == nil && week == nil }

    /// Only the windows that have not reset yet.
    public func current(at date: Date) -> AgentLimits {
        AgentLimits(
            fiveHour: fiveHour.flatMap { $0.isCurrent(at: date) ? $0 : nil },
            week: week.flatMap { $0.isCurrent(at: date) ? $0 : nil },
            updated: updated
        )
    }
}

/// Where mucli and the app meet.
public enum AgentPaths {
    /// The socket the app listens on for hook calls. Only this user can open it.
    public static var socket: URL { AppPaths.file("agents.sock") }
    /// Claude Code's latest limits, as its status line last saw them.
    public static var claudeLimits: URL { AppPaths.file("claude-limits.json") }
}
