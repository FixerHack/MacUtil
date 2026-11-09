@testable import CleanerCore
import Foundation
import Testing

struct SystemDockTests {
    @Test func putsBackExactlyWhatWasThere() {
        // Keys that were not set are deleted again, not written with a guess.
        #expect(SystemDock.restoreCommands(.init(autohide: nil, delay: nil)) == [
            ["delete", "com.apple.dock", "autohide"],
            ["delete", "com.apple.dock", "autohide-delay"],
        ])
        #expect(SystemDock.restoreCommands(.init(autohide: false, delay: 0.2)) == [
            ["write", "com.apple.dock", "autohide", "-bool", "false"],
            ["write", "com.apple.dock", "autohide-delay", "-float", "0.2"],
        ])
        #expect(SystemDock.hideCommands().contains(["write", "com.apple.dock", "autohide-delay", "-float", "1000"]))
    }

    @Test func keepsTheSystemDockOnTheSameEdgeAndPutsItBack() throws {
        // On the same edge, where Mission Control will show it.
        #expect(SystemDock.hideCommands(edge: "right").contains(["write", "com.apple.dock", "orientation", "-string", "right"]))
        // The edge comes back as it was, or goes if it was never set.
        let placed = SystemDock.Snapshot(autohide: true, delay: nil, orientation: "right", recordsPlacement: true)
        #expect(SystemDock.restoreCommands(placed).contains(["write", "com.apple.dock", "orientation", "-string", "right"]))
        let unset = SystemDock.Snapshot(autohide: nil, delay: nil, orientation: nil, recordsPlacement: true)
        #expect(SystemDock.restoreCommands(unset).contains(["delete", "com.apple.dock", "orientation"]))
        // A snapshot from the first beta never recorded it, so it is left alone.
        let old = try JSONDecoder().decode(SystemDock.Snapshot.self, from: Data(#"{"autohide":true}"#.utf8))
        #expect(!old.recordsPlacement)
        #expect(!SystemDock.restoreCommands(old).contains { $0.contains("orientation") })
    }

    @Test func knowsItsOwnHiding() {
        #expect(SystemDock.isHiddenByUs(.init(autohide: true, delay: 1000)))
        #expect(!SystemDock.isHiddenByUs(.init(autohide: true, delay: 0.5)))
        #expect(!SystemDock.isHiddenByUs(.init(autohide: nil, delay: nil)))
    }

    @Test func readsThePinnedApps() {
        let entries: [Any] = [
            ["tile-data": ["file-data": ["_CFURLString": "file:///System/Applications/Mail.app/", "_CFURLStringType": 15]]],
            ["tile-data": ["file-data": ["_CFURLString": "file:///Applications/Visual%20Studio%20Code.app/"]]],
            ["tile-data": ["file-data": ["_CFURLString": "file:///Users/me/Downloads/"]]],
            ["tile-type": "spacer-tile"],
        ]
        let apps = SystemDock.pinnedApps(from: entries)
        #expect(apps.map(\.path) == ["/System/Applications/Mail.app", "/Applications/Visual Studio Code.app"])
    }

    @Test func growsUnderThePointerAndEasesOff() {
        let size: CGFloat = 96
        #expect(DockMagnification.scale(distance: 0, iconSize: size, magnification: 1.335) == 1.335)
        let near = DockMagnification.scale(distance: 60, iconSize: size, magnification: 1.335)
        let far = DockMagnification.scale(distance: 180, iconSize: size, magnification: 1.335)
        #expect(near < 1.335 && near > far && far > 1)
        #expect(DockMagnification.scale(distance: 300, iconSize: size, magnification: 1.335) == 1)
        #expect(DockMagnification.scale(distance: 0, iconSize: size, magnification: 1) == 1)
    }
}

struct DockLayoutTests {
    let slots: [DockLayout.Slot] = [
        .init(units: 1.5, grows: false), .init(units: 0.32, grows: false),
        .init(units: 1, grows: true), .init(units: 1, grows: true), .init(units: 1, grows: true),
        .init(units: 1, grows: true), .init(units: 1, grows: true),
    ]

    @Test func laysOutEndToEndWithNothingUnderThePointer() {
        let layout = DockLayout(slots: slots, iconSize: 64, available: 2000, magnification: 1.5, pointer: nil)
        #expect(layout.icon == 64)
        #expect(layout.items.allSatisfy { $0.scale == 1 })
        #expect(layout.items[0].start == DockLayout.endPadding * 64)
        for index in 1 ..< layout.items.count {
            #expect(abs(layout.items[index].start - layout.items[index - 1].end) < 0.001)
        }
        #expect(layout.barStart == 0 && abs(layout.barEnd - layout.baseLength) < 0.001)
        #expect(layout.hovered == nil)
    }

    @Test func theIconUnderThePointerGrowsAndStaysUnderIt() throws {
        let base = DockLayout(slots: slots, iconSize: 64, available: 2000, magnification: 1.5, pointer: nil)
        for pointer in stride(from: base.items[2].start + 1, to: base.items[6].end, by: 7) {
            let layout = DockLayout(slots: slots, iconSize: 64, available: 2000, magnification: 1.5, pointer: pointer)
            let hovered = try #require(layout.hovered)
            // The icon drawn under the pointer is the one that takes the click and shows its name.
            #expect(layout.items[hovered].start <= pointer && pointer < layout.items[hovered].end)
            let baseHit = try #require(base.items.indices.first { base.items[$0].start <= pointer && pointer < base.items[$0].end })
            #expect(hovered == baseHit)
            #expect(layout.items[hovered].scale > 1)
            // Widgets never grow.
            #expect(layout.items[0].scale == 1)
        }
    }

    @Test func shrinksToFitTheScreen() {
        let units = slots.reduce(0) { $0 + $1.units } + 2 * DockLayout.endPadding
        let layout = DockLayout(slots: slots, iconSize: 128, available: 400, magnification: 1, pointer: nil)
        #expect(abs(layout.icon - 400 / units) < 0.001)
        #expect(layout.baseLength <= 400.001)
    }
}

struct WeatherTests {
    @Test func findsTheTownAndReadsTheWeather() throws {
        let search = Data(#"{"results":[{"name":"Київ","latitude":50.45466,"longitude":30.5238,"country":"Україна"}]}"#.utf8)
        let place = try #require(Weather.place(fromSearch: search))
        #expect(place.name == "Київ" && place.latitude == 50.45466)
        #expect(Weather.place(fromSearch: Data(#"{"generationtime_ms":0.5}"#.utf8)) == nil)

        let url = try #require(Weather.forecastURL(for: place))
        #expect(url.absoluteString.contains("latitude=50.455") && url.host() == "api.open-meteo.com")
        #expect(Weather.searchURL(for: "Київ", language: "uk")?.query?.contains("language=uk") == true)

        let forecast = Data(#"{"current":{"temperature_2m":3.4,"weather_code":61,"is_day":0},"daily":{"temperature_2m_max":[5.1],"temperature_2m_min":[-1.2]}}"#.utf8)
        let now = try #require(Weather.now(fromForecast: forecast))
        #expect(now.temperature == 3.4 && now.code == 61 && !now.isDay && now.high == 5.1 && now.low == -1.2)
        #expect(Weather.symbol(for: 61, isDay: false) == "cloud.rain.fill")
        #expect(Weather.symbol(for: 0, isDay: false) == "moon.stars.fill")
    }
}

struct ArithmeticTests {
    @Test func worksOutWhatIsTyped() {
        #expect(Arithmetic.evaluate("12 × (3 + 4) ÷ 2") == 42)
        #expect(Arithmetic.evaluate("2^3^2") == 512)
        #expect(Arithmetic.evaluate("-3 + 5") == 2)
        #expect(Arithmetic.evaluate("1,5 * 2") == 3)
        #expect(Arithmetic.evaluate("200 * 15%") == 30)
        #expect(Arithmetic.evaluate("10 − 4") == 6)
    }

    @Test func refusesWhatIsNotArithmetic() {
        #expect(Arithmetic.evaluate("") == nil)
        #expect(Arithmetic.evaluate("1 / 0") == nil)
        #expect(Arithmetic.evaluate("2 +") == nil)
        #expect(Arithmetic.evaluate("(1 + 2") == nil)
        #expect(Arithmetic.evaluate("FUNCTION(1, 'exit')") == nil)
    }

    @Test func writesTheAnswerPlainly() {
        #expect(Arithmetic.format(42) == "42")
        #expect(Arithmetic.format(0.1 + 0.2) == "0.3")
        #expect(Arithmetic.format(-2.5) == "-2.5")
    }
}

struct AssistantPolicyTests {
    @Test func importantAlwaysAsksAndBasicStaysHome() {
        #expect(AssistantPolicy.decide(level: .important, category: .uniMacHub, mode: .free) == .ask)
        #expect(AssistantPolicy.decide(level: .reversible, category: .uniMacHub, mode: .basic) == .run)
        if case .refuse = AssistantPolicy.decide(level: .read, category: .terminal, mode: .basic) {} else { Issue.record("terminal ran in basic mode") }
        // A table that allows deleting still asks for it.
        var table = PermissionTable()
        table.policies[.deleteFiles] = .allowed
        #expect(AssistantPolicy.decide(level: .reversible, category: .deleteFiles, mode: .custom, table: table) == .ask)
        table.policies[.internet] = .forbidden
        if case .refuse = AssistantPolicy.decide(level: .read, category: .internet, mode: .custom, table: table) {} else { Issue.record("forbidden ran") }
    }

    @Test func customFoldersAndCommandPrefixes() {
        let table = PermissionTable(folders: ["/Users/me/Projects"], commandPrefixes: ["git status"])
        #expect(AssistantPolicy.decide(level: .read, category: .readFiles, mode: .custom, table: table, paths: ["/Users/me/Projects/a.txt"]) == .run)
        if case .refuse = AssistantPolicy.decide(level: .read, category: .readFiles, mode: .custom, table: table, paths: ["/Users/me/ProjectsX/a"]) {} else { Issue.record("left the folder") }
        #expect(AssistantPolicy.decide(level: .read, category: .terminal, mode: .custom, table: table, command: "git status -s") == .run)
        #expect(AssistantPolicy.decide(level: .read, category: .terminal, mode: .custom, table: table, command: "ls") == .ask)
    }

    @Test func judgesShellCommands() {
        #expect(ShellRisk.level(of: "ls -la ~/Desktop | head") == .read)
        #expect(ShellRisk.level(of: "git log --oneline -5") == .read)
        #expect(ShellRisk.level(of: "defaults read com.apple.dock") == .read)
        #expect(ShellRisk.level(of: "rm -rf ~/Desktop/x") == .important)
        #expect(ShellRisk.level(of: "find . -name '*.log' -delete") == .important)
        #expect(ShellRisk.level(of: "echo hi > file.txt") == .important)
        #expect(ShellRisk.level(of: "git push --force") == .important)
        #expect(ShellRisk.level(of: "ls; rm x") == .important)
        #expect(ShellRisk.level(of: "sudo purge") == .admin)
        #expect(ShellRisk.level(of: "python3 -c 'print(1)'") == .important)
    }

    @Test func tidiesDictation() {
        #expect(Dictation.clean("ну еее я думаю що це добре", language: "uk") == "Я думаю що це добре")
        #expect(Dictation.clean("um so uh we ship today", language: "en") == "So we ship today")
        #expect(Dictation.clean("відкрий юні мак хаб", language: "uk", dictionary: ["юні мак хаб": "UniMacHub"]) == "Відкрий UniMacHub")
        #expect(Dictation.command(in: "Скасуй останнє речення.") == .removeLastSentence)
        #expect(Dictation.lastSentenceLength(of: "First one. Second one.") == " Second one.".count)
        #expect(Dictation.lastSentenceLength(of: "Only one") == "Only one".count)
    }

    @Test func readsPagesAndSearchResults() {
        #expect(WebText.text(fromHTML: "<html><script>x()</script><p>Hello &amp; welcome</p><p>Two</p></html>") == "Hello & welcome\nTwo")
        let html = #"<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=x">Example <b>A</b></a><a class="result__snippet" href="x">Snippet <b>one</b></a>"#
        let results = WebText.results(fromDuckDuckGo: html)
        #expect(results.first?.title == "Example A")
        #expect(results.first?.snippet == "Snippet one")
        #expect(results.first?.url.hasPrefix("https://example.com/a") == true)
    }

    @Test func buildsEachProvidersRequest() throws {
        let actions = [ActionSpec(name: "disk_status", summary: "Disk.", level: .read)]
        let turns: [ConversationTurn] = [
            .user("How much space?"),
            .assistant(text: "", calls: [ActionCall(id: "t1", name: "disk_status", arguments: .object([:]))], raw: nil),
            .result(callID: "t1", name: "disk_status", text: "10 GB free", failed: false),
        ]
        let anthropic = ProviderWire.anthropicBody(system: "s", turns: turns, actions: actions, model: "claude-opus-5-5")
        let messages = try #require(anthropic["messages"]?.array)
        #expect(messages.count == 3)
        #expect(messages[2]["content"]?.array?.first?["type"]?.string == "tool_result")
        #expect(anthropic["tools"]?.array?.first?["input_schema"] != nil)
        let openAI = ProviderWire.openAIBody(system: "s", turns: turns, actions: actions, model: "m")
        #expect(openAI["messages"]?.array?.last?["role"]?.string == "tool")
        let gateway = ProviderWire.gatewayBody(system: "s", turns: turns, actions: actions, model: "opus")
        #expect(gateway["prompt"]?.string?.contains("10 GB free") == true)

        let reply = try ProviderWire.gatewayReply(.object(["structured": .object([
            "say": .string("Checking."), "action": .object(["name": .string("disk_status"), "arguments": .object([:])]),
        ])]))
        #expect(reply.text == "Checking." && reply.calls.first?.name == "disk_status")
        let toolUse = try ProviderWire.anthropicReply(.object(["stop_reason": .string("tool_use"), "content": .array([
            .object(["type": .string("text"), "text": .string("On it.")]),
            .object(["type": .string("tool_use"), "id": .string("x"), "name": .string("disk_status"), "input": .object([:])]),
        ])]))
        #expect(toolUse.calls.count == 1 && toolUse.text == "On it.")
    }
}
