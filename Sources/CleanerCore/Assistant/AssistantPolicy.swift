import Foundation

/// What kind of thing an action does, for the custom mode's table of permissions.
public enum ActionCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case uniMacHub, readFiles, changeFiles, deleteFiles, terminal, apps, screen, internet, messages, systemSettings, admin
    public var id: String { rawValue }
}

public enum AssistantMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Only UniMacHub's own actions on this Mac: no terminal, internet or screen.
    case basic
    /// A table of permissions the person fills in.
    case custom
    /// Anything asked for; only important actions wait for "yes".
    case free
    public var id: String { rawValue }
}

public enum CategoryPolicy: String, Codable, CaseIterable, Sendable {
    case forbidden, ask, allowed
}

/// The custom mode's permissions.
public struct PermissionTable: Codable, Equatable, Sendable {
    public var policies: [ActionCategory: CategoryPolicy]
    /// Folders file actions may touch; empty means anywhere in the home folder.
    public var folders: [String]
    /// Commands that run without asking when they start with one of these.
    public var commandPrefixes: [String]
    /// Rules in the person's words. Only passed to the model; the app cannot enforce them.
    public var rules: String

    public init(policies: [ActionCategory: CategoryPolicy] = PermissionTable.defaults, folders: [String] = [], commandPrefixes: [String] = [], rules: String = "") {
        self.policies = policies
        self.folders = folders
        self.commandPrefixes = commandPrefixes
        self.rules = rules
    }

    public static let defaults: [ActionCategory: CategoryPolicy] = [
        .uniMacHub: .allowed, .readFiles: .allowed, .changeFiles: .ask, .deleteFiles: .ask,
        .terminal: .ask, .apps: .allowed, .screen: .ask, .internet: .ask,
        .messages: .forbidden, .systemSettings: .ask, .admin: .ask,
    ]

    public func policy(_ category: ActionCategory) -> CategoryPolicy {
        policies[category] ?? Self.defaults[category] ?? .ask
    }
}

public enum ActionDecision: Equatable, Sendable {
    case run, ask
    case refuse(String)
}

/// Decides whether an action runs, waits for "yes", or is refused. The app decides, from
/// the action's level and category; nothing the model says changes it.
public enum AssistantPolicy {
    /// What the basic mode leaves out altogether.
    static let outsideBasic: Set<ActionCategory> = [.terminal, .internet, .screen, .messages]

    public static func decide(
        level: ActionLevel, category: ActionCategory, mode: AssistantMode,
        table: PermissionTable = PermissionTable(), command: String? = nil, paths: [String] = [],
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> ActionDecision {
        switch mode {
        case .basic:
            if outsideBasic.contains(category) { return .refuse("Not in the basic mode.") }
            return level.asksFirst ? .ask : .run
        case .free:
            return level.asksFirst ? .ask : .run
        case .custom:
            let policy = table.policy(category)
            if policy == .forbidden { return .refuse("Not allowed in your custom mode.") }
            if !paths.isEmpty, !table.folders.isEmpty {
                let allowed = table.folders.map { ($0 as NSString).expandingTildeInPath }
                let outside = paths.contains { path in
                    let full = (path as NSString).expandingTildeInPath
                    return !allowed.contains { full == $0 || full.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
                }
                if outside { return .refuse("Outside the folders allowed in your custom mode.") }
            }
            // Deleting asks at the least, and so does anything important, whatever the table says.
            if level.asksFirst || category == .deleteFiles || category == .admin { return .ask }
            if category == .terminal, let command,
               table.commandPrefixes.contains(where: { !$0.isEmpty && command.trimmingCharacters(in: .whitespaces).hasPrefix($0) }) {
                return .run
            }
            return policy == .allowed ? .run : .ask
        }
    }
}

/// How much a shell command may change, judged by the app before it runs.
///
/// Only commands known to look and not touch run as reading; anything unknown, anything
/// that writes through a redirection, and anything destructive asks first; `sudo` needs an
/// administrator.
public enum ShellRisk {
    static let lookers: Set<String> = [
        "ls", "cat", "head", "tail", "grep", "egrep", "rg", "find", "du", "df", "pwd", "echo", "which", "whoami",
        "date", "uptime", "sw_vers", "system_profiler", "ps", "wc", "sort", "uniq", "file", "stat", "mdfind",
        "mdls", "ping", "dig", "nslookup", "host", "ifconfig", "networksetup", "uname", "hostname", "env",
        "printenv", "id", "groups", "less", "tree", "lsof", "vm_stat", "top", "diskutil", "defaults", "sysctl",
        "pmset", "log", "tr", "cut", "awk", "sed", "jq", "xxd", "md5", "shasum", "otool", "codesign", "spctl",
        "brew", "git", "swift", "python3", "node", "npm", "xcode-select", "softwareupdate", "csrutil", "fdesetup",
    ]
    /// Subcommands and flags that make an otherwise looking command change things.
    static let changers: [String: [String]] = [
        "find": ["-delete", "-exec", "-execdir", "-ok"],
        "diskutil": ["erase", "partition", "unmount", "eject", "repair", "apfs delete", "zero", "secureErase", "mount"],
        "defaults": ["write", "delete", "import", "rename"],
        "networksetup": ["-set", "-remove", "-add", "-create", "-delete"],
        "pmset": ["-a", "-b", "-c", "-u", "sleepnow", "restoredefaults", "schedule", "repeat"],
        "brew": ["install", "uninstall", "remove", "upgrade", "update", "cleanup", "tap", "untap", "link", "unlink", "services"],
        "git": ["push", "reset", "checkout", "clean", "rebase", "merge", "commit", "rm", "mv", "restore", "switch", "branch -d", "branch -D", "stash", "pull", "tag -d"],
        "sed": ["-i"],
        "npm": ["install", "uninstall", "publish", "update", "ci", "run", "exec"],
        "softwareupdate": ["-i", "--install", "-a", "--restart"],
        "swift": ["build", "run", "test", "package"],
        "python3": [""], "node": [""],
        "csrutil": ["disable", "enable", "clear"], "fdesetup": ["enable", "disable", "changerecovery"],
        "log": ["erase", "config"], "sysctl": ["-w"], "xcode-select": ["-s", "--switch", "-r", "--reset", "--install"],
    ]

    public static func level(of command: String) -> ActionLevel {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .important }
        if text.range(of: #"(^|[\s;&|(])sudo\s"#, options: .regularExpression) != nil { return .admin }
        // Writing to a file, command substitution and backgrounding are not reading.
        if text.contains(">") || text.contains("`") || text.contains("$(") { return .important }
        let segments = text.components(separatedBy: CharacterSet(charactersIn: "|;&")).map { $0.trimmingCharacters(in: .whitespaces) }
        for segment in segments where !segment.isEmpty {
            let words = segment.split(separator: " ").map(String.init)
            guard let program = words.first.map({ ($0 as NSString).lastPathComponent }), lookers.contains(program) else {
                return .important
            }
            let rest = " " + words.dropFirst().joined(separator: " ") + " "
            if let risky = changers[program] {
                // An empty entry: the program runs code, which can do anything.
                if risky.contains("") { return .important }
                if risky.contains(where: { rest.contains(" " + $0) }) { return .important }
            }
        }
        return .read
    }
}

/// Dictation: tidying what was said before it goes into another app.
public enum Dictation {
    public enum Command: Equatable, Sendable {
        case removeLastSentence
    }

    /// A spoken command instead of text.
    public static func command(in text: String) -> Command? {
        let said = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let phrases = ["скасуй останнє речення", "видали останнє речення", "delete the last sentence", "undo the last sentence", "scratch that"]
        return phrases.contains(said) ? .removeLastSentence : nil
    }

    static let fillers: [String: [String]] = [
        "uk": ["е", "ее", "еее", "ееее", "м", "мм", "ммм", "ну", "ем", "ем-м"],
        "en": ["uh", "um", "uhm", "umm", "er", "erm", "hmm"],
    ]

    /// Takes out "um" and "ну", applies the person's own spellings, and tidies the spaces.
    public static func clean(_ text: String, language: String, dictionary: [String: String] = [:]) -> String {
        var result = " " + text + " "
        for filler in (fillers[language] ?? []) + (fillers["en"] ?? []) {
            let pattern = #"(?i)(?<=[\s,])"# + NSRegularExpression.escapedPattern(for: filler) + #"[,]?(?=\s)"#
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        for (heard, written) in dictionary where !heard.isEmpty {
            let pattern = #"(?i)\b"# + NSRegularExpression.escapedPattern(for: heard) + #"\b"#
            result = result.replacingOccurrences(of: pattern, with: written, options: .regularExpression)
        }
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard let first = result.first else { return result }
        return first.uppercased() + result.dropFirst()
    }

    /// How many characters the last sentence of what was typed takes, with the space before it.
    public static func lastSentenceLength(of text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        let body = trimmed.dropLast(trimmed.last.map { ".!?".contains($0) } == true ? 1 : 0)
        guard let end = body.lastIndex(where: { ".!?".contains($0) }) else { return text.count }
        return text.count - body.distance(from: body.startIndex, to: body.index(after: end))
    }
}

/// Reading the web for the assistant: pages as plain text, and search results.
public enum WebText {
    /// A page's words without its markup, scripts and styles.
    public static func text(fromHTML html: String, limit: Int = 12000) -> String {
        var text = html
        for pattern in [#"(?is)<script.*?</script>"#, #"(?is)<style.*?</style>"#, #"(?is)<noscript.*?</noscript>"#, #"(?s)<!--.*?-->"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, character) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'"] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    public struct Result: Equatable, Sendable {
        public let title: String
        public let url: String
        public let snippet: String
    }

    /// DuckDuckGo's plain HTML results page, which needs no key.
    public static func searchURL(_ query: String) -> URL? {
        var parts = URLComponents(string: "https://html.duckduckgo.com/html/")
        parts?.queryItems = [URLQueryItem(name: "q", value: query)]
        return parts?.url
    }

    public static func results(fromDuckDuckGo html: String, limit: Int = 8) -> [Result] {
        let link = try? NSRegularExpression(pattern: #"(?s)<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#)
        let snippet = try? NSRegularExpression(pattern: #"(?s)<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#)
        let range = NSRange(html.startIndex..., in: html)
        let links = link?.matches(in: html, range: range) ?? []
        let snippets = snippet?.matches(in: html, range: range) ?? []
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
            Range(match.range(at: index), in: html).map { String(html[$0]) } ?? ""
        }
        return links.prefix(limit).enumerated().map { index, match in
            var url = group(match, 1)
            // Results go through DuckDuckGo's redirect; the address is in its uddg parameter.
            if let parts = URLComponents(string: url.hasPrefix("//") ? "https:" + url : url),
               let target = parts.queryItems?.first(where: { $0.name == "uddg" })?.value {
                url = target
            }
            return Result(
                title: text(fromHTML: group(match, 2), limit: 200),
                url: url,
                snippet: index < snippets.count ? text(fromHTML: group(snippets[index], 1), limit: 300) : ""
            )
        }
    }
}
