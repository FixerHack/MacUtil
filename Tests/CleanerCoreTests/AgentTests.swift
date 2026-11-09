@testable import CleanerCore
import Foundation
import Testing

struct ClaudeHookEventTests {
    private func event(_ object: [String: Any]) throws -> ClaudeHookEvent {
        var object = object
        object["session_id"] = object["session_id"] ?? "s1"
        object["cwd"] = object["cwd"] ?? "/Users/me/projects/shop"
        return try #require(ClaudeHookEvent(json: JSONSerialization.data(withJSONObject: object)))
    }

    @Test func followsASessionThroughItsTurn() throws {
        let start = Date(timeIntervalSince1970: 0)
        var session = try AgentSession(event: event(["hook_event_name": "SessionStart", "umh_host": "com.apple.Terminal"]), at: start)
        #expect(session.state == .ready && session.project == "shop" && session.host == "com.apple.Terminal")

        _ = try session.apply(event(["hook_event_name": "UserPromptSubmit", "prompt": "hi"]), at: start)
        #expect(session.isWorking)
        _ = try session.apply(event(["hook_event_name": "PreToolUse", "tool_name": "Bash"]), at: start)
        #expect(session.state == .working("Bash"))

        let ask = try event([
            "hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "tool_input": ["command": "git push\nsecond line", "description": "Push"],
        ])
        #expect(ask.isPermissionRequest && ask.toolSummary == "git push")
        _ = session.apply(ask, at: start)
        #expect(session.state == .needsPermission("git push") && session.needsYou)

        // The terminal's own prompt notice does not replace the question already shown.
        _ = try session.apply(event(["hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "Claude needs your permission"]), at: start)
        #expect(session.state == .needsPermission("git push"))

        _ = try session.apply(event(["hook_event_name": "Stop", "last_assistant_message": "All pushed.\nDetails"]), at: start)
        #expect(session.state == .done("All pushed."))
        // Waiting after a finished turn is nothing new.
        _ = try session.apply(event(["hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "waiting"]), at: start)
        #expect(session.state == .done("All pushed."))

        let ended = try !session.apply(event(["hook_event_name": "SessionEnd", "reason": "other"]), at: start)
        #expect(ended)
    }

    @Test func summarisesToolCalls() {
        #expect(ClaudeHookEvent.summary(of: ["file_path": "/a/b/main.swift"], tool: "Edit") == "Edit main.swift")
        #expect(ClaudeHookEvent.summary(of: ["url": "https://x.dev"], tool: "WebFetch") == "WebFetch https://x.dev")
        #expect(ClaudeHookEvent.summary(of: nil, tool: "Task") == "Task")
        #expect(ClaudeHookEvent.clip(String(repeating: "a", count: 300)).count == 140)
        #expect(ClaudeHookEvent(json: Data("{}".utf8)) == nil)
    }
}

struct ClaudeSettingsTests {
    private let mucli = "/Applications/UniMacHub.app/Contents/Resources/mucli"

    /// Another app's hooks and a status line someone already had.
    private var existing: [String: Any] {
        [
            "theme": "dark",
            "hooks": [
                "Stop": [["hooks": [["type": "http", "url": "http://127.0.0.1:58371/event", "timeout": 1]]]],
            ],
            "statusLine": ["type": "command", "command": "~/bin/my line.sh 'quoted'", "padding": 1],
        ]
    }

    @Test func addsItsOwnBesideWhatIsThere() throws {
        let connected = ClaudeSettings.connecting(existing, mucli: mucli)
        #expect(ClaudeSettings.isConnected(connected))
        let hooks = try #require(connected["hooks"] as? [String: Any])
        for event in ClaudeSettings.events {
            let groups = try #require(hooks[event] as? [[String: Any]])
            #expect(groups.filter(ClaudeSettings.isOurs).count == 1)
        }
        // The other app's Stop hook is still first.
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2 && !ClaudeSettings.isOurs(stop[0]))
        let ask = try #require((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(ask.first?["timeout"] as? Int == ClaudeSettings.permissionTimeout)

        // The old status line runs through UniMacHub and keeps its padding.
        let line = try #require(connected["statusLine"] as? [String: Any])
        let command = try #require(line["command"] as? String)
        #expect(command.hasPrefix("'\(mucli)' statusline --then "))
        #expect(ClaudeSettings.previousStatusCommand(in: command) == "~/bin/my line.sh 'quoted'")
        #expect(line["padding"] as? Int == 1)

        // Connecting twice does not double anything.
        let twice = ClaudeSettings.connecting(connected, mucli: mucli)
        #expect(((twice["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.count == 2)
        #expect(ClaudeSettings.previousStatusCommand(in: (twice["statusLine"] as? [String: Any])?["command"] as? String ?? "") == "~/bin/my line.sh 'quoted'")
    }

    @Test func takesOutExactlyWhatItAdded() throws {
        let back = ClaudeSettings.disconnecting(ClaudeSettings.connecting(existing, mucli: mucli))
        let before = try JSONSerialization.data(withJSONObject: existing, options: .sortedKeys)
        let after = try JSONSerialization.data(withJSONObject: back, options: .sortedKeys)
        #expect(before == after)

        // With nothing there before, nothing is left behind.
        let empty = ClaudeSettings.disconnecting(ClaudeSettings.connecting([:], mucli: mucli))
        #expect(empty.isEmpty)
    }

    @Test func quotesThePathForTheShell() {
        #expect(ClaudeSettings.hookCommand(mucli: "/A b/it's/mucli") == "[ -x '/A b/it'\\''s/mucli' ] && '/A b/it'\\''s/mucli' agent-hook claude || true")
    }

    @Test func refusesAFileThatIsNotJSONAndKeepsABackup() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "claude-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "settings.json")

        #expect(try ClaudeSettings.read(from: file).isEmpty)
        try Data("// a comment\n{}".utf8).write(to: file)
        #expect(throws: ClaudeSettings.Failure.unreadable) { try ClaudeSettings.read(from: file) }

        try Data(#"{"theme":"dark"}"#.utf8).write(to: file)
        try ClaudeSettings.write(ClaudeSettings.connecting(ClaudeSettings.read(from: file), mucli: mucli), to: file)
        #expect(try ClaudeSettings.isConnected(ClaudeSettings.read(from: file)))
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".backup") }
        #expect(backups.count == 1)
    }

    @Test func readsTheLimitsFromTheStatusLine() throws {
        let json = Data("""
        {"model":{"display_name":"Opus"},"context_window":{"used_percentage":8},
         "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}
        """.utf8)
        let limits = try #require(ClaudeStatusLine.limits(from: json))
        #expect(limits.fiveHour?.usedPercent == 23.5)
        #expect(limits.week?.resetsAt == Date(timeIntervalSince1970: 1_738_857_600))
        #expect(ClaudeStatusLine.line(from: json) == "Opus · ctx 8% · 5h 24% · 7d 41%")
        #expect(ClaudeStatusLine.limits(from: Data(#"{"model":{}}"#.utf8)) == nil)
        // A window that has reset is dropped.
        #expect(limits.current(at: Date(timeIntervalSince1970: 1_738_500_000)).fiveHour == nil)
    }
}

struct ClaudeAppUsageTests {
    @Test func takesTheLatestSampleWhileItsWindowCanStillBeCurrent() throws {
        let json = Data(#"{"version":2,"samples":[{"t":1000000000,"u":{"fh":10,"sd":5}},{"t":1000003600000,"u":{"fh":71,"sd":14}}]}"#.utf8)
        let taken = Date(timeIntervalSince1970: 1_000_003_600)
        let fresh = try #require(ClaudeAppUsage.limits(from: json, now: taken.addingTimeInterval(3600)))
        #expect(fresh.fiveHour?.usedPercent == 71 && fresh.week?.usedPercent == 14 && fresh.updated == taken)
        // A day later the five-hour figure says nothing; the weekly one still does.
        let later = try #require(ClaudeAppUsage.limits(from: json, now: taken.addingTimeInterval(24 * 3600)))
        #expect(later.fiveHour == nil && later.week?.usedPercent == 14)
        #expect(ClaudeAppUsage.limits(from: json, now: taken.addingTimeInterval(8 * 24 * 3600)) == nil)
    }
}

struct CodexSessionsTests {
    private let head = #"{"timestamp":"t","type":"session_meta","payload":{"id":"abc","cwd":"/Users/me/app","originator":"Codex Desktop"}}"#

    private func line(_ type: String, _ extra: String = "") -> String {
        #"{"timestamp":"t","type":"event_msg","payload":{"type":"\#(type)"\#(extra)}}"#
    }

    @Test func readsStateAndLimits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let limits = #","rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1000500},"secondary":{"used_percent":71.0,"window_minutes":10080,"resets_at":1500000}}"#
        let working = CodexSessions.read(
            head: head, tail: [line("task_started"), line("token_count", limits)].joined(separator: "\n"),
            modified: now, now: now
        )
        #expect(working.session?.isWorking == true)
        #expect(working.session?.project == "app" && working.session?.host == "com.openai.codex")
        #expect(working.limits?.fiveHour?.usedPercent == 12 && working.limits?.week?.usedPercent == 71)

        let done = CodexSessions.read(
            head: head,
            tail: [line("task_started"), line("agent_message", ##","message":"Finished the refactor.""##), line("task_complete")].joined(separator: "\n"),
            modified: now, now: now
        )
        #expect(done.session?.state == .done("Finished the refactor."))

        // A turn that started long ago and wrote nothing since has stalled.
        let stalled = CodexSessions.read(head: head, tail: line("task_started"), modified: now, now: now.addingTimeInterval(3600))
        #expect(stalled.session?.isWorking == false)

        #expect(CodexSessions.read(head: "garbage", tail: "", modified: now).session == nil)
    }

    @Test func readsTheWholeFirstLineAndTheEnd() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        // A first line far longer than one read, as Codex writes it.
        let longHead = head.replacingOccurrences(of: #""originator""#, with: #""pad":"\#(String(repeating: "x", count: 150_000))","originator""#)
        let body = (0 ..< 3000).map { _ in line("item_completed") } + [line("task_complete")]
        try ([longHead] + body).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let read = try #require(CodexSessions.headAndTail(of: file))
        #expect(read.head == longHead)
        #expect(read.tail.hasSuffix(line("task_complete")))
        #expect(CodexSessions.read(head: read.head, tail: read.tail, modified: Date()).session?.state == .done(nil))
    }
}

struct BatteryTests {
    @Test func readsAirPodsFromSystemProfiler() {
        let json = Data("""
        {"SPBluetoothDataType":[{"device_connected":[
          {"AirPods Pro":{"device_batteryLevelLeft":"80%","device_batteryLevelRight":"74%","device_batteryLevelCase":"50%","device_minorType":"Headphones"}},
          {"Magic Keyboard":{"device_batteryLevelMain":"60%","device_minorType":"Keyboard"}}
        ]}]}
        """.utf8)
        let found = Batteries.headphones(fromSystemProfiler: json)
        #expect(found == [DeviceBattery(name: "AirPods Pro", kind: .headphones, level: 74, left: 80, right: 74, caseLevel: 50)])
        #expect(Batteries.headphones(fromSystemProfiler: Data("[]".utf8)).isEmpty)
        #expect(Batteries.kind(ofProduct: "Magic Trackpad") == .trackpad)
    }
}

struct AgentSocketTests {
    @Test func carriesALineEachWayAndHoldsAnAnswer() async throws {
        // Short: a socket's path has to fit in about a hundred bytes.
        let path = "/tmp/umh-\(UUID().uuidString.prefix(8)).sock"
        let server = AgentSocketServer(path: path) { line, reply in
            if line == Data("ask".utf8) {
                // Answered later, the way a question waits for the person.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { reply.send(Data("yes".utf8)) }
            } else {
                reply.send()
            }
        }
        try server.start()
        defer { server.stop() }

        var info = stat()
        #expect(stat(path, &info) == 0 && info.st_mode & 0o077 == 0)

        let quick = await Task.detached { AgentSocket.send(Data("hello".utf8), to: path, timeout: 3) }.value
        #expect(quick == Data())
        let answer = await Task.detached { AgentSocket.send(Data("ask".utf8), to: path, timeout: 3) }.value
        #expect(answer == Data("yes".utf8))
        #expect(AgentSocket.send(Data("x".utf8), to: path + ".none", timeout: 1) == nil)
    }
}
