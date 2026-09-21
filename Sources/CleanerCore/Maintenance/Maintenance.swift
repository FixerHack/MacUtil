import Foundation

/// Runs shell commands with administrator rights through the standard macOS
/// password prompt (`do shell script … with administrator privileges`).
/// All commands of one call share a single prompt.
public enum AdminRunner {
    public struct Output: Sendable {
        public let succeeded: Bool
        public let text: String
        /// The user closed the password prompt.
        public let wasCancelled: Bool
    }

    public static func run(_ commands: [String], prompt: String) async -> Output {
        let script = appleScript(commands, prompt: prompt)
        guard let output = await Command.run("/usr/bin/osascript", ["-e", script], timeout: .seconds(600)) else {
            return Output(succeeded: false, text: "", wasCancelled: false)
        }
        // osascript reports "User canceled. (-128)" when the prompt is dismissed.
        let cancelled = output.text.contains("(-128)")
        return Output(succeeded: output.status == 0, text: output.text, wasCancelled: cancelled)
    }

    /// `do shell script "a ; b" with prompt "…" with administrator privileges`, quoted for AppleScript.
    static func appleScript(_ commands: [String], prompt: String) -> String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let shell = commands.joined(separator: " ; ")
        // Without "altering line endings" AppleScript turns \n into \r in the output.
        return "do shell script \(quoted(shell)) with prompt \(quoted(prompt)) with administrator privileges without altering line endings"
    }
}

/// A maintenance job like the ones OnyX offers.
public struct MaintenanceTask: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: LocalizedStringResource
    public let details: LocalizedStringResource
    public let symbol: String
    public let requiresAdmin: Bool
    public let commands: [String]
    /// Shown after the task ran, for example "Restart to finish".
    public let followUp: LocalizedStringResource?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public enum MaintenanceCatalog {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    public static let all: [MaintenanceTask] = [
        MaintenanceTask(
            id: "dns", title: "Flush DNS cache",
            details: "Fixes websites that do not open or open the wrong server after a network change.",
            symbol: "network", requiresAdmin: true,
            commands: ["dscacheutil -flushcache", "killall -HUP mDNSResponder"], followUp: nil
        ),
        MaintenanceTask(
            id: "memory", title: "Free up memory",
            details: "Clears the disk cache from memory. macOS refills it as needed, so the effect is short-lived.",
            symbol: "memorychip", requiresAdmin: true,
            commands: ["purge"], followUp: nil
        ),
        MaintenanceTask(
            id: "spotlight", title: "Reindex Spotlight",
            details: "Rebuilds the search index when Spotlight misses files or shows stale results. Takes a while in the background.",
            symbol: "magnifyingglass", requiresAdmin: true,
            commands: ["mdutil -E /"], followUp: "Spotlight rebuilds its index in the background."
        ),
        MaintenanceTask(
            id: "launchServices", title: "Rebuild Launch Services",
            details: "Fixes duplicate apps in the Open With menu and files opening in the wrong app.",
            symbol: "arrow.up.forward.app", requiresAdmin: false,
            commands: ["\(lsregister) -kill -r -domain local -domain system -domain user"], followUp: nil
        ),
        MaintenanceTask(
            id: "quickLook", title: "Reset Quick Look",
            details: "Clears thumbnail and preview caches when previews look wrong or outdated.",
            symbol: "eye", requiresAdmin: false,
            commands: ["qlmanage -r", "qlmanage -r cache"], followUp: nil
        ),
        MaintenanceTask(
            id: "fonts", title: "Clear font caches",
            details: "Fixes garbled or missing fonts.",
            symbol: "textformat", requiresAdmin: false,
            commands: ["atsutil databases -removeUser"], followUp: "Restart the Mac to finish."
        ),
        MaintenanceTask(
            id: "icons", title: "Rebuild icon cache",
            details: "Fixes blank or wrong icons in Finder and the Dock.",
            symbol: "app.dashed", requiresAdmin: true,
            commands: ["rm -rf /Library/Caches/com.apple.iconservices.store", "killall Dock", "killall Finder || true"],
            followUp: nil
        ),
        MaintenanceTask(
            id: "dockFinder", title: "Restart Dock and Finder",
            details: "Helps when the Dock, Finder or the desktop stop responding.",
            symbol: "dock.rectangle", requiresAdmin: false,
            commands: ["killall Dock", "killall Finder"], followUp: nil
        ),
        MaintenanceTask(
            id: "snapshots", title: "Thin Time Machine snapshots",
            details: "Removes local Time Machine snapshots that hold on to disk space. Backups on your backup disk are not touched.",
            symbol: "clock.arrow.circlepath", requiresAdmin: true,
            commands: ["tmutil thinlocalsnapshots / 999999999999 4"], followUp: nil
        ),
        MaintenanceTask(
            id: "verifyDisk", title: "Verify startup disk",
            details: "Checks the file system for errors without changing anything.",
            symbol: "internaldrive", requiresAdmin: true,
            commands: ["diskutil verifyVolume /"], followUp: nil
        ),
        MaintenanceTask(
            id: "homePermissions", title: "Repair home folder permissions",
            details: "Resets permissions in your home folder when apps cannot save files or settings.",
            symbol: "person.badge.key", requiresAdmin: true,
            commands: ["diskutil resetUserPermissions / \(getuid())"], followUp: "Restart the Mac to finish."
        ),
    ]

    /// Runs tasks, asking for the administrator password once for all admin tasks.
    public static func run(_ tasks: [MaintenanceTask]) async -> [String: AdminRunner.Output] {
        var results: [String: AdminRunner.Output] = [:]
        for task in tasks where !task.requiresAdmin {
            var text = ""
            var succeeded = true
            for command in task.commands {
                let output = await Command.run("/bin/sh", ["-c", command], timeout: .seconds(300))
                text += output?.text ?? ""
                // killall exits 1 when nothing was running; that is fine.
                if (output?.status ?? 1) != 0, !command.hasPrefix("killall") {
                    succeeded = false
                }
            }
            results[task.id] = AdminRunner.Output(succeeded: succeeded, text: text, wasCancelled: false)
        }
        let adminTasks = tasks.filter(\.requiresAdmin)
        if !adminTasks.isEmpty {
            // One prompt; each task's output is framed so it can be told apart.
            let commands = adminTasks.map { task in
                "echo '<<\(task.id)>>' ; ( " + task.commands.joined(separator: " ; ") + " ) 2>&1 ; echo \"<<status $?>>\""
            }
            let output = await AdminRunner.run(
                commands,
                prompt: String(localized: "MacUtil needs your password to run maintenance tasks.")
            )
            for (id, result) in split(output) {
                results[id] = result
            }
            for task in adminTasks where results[task.id] == nil {
                results[task.id] = AdminRunner.Output(
                    succeeded: false,
                    text: output.text,
                    wasCancelled: output.wasCancelled
                )
            }
        }
        return results
    }

    /// Splits framed admin output into per-task results.
    static func split(_ output: AdminRunner.Output) -> [String: AdminRunner.Output] {
        var results: [String: AdminRunner.Output] = [:]
        var current: String?
        var lines: [String] = []
        for line in output.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("<<"), line.hasSuffix(">>"), !line.hasPrefix("<<status") {
                current = String(line.dropFirst(2).dropLast(2))
                lines = []
            } else if line.hasPrefix("<<status "), let id = current {
                let status = Int(line.dropFirst("<<status ".count).dropLast(2)) ?? 1
                results[id] = AdminRunner.Output(
                    succeeded: status == 0,
                    text: lines.joined(separator: "\n"),
                    wasCancelled: false
                )
                current = nil
            } else {
                lines.append(line)
            }
        }
        return results
    }
}
