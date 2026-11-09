import Foundation

/// Codex sessions and limits, read from the logs Codex keeps in ~/.codex/sessions.
///
/// Every session is a file of JSON lines. The first line says where it runs; later lines mark
/// each turn starting and finishing, and every token count carries the account's rate limits.
/// Nothing is installed into Codex for this, and nothing is written.
public enum CodexSessions {
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
    }

    /// What one session file says.
    public struct Reading: Equatable, Sendable {
        public var session: AgentSession?
        public var limits: AgentLimits?
    }

    /// A session file seen within this long counts as recent.
    public static let recent: TimeInterval = 60 * 60
    /// A turn that started and has not written anything for this long is taken as stalled.
    static let stalled: TimeInterval = 10 * 60

    /// Reads a session from its first line and its last stretch of lines.
    public static func read(head: String, tail: String, modified: Date, now: Date = Date()) -> Reading {
        var reading = Reading()
        guard let meta = jsonLine(head.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""),
              meta["type"] as? String == "session_meta",
              let payload = meta["payload"] as? [String: Any],
              let id = payload["id"] as? String ?? payload["session_id"] as? String
        else { return reading }
        let directory = payload["cwd"] as? String ?? ""
        let host = (payload["originator"] as? String)?.contains("Desktop") == true ? "com.openai.codex" : nil

        var state: AgentSession.State = .ready
        var lastMessage: String?
        for line in tail.split(whereSeparator: \.isNewline) {
            guard let object = jsonLine(String(line)), let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String
            else { continue }
            switch type {
            case "task_started", "user_message":
                state = .working(nil)
            case "task_complete":
                state = .done(lastMessage ?? (payload["last_agent_message"] as? String).map { ClaudeHookEvent.clip($0) })
            case "turn_aborted":
                state = .done(nil)
            case "agent_message":
                if let text = payload["message"] as? String { lastMessage = ClaudeHookEvent.clip(text) }
            case "token_count":
                if let limits = limits(from: payload["rate_limits"] as? [String: Any], now: now) {
                    reading.limits = limits
                }
            default:
                if type.hasSuffix("approval_request") {
                    state = .needsPermission(ClaudeHookEvent.summary(of: payload, tool: nil) ?? "")
                }
            }
        }
        if case .working = state, now.timeIntervalSince(modified) > stalled { state = .done(nil) }
        reading.session = AgentSession(kind: .codex, sessionID: id, directory: directory, state: state, updated: modified, host: host)
        return reading
    }

    /// Codex's limits: a window of five hours and one of a week, whichever it calls primary.
    static func limits(from object: [String: Any]?, now: Date) -> AgentLimits? {
        guard let object else { return nil }
        var limits = AgentLimits(fiveHour: nil, week: nil, updated: now)
        for key in ["primary", "secondary"] {
            guard let window = object[key] as? [String: Any],
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue
            else { continue }
            let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
            var resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if resets == nil, let seconds = (window["resets_in_seconds"] as? NSNumber)?.doubleValue {
                resets = now.addingTimeInterval(seconds)
            }
            let usage = UsageWindow(usedPercent: used, resetsAt: resets)
            if minutes > 0, minutes <= 6 * 60 { limits.fiveHour = usage } else { limits.week = usage }
        }
        return limits.isEmpty ? nil : limits
    }

    static func jsonLine(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Session files written to in the last hour, newest first. Only today's and yesterday's
    /// folders are looked at, so this stays quick however long Codex has been in use.
    public static func recentFiles(now: Date = Date()) -> [(url: URL, modified: Date)] {
        let calendar = Calendar(identifier: .gregorian)
        var folders: [URL] = []
        for daysBack in 0 ... 1 {
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let date = parts.day else { continue }
            folders.append(folder.appending(path: String(format: "%04d/%02d/%02d", year, month, date)))
        }
        var found: [(URL, Date)] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(modified) < recent
                else { continue }
                found.append((file, modified))
            }
        }
        return found.sorted { $0.1 > $1.1 }
    }

    /// The first line and roughly the last 96 KB of a file.
    public static func headAndTail(of url: URL, tailBytes: Int = 96 * 1024) -> (head: String, tail: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The first line carries Codex's instructions too, so it runs to tens of kilobytes.
        var headData = Data()
        while headData.count < 1024 * 1024, !headData.contains(0x0A),
              let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty
        {
            headData.append(chunk)
        }
        let firstLine = headData.firstIndex(of: 0x0A).map { headData[..<$0] } ?? headData[...]
        let head = String(decoding: firstLine, as: UTF8.self)
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        var tail = (try? handle.readToEnd()).flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
        // Starting in the middle of a line: drop that part line.
        if start > 0, let newline = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: newline)...]) }
        return (head, tail)
    }
}
