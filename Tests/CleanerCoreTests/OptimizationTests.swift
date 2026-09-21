@testable import CleanerCore
import Foundation
import Testing

struct MaintenanceTests {
    @Test func quotesAdminScripts() {
        let script = AdminRunner.appleScript(["echo \"hi\"", #"ls /tmp\ dir"#], prompt: "Need \"password\"")
        #expect(script ==
            #"do shell script "echo \"hi\" ; ls /tmp\\ dir" with prompt "Need \"password\"" with administrator privileges without altering line endings"#)
    }

    @Test func splitsFramedOutputPerTask() {
        let output = AdminRunner.Output(
            succeeded: true,
            text: "<<dns>>\n<<status 0>>\n<<verifyDisk>>\nChecking volume\nError: bad\n<<status 1>>\n",
            wasCancelled: false
        )
        let results = MaintenanceCatalog.split(output)
        #expect(results["dns"]?.succeeded == true)
        #expect(results["verifyDisk"]?.succeeded == false)
        #expect(results["verifyDisk"]?.text == "Checking volume\nError: bad")
    }

    @Test func catalogIsConsistent() {
        #expect(Set(MaintenanceCatalog.all.map(\.id)).count == MaintenanceCatalog.all.count)
        #expect(MaintenanceCatalog.all.allSatisfy { !$0.commands.isEmpty })
    }

    @Test func runsUserTasksWithoutAPassword() async {
        let task = MaintenanceTask(
            id: "echo", title: "t", details: "d", symbol: "x", requiresAdmin: false,
            commands: ["echo done"], followUp: nil
        )
        let results = await MaintenanceCatalog.run([task])
        #expect(results["echo"]?.succeeded == true)
        #expect(results["echo"]?.text.contains("done") == true)
    }
}

@Suite(.serialized)
struct HiddenSettingsTests {
    /// A throwaway preferences domain so the test never touches real settings.
    let setting = HiddenSetting(
        id: "test", section: .general, title: "t", details: "d",
        domain: "com.fixerhack.MacUtil.tests", key: "TestFlag",
        options: [HiddenSetting.Option(title: "On", value: .bool(true))], restarts: nil
    )

    @Test func appliesReadsAndRevertsASetting() async {
        await HiddenSettings.apply(nil, to: setting)
        #expect(HiddenSettings.currentValue(of: setting) == nil)
        #expect(!HiddenSettings.isOn(setting))

        #expect(await HiddenSettings.apply(.bool(true), to: setting))
        #expect(HiddenSettings.isOn(setting))

        await HiddenSettings.apply(nil, to: setting)
        #expect(HiddenSettings.currentValue(of: setting) == nil)
    }

    @Test func convertsStoredValues() {
        #expect(HiddenSettings.value("1", like: .bool(false)) == .bool(true))
        #expect(HiddenSettings.value(NSNumber(value: 0), like: .bool(true)) == .bool(false))
        #expect(HiddenSettings.value("0.25", like: .float(0)) == .float(0.25))
        #expect(HiddenSettings.value("scale", like: .string("")) == .string("scale"))
    }

    @Test func catalogIsConsistent() {
        #expect(Set(HiddenSettings.all.map(\.id)).count == HiddenSettings.all.count)
        #expect(HiddenSettings.all.allSatisfy { !$0.options.isEmpty })
    }
}

struct ProcessMonitorTests {
    @Test func parsesPS() {
        let output = """
          1   0.3   4944 root             /sbin/launchd
        812  12.5 204800 tester           /Applications/Some App.app/Contents/MacOS/Some App
        """
        let processes = ProcessMonitor.parse(output)
        #expect(processes.count == 2)
        #expect(processes.last?.name == "Some App")
        #expect(processes.last?.memory == Int64(204_800 * 1024))
        #expect(processes.last?.cpu == 12.5)
    }

    @Test func readsRealProcessesAndMemory() async throws {
        #expect(await ProcessMonitor.processes().count > 20)
        let memory = try #require(ProcessMonitor.memory())
        #expect(memory.total > 1_000_000_000)
        #expect(memory.used > 0 && memory.used <= memory.total)
    }
}

struct PrivacyRuleTests {
    @Test func findsBrowserHistoryAndLocksRunningBrowser() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "mc-privacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for path in [
            "Library/Application Support/Google/Chrome/Default/History",
            "Library/Application Support/Google/Chrome/Default/Bookmarks",
            "Library/Application Support/BraveSoftware/Brave-Browser/Profile 1/History",
            ".zsh_history",
        ] {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(count: 5000).write(to: url)
        }
        let context = JunkContext(
            home: home,
            runningBundleIDs: ["com.brave.Browser"],
            installed: InstalledApps(bundleIDs: [])
        )
        let categories = await JunkScanner.scan(JunkCatalog.rules(in: .privacy), context: context)
        let history = try #require(categories.first { $0.rule.id == "privacy.browserHistory" })

        #expect(history.items.count == 2, "bookmarks are not history")
        #expect(history.items.first { $0.path.contains("BraveSoftware") }?.inUseBy == "com.brave.Browser")
        #expect(history.items.first { $0.path.contains("Google") }?.isInUse == false)
        #expect(categories.contains { $0.rule.id == "privacy.terminalHistory" })
    }
}
