import ArgumentParser
import CleanerCore
import Foundation

/// What Claude Code runs on each hook event once UniMacHub is connected to it: passes the
/// event to the app, and for a permission request, waits for the answer given in the island.
struct AgentHook: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-hook",
        abstract: "Pass a coding agent's hook event to UniMacHub's island.",
        shouldDisplay: false
    )

    @Argument(help: "The agent: claude.")
    var agent: String

    func run() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard var object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }
        object["umh_agent"] = agent
        object["umh_host"] = Self.host(ProcessInfo.processInfo.environment)
        guard let line = try? JSONSerialization.data(withJSONObject: object) else { return }
        let asks = object["hook_event_name"] as? String == "PermissionRequest"
        // Without the app, or without an answer, Claude Code carries on as it would anyway.
        guard let reply = AgentSocket.send(line, to: AgentPaths.socket.path, timeout: asks ? ClaudeSettings.questionWait : 3),
              !reply.isEmpty, let text = String(data: reply, encoding: .utf8), text != "{}"
        else { return }
        print(text)
    }

    /// The app the agent runs in, so the island can bring it forward.
    static func host(_ environment: [String: String]) -> String? {
        if let bundle = environment["__CFBundleIdentifier"], !bundle.isEmpty { return bundle }
        switch environment["TERM_PROGRAM"] {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "ghostty": return "com.mitchellh.ghostty"
        case "vscode": return "com.microsoft.VSCode"
        case "WezTerm": return "com.github.wez.wezterm"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        default: return nil
        }
    }
}

/// Claude Code's status line, run through UniMacHub so the island can show the usage limits.
/// Prints the status line there was before, or a short one of its own.
struct StatusLine: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "statusline",
        abstract: "Claude Code's status line, reading the usage limits on the way.",
        shouldDisplay: false
    )

    @Option(help: "The status line command there was before, base64-encoded.")
    var then: String?

    func run() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if let limits = ClaudeStatusLine.limits(from: input) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            if let data = try? encoder.encode(limits) {
                let url = AgentPaths.claudeLimits
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
        guard let then, let decoded = Data(base64Encoded: then), let command = String(data: decoded, encoding: .utf8) else {
            print(ClaudeStatusLine.line(from: input))
            return
        }
        // The old status line, given the same input, printing straight to Claude Code.
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        pipe.fileHandleForWriting.write(input)
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        throw ExitCode(process.terminationStatus)
    }
}
