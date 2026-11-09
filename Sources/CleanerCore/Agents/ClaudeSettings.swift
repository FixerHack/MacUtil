import Foundation

/// UniMacHub's part of Claude Code's own settings file, ~/.claude/settings.json.
///
/// Two things go in, and only on the person's say-so: hooks, which tell the island what each
/// session is doing, and a status line, which is how Claude Code shares its usage limits. Both
/// are added beside whatever is there already, never in place of it: other apps' hooks stay,
/// and a status line someone already has keeps running and printing, with UniMacHub only
/// reading along. Taking UniMacHub out removes exactly what it added, found by the
/// `agent-hook claude` and `statusline` marks in its commands.
public enum ClaudeSettings {
    public static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
    }

    /// The events the island follows.
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "Notification", "Stop", "StopFailure", "SessionEnd",
    ]

    static let hookMark = "agent-hook claude"
    static let statusMark = "statusline"

    /// How long Claude Code waits for an answer from the island, in seconds. mucli itself
    /// gives up sooner and hands the question back to the terminal.
    public static let permissionTimeout = 330
    /// How long a question waits in the island before going back to the terminal.
    public static let questionWait: TimeInterval = 300

    /// The shell command for a hook: nothing at all if UniMacHub has been removed since.
    public static func hookCommand(mucli: String) -> String {
        let path = quoted(mucli)
        return "[ -x \(path) ] && \(path) \(hookMark) || true"
    }

    /// The status line: UniMacHub's own, or the one there was, run by UniMacHub so the
    /// limits can be read on the way. The old command travels base64-encoded, so no quoting
    /// can go wrong, and comes back unchanged when UniMacHub is taken out.
    public static func statusCommand(mucli: String, previous: String?) -> String {
        var command = "\(quoted(mucli)) \(statusMark)"
        if let previous, !previous.isEmpty {
            command += " --then " + Data(previous.utf8).base64EncodedString()
        }
        return command
    }

    /// Single quotes for the shell.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Reading what is there

    public static func isConnected(_ settings: [String: Any]) -> Bool {
        hasOurHooks(settings) || hasOurStatusLine(settings)
    }

    static func hasOurHooks(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { groups in
            (groups as? [[String: Any]] ?? []).contains(where: isOurs)
        }
    }

    static func hasOurStatusLine(_ settings: [String: Any]) -> Bool {
        guard let line = settings["statusLine"] as? [String: Any], let command = line["command"] as? String else { return false }
        return isOurStatusCommand(command)
    }

    static func isOurStatusCommand(_ command: String) -> Bool {
        command.contains("mucli' \(statusMark)")
    }

    /// A hook group UniMacHub put there.
    static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(hookMark) == true }
    }

    // MARK: - Changing it

    /// The settings with UniMacHub's hooks and status line in, and nothing else changed.
    public static func connecting(_ settings: [String: Any], mucli: String) -> [String: Any] {
        var settings = disconnecting(settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var hook: [String: Any] = ["type": "command", "command": hookCommand(mucli: mucli)]
            hook["timeout"] = event == "PermissionRequest" ? permissionTimeout : 5
            groups.append(["hooks": [hook]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks

        var line = settings["statusLine"] as? [String: Any] ?? [:]
        let previous = line["command"] as? String
        line["type"] = "command"
        line["command"] = statusCommand(mucli: mucli, previous: previous)
        settings["statusLine"] = line
        return settings
    }

    /// The settings with everything UniMacHub added taken out again.
    public static func disconnecting(_ settings: [String: Any]) -> [String: Any] {
        var settings = settings
        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let kept = groups.filter { !isOurs($0) }
                if kept.count != groups.count {
                    hooks[event] = kept.isEmpty ? nil : kept
                }
            }
            settings["hooks"] = hooks.isEmpty ? nil : hooks
        }
        if var line = settings["statusLine"] as? [String: Any], let command = line["command"] as? String,
           isOurStatusCommand(command)
        {
            if let previous = previousStatusCommand(in: command) {
                line["command"] = previous
                settings["statusLine"] = line
            } else {
                settings["statusLine"] = nil
            }
        }
        return settings
    }

    /// The status line there was before UniMacHub's, if any.
    static func previousStatusCommand(in command: String) -> String? {
        guard let range = command.range(of: " --then ") else { return nil }
        let encoded = command[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - The file

    public enum Failure: Error, Equatable {
        /// The file is there but is not JSON this can safely rewrite.
        case unreadable
        case unwritable(String)
    }

    /// The file's settings; empty when there is no file yet.
    public static func read(from url: URL = file) throws(Failure) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .unreadable
        }
        return object
    }

    /// Writes the settings back, keeping a copy of how the file was first.
    public static func write(_ settings: [String: Any], to url: URL = file, now: Date = Date()) throws(Failure) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: url.path) {
                let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
                let backup = url.deletingLastPathComponent()
                    .appending(path: "\(url.lastPathComponent).unimachub-\(stamp).backup")
                try? fileManager.removeItem(at: backup)
                try fileManager.copyItem(at: url, to: backup)
            }
            let data = try JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw .unwritable(error.localizedDescription)
        }
    }
}

/// What Claude Code passes its status line, read for the limits.
public enum ClaudeStatusLine {
    public static func limits(from json: Data, now: Date = Date()) -> AgentLimits? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any]
        else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let window = limits[key] as? [String: Any],
                  let used = (window["used_percentage"] as? NSNumber)?.doubleValue
            else { return nil }
            let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return UsageWindow(usedPercent: used, resetsAt: resets)
        }
        let result = AgentLimits(fiveHour: window("five_hour"), week: window("seven_day"), updated: now)
        return result.isEmpty ? nil : result
    }

    /// UniMacHub's own status line, for someone who had none: the model, how full the
    /// context is, and the limits.
    public static func line(from json: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return "" }
        var parts: [String] = []
        if let model = (object["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
        if let context = (object["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber {
            parts.append("ctx \(context.intValue)%")
        }
        if let limits = limits(from: json) {
            if let five = limits.fiveHour { parts.append("5h \(Int(five.usedPercent.rounded()))%") }
            if let week = limits.week { parts.append("7d \(Int(week.usedPercent.rounded()))%") }
        }
        return parts.joined(separator: " · ")
    }
}
