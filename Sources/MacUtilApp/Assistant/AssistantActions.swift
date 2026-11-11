import AppKit
import ApplicationServices
import CleanerCore
import Foundation
@preconcurrency import ScreenCaptureKit

/// How an action went, for the model, the log, and undoing it.
struct ActionOutcome {
    var text: String
    var failed = false
    var image: Data?
    /// Puts things back, when that is possible; says what it did.
    var undo: (@MainActor () async -> String)?
}

/// One thing the assistant can do: what the model is told, which kind of thing it is, how
/// much it may change, and doing it.
@MainActor
struct AssistantAction {
    let spec: ActionSpec
    let category: ActionCategory
    /// The level for one particular call, such as a shell command judged by what it runs.
    var levelFor: (JSONValue) -> ActionLevel
    /// Paths the call touches, for the custom mode's folders.
    var paths: (JSONValue) -> [String]
    var command: (JSONValue) -> String?
    /// What the person is asked, in their words.
    var question: (JSONValue) -> String
    let run: @MainActor (JSONValue, AppState) async -> ActionOutcome

    init(
        _ name: String, _ summary: String, category: ActionCategory, level: ActionLevel,
        parameters: [String: JSONValue] = [:], required: [String] = [],
        levelFor: ((JSONValue) -> ActionLevel)? = nil,
        paths: ((JSONValue) -> [String])? = nil,
        command: ((JSONValue) -> String?)? = nil,
        question: ((JSONValue) -> String)? = nil,
        run: @escaping @MainActor (JSONValue, AppState) async -> ActionOutcome
    ) {
        spec = ActionSpec(
            name: name, summary: summary,
            parameters: .object([
                "type": .string("object"), "properties": .object(parameters),
                "required": .array(required.map { .string($0) }),
            ]),
            level: level
        )
        self.category = category
        self.levelFor = levelFor ?? { _ in level }
        self.paths = paths ?? { _ in [] }
        self.command = command ?? { _ in nil }
        self.question = question ?? { arguments in
            let detail = arguments.text == "{}" ? "" : " " + arguments.text
            return String(localized: "Run “\(name)”\(detail)?")
        }
        self.run = run
    }
}

/// Every action the assistant has, by mode.
@MainActor
enum AssistantActions {
    private static func string(_ description: String = "") -> JSONValue {
        description.isEmpty ? .object(["type": .string("string")]) : .object(["type": .string("string"), "description": .string(description)])
    }

    /// One of these values; with none to offer, any text (an empty list is not valid JSON Schema).
    private static func choice(_ values: [String]) -> JSONValue {
        values.isEmpty
            ? .object(["type": .string("string")])
            : .object(["type": .string("string"), "enum": .array(values.map { .string($0) })])
    }

    private static let integer: JSONValue = .object(["type": .string("integer")])
    private static let boolean: JSONValue = .object(["type": .string("boolean")])

    static func path(_ value: JSONValue?) -> String {
        ((value?.string ?? "") as NSString).expandingTildeInPath
    }

    static func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }

    /// The junk tools, by the name the model uses.
    static func junkStore(_ name: String, _ state: AppState) -> JunkStore? {
        switch name {
        case "systemJunk": state.systemJunk
        case "developerJunk": state.developerJunk
        case "leftovers": state.leftovers
        case "privacy": state.privacy
        default: nil
        }
    }

    /// The actions offered now: the mode's, without what the provider cannot use.
    static func available(_ state: AppState, mode: AssistantMode, table: PermissionTable, seesImages: Bool) -> [AssistantAction] {
        all(state).filter { action in
            if action.category == .screen, !seesImages { return false }
            switch mode {
            case .basic: return !AssistantPolicy.outsideBasicForUI.contains(action.category)
            case .custom: return table.policy(action.category) != .forbidden
            case .free: return true
            }
        }
    }

    static func all(_ state: AppState) -> [AssistantAction] {
        unimachub(state) + apps + files + terminal + internet + screen
    }

    // MARK: - UniMacHub and the Mac

    static func unimachub(_ state: AppState) -> [AssistantAction] {
        let tools = Module.allCases.filter { !$0.isPlanned && $0 != .hub }
        let profiles = state.dock.profiles.map(\.name)
        var list: [AssistantAction] = []
        list.append(AssistantAction(
                "open_tool", "Opens one of UniMacHub's tools on screen. Tools: " + tools.map { "\($0.key) (\($0.titleText))" }.joined(separator: ", "),
                category: .uniMacHub, level: .reversible, parameters: ["tool": choice(tools.map(\.key))], required: ["tool"]
            ) { arguments, state in
                guard let module = arguments["tool"]?.string.flatMap(Module.named) else { return ActionOutcome(text: "No such tool.", failed: true) }
                state.showMain(module)
                return ActionOutcome(text: "Opened \(module.titleText).")
            })
        list.append(AssistantAction(
                "check_everything", "Runs UniMacHub's full check: junk safe to remove, the Trash and security. Changes nothing.",
                category: .uniMacHub, level: .read
            ) { _, state in
                await state.smartScan.run(state)
                let junk = state.smartScan.safeJunk(state)
                return ActionOutcome(text: "Junk safe to remove: \(size(junk.reduce(0) { $0 + $1.size })) in \(junk.count) items. Trash: \(size(state.trash.totalSize)). Security issues: \(state.security.issues.count). Nothing was removed.")
            })
        list.append(AssistantAction(
                "scan_junk", "Scans one kind of junk and reports how much there is, changing nothing. Kinds: systemJunk (caches, logs), developerJunk (Xcode, package caches), leftovers (of removed apps), privacy (browser traces).",
                category: .uniMacHub, level: .read, parameters: ["kind": choice(["systemJunk", "developerJunk", "leftovers", "privacy"])], required: ["kind"]
            ) { arguments, state in
                guard let store = junkStore(arguments["kind"]?.string ?? "", state) else { return ActionOutcome(text: "No such kind.", failed: true) }
                await store.scan()
                let top = store.categories.sorted { $0.size > $1.size }.prefix(6).map { "\(String(localized: $0.rule.title)) \(size($0.size))" }
                return ActionOutcome(text: "\(size(store.totalSize)) in all; selected as safe: \(size(store.selectedSize)). Largest: \(top.joined(separator: ", ")).")
            })
        list.append(AssistantAction(
                "clean_junk", "Moves the junk UniMacHub selected as safe, of one kind, to the Trash. Scan it first. Can be put back from the log.",
                category: .deleteFiles, level: .important, parameters: ["kind": choice(["systemJunk", "developerJunk", "leftovers", "privacy"])], required: ["kind"],
                question: { arguments in String(localized: "Move the safe \(arguments["kind"]?.string ?? "") junk to the Trash?") }
            ) { arguments, state in
                await cleanJunk(arguments, state)
            })
        list.append(AssistantAction(
                "empty_trash", "Empties the Trash for good. Cannot be undone.",
                category: .deleteFiles, level: .important,
                question: { _ in String(localized: "Empty the Trash for good? This cannot be undone.") }
            ) { _, state in
                await state.trash.scan()
                let total = state.trash.totalSize
                await state.trash.empty()
                return ActionOutcome(text: "Emptied the Trash, \(size(total)).")
            })
        list.append(AssistantAction("app_updates", "Lists apps with updates waiting, from the App Store, Homebrew and the apps themselves.", category: .apps, level: .read) { _, state in
                await state.updater.check()
                let names = state.updater.updates.map { "\($0.name) \($0.installedVersion) → \($0.availableVersion)" }
                return ActionOutcome(text: names.isEmpty ? "Everything is up to date." : names.joined(separator: "; "))
            })
        list.append(AssistantAction(
                "update_apps", "Installs waiting app updates: one by its name, or all when the name is left out.",
                category: .apps, level: .important, parameters: ["app": string("App name; leave out for all")],
                question: { arguments in String(localized: "Update \(arguments["app"]?.string ?? String(localized: "every app with an update"))?") }
            ) { arguments, state in
                if state.updater.updates.isEmpty { await state.updater.check() }
                let wanted = arguments["app"]?.string
                let chosen = state.updater.updates.filter { wanted == nil || $0.name.localizedCaseInsensitiveContains(wanted!) }
                guard !chosen.isEmpty else { return ActionOutcome(text: "No update for that.") }
                for update in chosen { await state.updater.update(update) }
                return ActionOutcome(text: "Updated: " + chosen.map(\.name).joined(separator: ", ") + ".")
            })
        list.append(AssistantAction(
                "uninstall_app", "Uninstalls an app with what it left around the Mac, into the Trash.",
                category: .deleteFiles, level: .important, parameters: ["app": string("The app's name")], required: ["app"],
                question: { arguments in String(localized: "Uninstall \(arguments["app"]?.string ?? "") and its leftovers, into the Trash?") }
            ) { arguments, state in
                if state.uninstaller.apps.isEmpty { await state.uninstaller.load() }
                let name = arguments["app"]?.string ?? ""
                guard let app = state.uninstaller.apps.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
                    ?? state.uninstaller.apps.first(where: { $0.name.localizedCaseInsensitiveContains(name) })
                else { return ActionOutcome(text: "No app called \(name).", failed: true) }
                await state.uninstaller.remove(app, includingApp: true)
                return ActionOutcome(text: "Uninstalled \(app.name); it is in the Trash.")
            })
        list.append(AssistantAction("disk_status", "How full the startup disk is.", category: .uniMacHub, level: .read) { _, _ in
                guard let disk = try? VolumeInfo.forVolume() else { return ActionOutcome(text: "The startup disk could not be read.", failed: true) }
                return ActionOutcome(text: "\(size(disk.availableCapacity)) free of \(size(disk.totalCapacity)).")
            })
        list.append(AssistantAction("system_status", "The processor, memory, temperature and battery right now.", category: .uniMacHub, level: .read) { _, _ in
                let stats = SystemStats()
                _ = await Task.detached { stats.sample() }.value
                try? await Task.sleep(for: .seconds(1))
                let sample = await Task.detached { stats.sample() }.value
                var parts = ["Processor \(Int(sample.cpu * 100))%"]
                if let memory = sample.memory { parts.append("memory \(Int(memory.usedFraction * 100))% used") }
                if let temperature = sample.temperature { parts.append("\(Int(temperature)) °C") }
                if let battery = sample.battery { parts.append("battery \(battery.percent)%\(battery.isCharging ? ", charging" : "")") }
                return ActionOutcome(text: parts.joined(separator: ", ") + ".")
            })
        list.append(AssistantAction(
                "keep_awake", "Keeps the Mac and its display from sleeping, or lets them sleep again.",
                category: .uniMacHub, level: .reversible, parameters: ["on": boolean, "minutes": integer], required: ["on"]
            ) { arguments, _ in
                if arguments["on"]?.bool == false {
                    KeepAwake.shared.stop()
                    return ActionOutcome(text: "The Mac may sleep again.")
                }
                let minutes = arguments["minutes"]?.number.map { Int($0) }
                guard KeepAwake.shared.start(.display, minutes: minutes) else { return ActionOutcome(text: "Could not keep it awake.", failed: true) }
                return ActionOutcome(text: minutes.map { "Staying awake for \($0) minutes." } ?? "Staying awake until told otherwise.") {
                    KeepAwake.shared.stop()
                    return String(localized: "The Mac may sleep again.")
                }
            })
        list.append(AssistantAction(
                "set_volume", "Sets the sound volume from 0 to 100, or mutes and unmutes it.",
                category: .systemSettings, level: .reversible, parameters: ["level": integer, "muted": boolean]
            ) { arguments, _ in
                let before = SystemVolume.volume()
                let wasMuted = SystemVolume.isMuted()
                if let muted = arguments["muted"]?.bool { SystemVolume.setMuted(muted) }
                if let level = arguments["level"]?.number {
                    guard SystemVolume.setVolume(Float(max(0, min(100, level)) / 100)) else { return ActionOutcome(text: "The volume cannot be set for this output.", failed: true) }
                }
                let now = Int(((SystemVolume.volume() ?? 0) * 100).rounded())
                return ActionOutcome(text: SystemVolume.isMuted() ? "Muted." : "Volume is \(now)%.") {
                    if let before { SystemVolume.setVolume(before) }
                    SystemVolume.setMuted(wasMuted)
                    return String(localized: "The volume is back as it was.")
                }
            })
        list.append(AssistantAction(
                "dark_mode", "Turns macOS's dark appearance on or off.",
                category: .systemSettings, level: .reversible, parameters: ["on": boolean], required: ["on"]
            ) { arguments, _ in
                let on = arguments["on"]?.bool ?? true
                let wasDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                guard await setDarkMode(on) else { return ActionOutcome(text: "macOS did not allow changing the appearance (Automation for System Events).", failed: true) }
                return ActionOutcome(text: on ? "Dark mode is on." : "Light mode is on.") {
                    _ = await setDarkMode(wasDark)
                    return String(localized: "The appearance is back as it was.")
                }
            })
        list.append(AssistantAction("lock_screen", "Locks the screen.", category: .systemSettings, level: .reversible) { _, _ in
                await QuickActions.lockScreen()
                return ActionOutcome(text: "Locked.")
            })
        list.append(AssistantAction(
                "switch_dock_profile",
                profiles.isEmpty ? "Switches the Dock to another profile. There are none yet; they are made in Dock & Widgets." : "Switches UniMacHub's Dock to another profile. Profiles: " + profiles.joined(separator: ", "),
                category: .uniMacHub, level: .reversible, parameters: ["profile": choice(profiles)], required: ["profile"]
            ) { arguments, state in
                let name = arguments["profile"]?.string ?? ""
                guard let profile = state.dock.profiles.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
                else { return ActionOutcome(text: "There is no Dock profile called \(name).", failed: true) }
                let before = state.dock.activeProfile
                state.dock.switchProfile(to: profile.id)
                return ActionOutcome(text: "The Dock is on \(profile.name) now.") {
                    if let before { state.dock.switchProfile(to: before) }
                    return String(localized: "The Dock is back on its earlier profile.")
                }
            })
        list.append(AssistantAction("flush_dns", "Clears macOS's DNS cache, which helps when sites do not open after a change.", category: .admin, level: .admin) { _, state in
                await state.dns.flushCache()
                return ActionOutcome(text: "Cleared the DNS cache.")
            })
        list.append(AssistantAction(
            "remember", "Writes down something the person asks you to remember, kept across conversations and always shown to you. With minutes or at, it is a reminder: a notification, and said aloud, at that time.",
            category: .uniMacHub, level: .reversible,
            parameters: [
                "text": string(),
                "minutes": .object(["type": .string("number"), "description": .string("Remind in this many minutes")]),
                "at": string("Remind at a time: HH:mm, or yyyy-MM-dd HH:mm, in the person's time zone"),
            ],
            required: ["text"]
        ) { arguments, state in
            let text = arguments["text"]?.string ?? ""
            guard !text.isEmpty else { return ActionOutcome(text: "Nothing to remember.", failed: true) }
            let due = AssistantContext.due(minutes: arguments["minutes"]?.number, at: arguments["at"]?.string)
            if arguments["at"]?.string != nil || arguments["minutes"]?.number != nil, due == nil {
                return ActionOutcome(text: "That time could not be read; use HH:mm or yyyy-MM-dd HH:mm.", failed: true)
            }
            let note = state.assistant.remember(text, due: due)
            let said = due.map { "Will remind at \($0.formatted(date: .abbreviated, time: .shortened))." } ?? "Noted."
            return ActionOutcome(text: said) {
                state.assistant.forget(note.id)
                return String(localized: "Forgot it again.")
            }
        })
        list.append(AssistantAction(
            "forget", "Removes notes or reminders whose text contains these words; all of them with everything set to true.",
            category: .uniMacHub, level: .reversible, parameters: ["words": string(), "everything": boolean]
        ) { arguments, state in
            let gone: [AssistantContext.Note]
            if arguments["everything"]?.bool == true {
                gone = state.assistant.notes
            } else {
                let words = arguments["words"]?.string ?? ""
                gone = state.assistant.notes.filter { !words.isEmpty && $0.text.localizedCaseInsensitiveContains(words) }
            }
            guard !gone.isEmpty else { return ActionOutcome(text: "No such note.", failed: true) }
            gone.forEach { state.assistant.forget($0.id) }
            return ActionOutcome(text: "Forgot \(gone.count).") {
                for note in gone { state.assistant.remember(note.text, due: note.due.flatMap { $0 > Date() ? $0 : nil }) }
                return String(localized: "The notes are back.")
            }
        })
        list.append(AssistantAction("clipboard_history", "The last things copied, from UniMacHub's clipboard history, newest first.", category: .uniMacHub, level: .read) { _, _ in
                let entries = ClipboardHistory.load().prefix(10).map(\.preview)
                return ActionOutcome(text: entries.isEmpty ? "The history is empty or switched off." : entries.joined(separator: "\n"))
            })
        return list
    }

    private static func cleanJunk(_ arguments: JSONValue, _ state: AppState) async -> ActionOutcome {
        guard let store = junkStore(arguments["kind"]?.string ?? "", state) else { return ActionOutcome(text: "No such kind.", failed: true) }
        if store.categories.isEmpty { await store.scan() }
        let targets = store.selectedItems.map { CleanupTarget(path: $0.path, size: $0.size) }
        guard !targets.isEmpty else { return ActionOutcome(text: "Nothing selected to clean.") }
        let result = await Cleaner().clean(targets, mode: .trash, source: "assistant")
        await store.scan()
        var outcome = ActionOutcome(text: "Moved \(result.removed.count) items, \(size(result.freedBytes)), to the Trash.")
        if !result.failures.isEmpty { outcome.text += " \(result.failures.count) could not be moved." }
        if result.canUndo {
            outcome.undo = { @MainActor in
                _ = await Cleaner().undo(result)
                await store.scan()
                return String(localized: "Put the junk back from the Trash.")
            }
        }
        return outcome
    }

    private static func setDarkMode(_ on: Bool) async -> Bool {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)"
        let output = await Command.run("/usr/bin/osascript", ["-e", script])
        return output?.status == 0
    }

    // MARK: - Apps

    static func runningApp(named name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { $0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame }
            ?? apps.first { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }
    }

    static var apps: [AssistantAction] { [
        AssistantAction(
            "open_link", "Opens a web address in the person's browser, or a mail address in Mail.",
            category: .apps, level: .reversible, parameters: ["url": string()], required: ["url"]
        ) { arguments, _ in
            var text = (arguments["url"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            if !text.contains("://"), !text.hasPrefix("mailto:") { text = "https://" + text }
            guard let url = URL(string: text), ["http", "https", "mailto"].contains(url.scheme ?? "") else {
                return ActionOutcome(text: "Not a web or mail address.", failed: true)
            }
            NSWorkspace.shared.open(url)
            return ActionOutcome(text: "Opened \(url.host() ?? text).")
        },
        AssistantAction(
            "search_in_browser", "Opens a web search for something in the person's browser, for them to look at.",
            category: .apps, level: .reversible, parameters: ["query": string()], required: ["query"]
        ) { arguments, _ in
            var parts = URLComponents(string: "https://www.google.com/search")
            parts?.queryItems = [URLQueryItem(name: "q", value: arguments["query"]?.string ?? "")]
            guard let url = parts?.url else { return ActionOutcome(text: "No query.", failed: true) }
            NSWorkspace.shared.open(url)
            return ActionOutcome(text: "Opened the search.")
        },
        AssistantAction(
            "open_file", "Opens a file in its usual app, or a folder in Finder.",
            category: .apps, level: .reversible, parameters: ["path": string()], required: ["path"],
            paths: { [path($0["path"])] }
        ) { arguments, _ in
            let file = path(arguments["path"])
            guard FileManager.default.fileExists(atPath: file) else { return ActionOutcome(text: "\(file) is not there.", failed: true) }
            NSWorkspace.shared.open(URL(filePath: file))
            return ActionOutcome(text: "Opened \(file).")
        },
        AssistantAction("running_apps", "The apps open right now.", category: .apps, level: .read) { _, _ in
            let names = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
            return ActionOutcome(text: names.joined(separator: ", "))
        },
        AssistantAction(
            "open_app", "Opens an app by its name, or brings it forward.",
            category: .apps, level: .reversible, parameters: ["app": string()], required: ["app"]
        ) { arguments, _ in
            let name = arguments["app"]?.string ?? ""
            let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
                ?? ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
                .lazy.map { URL(filePath: "\($0)/\(name).app") }.first { FileManager.default.fileExists(atPath: $0.path) }
            guard let url = found else {
                // Spotlight knows apps by their displayed names too.
                let output = await Command.run("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle' && kMDItemDisplayName == '\(name.replacingOccurrences(of: "'", with: ""))*'cd"])
                guard let path = output?.text.split(separator: "\n").first else { return ActionOutcome(text: "No app called \(name).", failed: true) }
                _ = try? await NSWorkspace.shared.openApplication(at: URL(filePath: String(path)), configuration: .init())
                return ActionOutcome(text: "Opened \(name).")
            }
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return ActionOutcome(text: "Opened \(name).")
        },
        AssistantAction(
            "quit_app", "Quits an app. It may ask to save. With force, it is ended at once and unsaved work is lost.",
            category: .apps, level: .reversible, parameters: ["app": string(), "force": boolean], required: ["app"],
            levelFor: { $0["force"]?.bool == true ? .important : .reversible },
            question: { arguments in String(localized: "Force \(arguments["app"]?.string ?? "") to quit? Unsaved work is lost.") }
        ) { arguments, _ in
            let name = arguments["app"]?.string ?? ""
            guard let app = runningApp(named: name) else { return ActionOutcome(text: "\(name) is not open.", failed: true) }
            _ = arguments["force"]?.bool == true ? app.forceTerminate() : app.terminate()
            return ActionOutcome(text: "Asked \(app.localizedName ?? name) to quit.")
        },
    ] }

    // MARK: - Files

    static var files: [AssistantAction] { [
        AssistantAction(
            "search_files", "Finds files by name or content with Spotlight, optionally inside one folder.",
            category: .readFiles, level: .read, parameters: ["query": string(), "folder": string("Optional folder")], required: ["query"],
            paths: { [path($0["folder"])].filter { !$0.isEmpty } }
        ) { arguments, _ in
            var options = [arguments["query"]?.string ?? ""]
            if let folder = arguments["folder"]?.string { options = ["-onlyin", path(.string(folder))] + options }
            let output = await Command.run("/usr/bin/mdfind", options, timeout: .seconds(20))
            let found = (output?.text ?? "").split(separator: "\n").prefix(30)
            return ActionOutcome(text: found.isEmpty ? "Nothing found." : found.joined(separator: "\n"))
        },
        AssistantAction(
            "list_folder", "Lists what is in a folder.", category: .readFiles, level: .read,
            parameters: ["path": string()], required: ["path"], paths: { [path($0["path"])] }
        ) { arguments, _ in
            let folder = path(arguments["path"])
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return ActionOutcome(text: "Cannot read \(folder).", failed: true) }
            return ActionOutcome(text: names.filter { !$0.hasPrefix(".") }.sorted().prefix(200).joined(separator: "\n"))
        },
        AssistantAction(
            "read_file", "Reads a text file.", category: .readFiles, level: .read,
            parameters: ["path": string()], required: ["path"], paths: { [path($0["path"])] }
        ) { arguments, _ in
            let file = path(arguments["path"])
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return ActionOutcome(text: "Cannot read \(file) as text.", failed: true) }
            return ActionOutcome(text: text.count > 20000 ? String(text.prefix(20000)) + "…" : text)
        },
        AssistantAction(
            "write_file", "Writes text to a file, making it or replacing what is in it.",
            category: .changeFiles, level: .reversible, parameters: ["path": string(), "text": string()], required: ["path", "text"],
            levelFor: { FileManager.default.fileExists(atPath: path($0["path"])) ? .important : .reversible },
            paths: { [path($0["path"])] },
            question: { arguments in String(localized: "Replace what is in \(path(arguments["path"]))?") }
        ) { arguments, _ in
            let file = path(arguments["path"])
            let before = try? Data(contentsOf: URL(filePath: file))
            do {
                try (arguments["text"]?.string ?? "").write(toFile: file, atomically: true, encoding: .utf8)
            } catch {
                return ActionOutcome(text: error.localizedDescription, failed: true)
            }
            return ActionOutcome(text: "Wrote \(file).") {
                if let before { try? before.write(to: URL(filePath: file)) } else { try? FileManager.default.trashItem(at: URL(filePath: file), resultingItemURL: nil) }
                return String(localized: "\(file) is back as it was.")
            }
        },
        AssistantAction(
            "move_file", "Moves or renames a file or folder.", category: .changeFiles, level: .reversible,
            parameters: ["from": string(), "to": string()], required: ["from", "to"],
            levelFor: { FileManager.default.fileExists(atPath: path($0["to"])) ? .important : .reversible },
            paths: { [path($0["from"]), path($0["to"])] }
        ) { arguments, _ in
            let from = path(arguments["from"]), to = path(arguments["to"])
            guard !FileManager.default.fileExists(atPath: to) else { return ActionOutcome(text: "\(to) is already there; nothing was moved.", failed: true) }
            do {
                try FileManager.default.moveItem(atPath: from, toPath: to)
            } catch {
                return ActionOutcome(text: error.localizedDescription, failed: true)
            }
            return ActionOutcome(text: "Moved to \(to).") {
                try? FileManager.default.moveItem(atPath: to, toPath: from)
                return String(localized: "Moved back to \(from).")
            }
        },
        AssistantAction(
            "trash_file", "Moves a file or folder to the Trash.", category: .deleteFiles, level: .important,
            parameters: ["path": string()], required: ["path"], paths: { [path($0["path"])] },
            question: { arguments in String(localized: "Move \(path(arguments["path"])) to the Trash?") }
        ) { arguments, _ in
            let file = path(arguments["path"])
            var moved: NSURL?
            do {
                try FileManager.default.trashItem(at: URL(filePath: file), resultingItemURL: &moved)
            } catch {
                return ActionOutcome(text: error.localizedDescription, failed: true)
            }
            let inTrash = moved as URL?
            var undo: (@MainActor () async -> String)?
            if let trashed = inTrash {
                undo = { @MainActor in
                    try? FileManager.default.moveItem(at: trashed, to: URL(filePath: file))
                    return String(localized: "Put \(file) back.")
                }
            }
            return ActionOutcome(text: "Moved \(file) to the Trash.", undo: undo)
        },
    ] }

    // MARK: - Terminal

    static var terminal: [AssistantAction] { [
        AssistantAction(
            "run_command", "Runs a shell command in zsh and returns what it printed. Commands that change things wait for the person's yes; sudo asks for the administrator's password through macOS.",
            category: .terminal, level: .important, parameters: ["command": string()], required: ["command"],
            levelFor: { ShellRisk.level(of: $0["command"]?.string ?? "") },
            command: { $0["command"]?.string },
            question: { arguments in String(localized: "Run this command?\n\(arguments["command"]?.string ?? "")") }
        ) { arguments, _ in
            let command = arguments["command"]?.string ?? ""
            if ShellRisk.level(of: command) == .admin {
                let plain = command.replacingOccurrences(of: #"(^|[\s;&|(])sudo\s+"#, with: "$1", options: .regularExpression)
                let output = await AdminRunner.run([plain], prompt: String(localized: "UniMacHub's assistant wants to run a command as an administrator."))
                return ActionOutcome(text: output.wasCancelled ? "The person cancelled the password." : String(output.text.suffix(8000)), failed: !output.succeeded)
            }
            let output = await Command.run("/bin/zsh", ["-lc", command], timeout: .seconds(120))
            guard let output else { return ActionOutcome(text: "The command did not run.", failed: true) }
            let text = output.text.isEmpty ? "(no output)" : String(output.text.suffix(8000))
            return ActionOutcome(text: "Exit \(output.status). \(text)", failed: output.status != 0)
        },
    ] }

    // MARK: - Internet

    static var internet: [AssistantAction] { [
        AssistantAction(
            "web_search", "Searches the web and returns titles, addresses and snippets.", category: .internet, level: .read,
            parameters: ["query": string()], required: ["query"]
        ) { arguments, _ in
            guard let url = WebText.searchURL(arguments["query"]?.string ?? "") else { return ActionOutcome(text: "No query.", failed: true) }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("Mozilla/5.0 (Macintosh) UniMacHub", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request), let html = String(data: data, encoding: .utf8)
            else { return ActionOutcome(text: "The search did not answer.", failed: true) }
            let results = WebText.results(fromDuckDuckGo: html)
            return ActionOutcome(text: results.isEmpty ? "No results." : results.map { "\($0.title)\n\($0.url)\n\($0.snippet)" }.joined(separator: "\n\n"))
        },
        AssistantAction(
            "fetch_page", "Reads a web page as plain text.", category: .internet, level: .read,
            parameters: ["url": string()], required: ["url"]
        ) { arguments, _ in
            guard let url = URL(string: arguments["url"]?.string ?? ""), url.scheme == "https" || url.scheme == "http" else {
                return ActionOutcome(text: "Not a web address.", failed: true)
            }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("Mozilla/5.0 (Macintosh) UniMacHub", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { return ActionOutcome(text: "The page did not load.", failed: true) }
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return ActionOutcome(text: WebText.text(fromHTML: html))
        },
        AssistantAction(
            "download_file", "Downloads a file into Downloads.", category: .internet, level: .reversible,
            parameters: ["url": string()], required: ["url"]
        ) { arguments, _ in
            guard let url = URL(string: arguments["url"]?.string ?? ""), url.scheme == "https" || url.scheme == "http" else {
                return ActionOutcome(text: "Not a web address.", failed: true)
            }
            guard let (temporary, _) = try? await URLSession.shared.download(from: url) else { return ActionOutcome(text: "The download failed.", failed: true) }
            let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
            var target = folder.appending(path: url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
            var number = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appending(path: "\(number) " + url.lastPathComponent)
                number += 1
            }
            do { try FileManager.default.moveItem(at: temporary, to: target) } catch { return ActionOutcome(text: error.localizedDescription, failed: true) }
            let saved = target
            return ActionOutcome(text: "Saved \(saved.path).") {
                try? FileManager.default.trashItem(at: saved, resultingItemURL: nil)
                return String(localized: "The download is in the Trash.")
            }
        },
    ] }

    // MARK: - The screen

    /// Screenshot pixels per screen point, from the last screenshot, to turn clicks back.
    nonisolated(unsafe) static var screenshotScale: CGFloat = 1

    static var screen: [AssistantAction] { [
        AssistantAction(
            "screenshot", "Takes a picture of the main screen, to see what is on it. Click coordinates are in this picture's pixels.",
            category: .screen, level: .read
        ) { _, _ in
            guard let (image, scale) = await ScreenControl.screenshot() else {
                return ActionOutcome(text: "No screenshot: UniMacHub needs Screen Recording (System Settings → Privacy & Security).", failed: true)
            }
            screenshotScale = scale
            return ActionOutcome(text: "The screen, \(Int(image.width)) × \(Int(image.height)) pixels.", image: image.jpeg)
        },
        AssistantAction(
            "click", "Clicks at a point of the last screenshot.", category: .screen, level: .reversible,
            parameters: ["x": integer, "y": integer, "double": boolean, "right": boolean], required: ["x", "y"]
        ) { arguments, _ in
            guard ScreenControl.canControl else { return ScreenControl.needsAccessibility }
            let point = CGPoint(x: (arguments["x"]?.number ?? 0) / screenshotScale, y: (arguments["y"]?.number ?? 0) / screenshotScale)
            ScreenControl.click(at: point, right: arguments["right"]?.bool == true, double: arguments["double"]?.bool == true)
            return ActionOutcome(text: "Clicked.")
        },
        AssistantAction(
            "type_text", "Types text where the cursor is.", category: .screen, level: .reversible,
            parameters: ["text": string()], required: ["text"]
        ) { arguments, _ in
            guard ScreenControl.canControl else { return ScreenControl.needsAccessibility }
            ScreenControl.type(arguments["text"]?.string ?? "")
            return ActionOutcome(text: "Typed.")
        },
        AssistantAction(
            "press_keys", "Presses a key with modifiers, such as return, escape, tab, space, delete, up, down, left, right or a letter, with command, shift, option, control.",
            category: .screen, level: .reversible,
            parameters: ["key": string(), "modifiers": .object(["type": .string("array"), "items": .object(["type": .string("string")])])], required: ["key"]
        ) { arguments, _ in
            guard ScreenControl.canControl else { return ScreenControl.needsAccessibility }
            let modifiers = arguments["modifiers"]?.array?.compactMap(\.string) ?? []
            guard ScreenControl.press(arguments["key"]?.string ?? "", modifiers: modifiers) else { return ActionOutcome(text: "Unknown key.", failed: true) }
            return ActionOutcome(text: "Pressed.")
        },
        AssistantAction(
            "scroll", "Scrolls where the pointer is: positive down, negative up, in lines.", category: .screen, level: .reversible,
            parameters: ["lines": integer], required: ["lines"]
        ) { arguments, _ in
            guard ScreenControl.canControl else { return ScreenControl.needsAccessibility }
            ScreenControl.scroll(lines: Int(arguments["lines"]?.number ?? 3))
            return ActionOutcome(text: "Scrolled.")
        },
    ] }
}

extension AssistantPolicy {
    /// The categories the basic mode leaves out, for listing actions.
    static var outsideBasicForUI: Set<ActionCategory> { [.terminal, .internet, .screen, .messages] }
}

/// The mouse and keyboard, for the assistant's control of the screen.
@MainActor
enum ScreenControl {
    static var canControl: Bool {
        if AXIsProcessTrusted() { return true }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        return false
    }

    static var needsAccessibility: ActionOutcome {
        ActionOutcome(text: "UniMacHub needs Accessibility to use the mouse and keyboard (System Settings → Privacy & Security → Accessibility).", failed: true)
    }

    struct Shot {
        let width: CGFloat
        let height: CGFloat
        let jpeg: Data
    }

    /// The main screen, at most 1440 pixels wide, as JPEG; and pixels per point.
    static func screenshot() async -> (Shot, CGFloat)? {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { return nil }
        let scale = min(1, 1440 / CGFloat(display.width))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.showsCursor = true
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration
        ) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        return (Shot(width: CGFloat(image.width), height: CGFloat(image.height), jpeg: jpeg), scale)
    }

    static func click(at point: CGPoint, right: Bool, double: Bool) {
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = right ? .right : .left
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        for count in 1 ... (double ? 2 : 1) {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    static func type(_ text: String) {
        for chunk in text.chunked(20) {
            let characters = Array(chunk.utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    @discardableResult
    static func press(_ key: String, modifiers: [String]) -> Bool {
        guard let code = keyCodes[key.lowercased()] else { return false }
        var flags: CGEventFlags = []
        for modifier in modifiers.map({ $0.lowercased() }) {
            switch modifier {
            case "command", "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            default: break
            }
        }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        return true
    }

    static func scroll(lines: Int) {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(-lines), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }
}

private extension String {
    func chunked(_ size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for character in self {
            current.append(character)
            if current.count == size {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
