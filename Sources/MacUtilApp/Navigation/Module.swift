import SwiftUI

enum SidebarSection: CaseIterable, Identifiable {
    case overview, cleanup, storage, applications, files, system, network, security

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Cleanup"
        case .storage: "Storage"
        case .applications: "Applications"
        case .files: "Files"
        case .system: "System"
        case .network: "Network"
        case .security: "Security"
        }
    }

    /// A word for the whole section, shown under its name while it is open.
    var summary: LocalizedStringKey {
        switch self {
        case .overview: "What your Mac looks like right now."
        case .cleanup: "What can go, and why it is safe to let it."
        case .storage: "Where the space went, and how to get it back."
        case .applications: "What is installed, and what it left behind."
        case .files: "Finding things, and keeping them in order."
        case .system: "How macOS behaves, and what runs inside it."
        case .network: "What this Mac is connected through."
        case .security: "What is running, signed and allowed."
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cleanup: "sparkles"
        case .storage: "internaldrive"
        case .applications: "app.badge"
        case .files: "folder"
        case .system: "gearshape.2"
        case .network: "network"
        case .security: "lock.shield"
        }
    }

    /// The tools of this section. The hub is not one of them: it is where you already are.
    var modules: [Module] {
        Module.allCases.filter { $0.section == self && $0 != .hub }
    }
}

enum Module: CaseIterable, Identifiable, Hashable {
    case hub, smartScan, dashboard, history, clipboard, settings
    case systemJunk, developerJunk, projectBuilds, messengers, installers, trash, privacy
    case spaceLens, largeFiles, duplicates, disks, fileRecovery
    case uninstaller, leftovers, updater, slimming, addOns
    case folderOrganizer, deepSearch
    case taskManager, loginItems, maintenance, hiddenSettings, terminal
    case vault
    case networkAdapters, dns
    case securityAnalyzer

    // Planned, listed so the shape of the app is honest about where it is going.
    case menuBarTidy, windowTiling, audioSwitch, displayControl, batteryCare
    case dockWidgets, batchRename, terminalThemes
    case networkControl, linkAggregation
    case firewall, permissions
    case island, assistant, timeMachine, iCloudSync, converter, lanScan, appConnections

    var id: Self { self }

    /// A stable name to store a choice under. The case names are the app's own and do not
    /// change when a title is reworded or translated.
    var key: String { String(describing: self) }

    static func named(_ key: String) -> Module? {
        allCases.first { $0.key == key }
    }

    /// Not built yet: shown with a mark, and opening one explains what it will do.
    var isPlanned: Bool {
        switch self {
        case .menuBarTidy, .windowTiling, .audioSwitch, .displayControl, .batteryCare,
             .dockWidgets, .batchRename, .terminalThemes, .networkControl, .linkAggregation,
             .firewall, .permissions,
             .island, .assistant, .timeMachine, .iCloudSync, .converter, .lanScan, .appConnections:
            true
        default:
            false
        }
    }

    /// Tools whose answer would be wrong, not merely shorter, without Full Disk Access.
    ///
    /// Each of these reads the libraries, containers or Trash that macOS hides from an app
    /// it has not been told to trust. A scan there without access does not fail — it comes
    /// back small and looks finished, which is worse — so they are locked until it is given.
    var needsFullDiskAccess: Bool {
        switch self {
        case .smartScan, .systemJunk, .messengers, .trash, .privacy,
             .spaceLens, .largeFiles, .duplicates,
             .uninstaller, .leftovers, .deepSearch:
            true
        default:
            false
        }
    }

    var section: SidebarSection {
        switch self {
        case .hub, .smartScan, .dashboard, .history, .clipboard, .settings, .island, .assistant: .overview
        case .systemJunk, .developerJunk, .projectBuilds, .messengers, .installers, .trash, .privacy: .cleanup
        case .spaceLens, .largeFiles, .duplicates, .disks, .fileRecovery, .vault, .timeMachine, .iCloudSync: .storage
        case .uninstaller, .leftovers, .updater, .slimming, .addOns, .dockWidgets: .applications
        case .folderOrganizer, .deepSearch, .batchRename, .converter: .files
        case .taskManager, .loginItems, .maintenance, .hiddenSettings, .terminal,
             .terminalThemes, .menuBarTidy, .windowTiling, .audioSwitch, .displayControl, .batteryCare:
            .system
        case .networkAdapters, .dns, .networkControl, .linkAggregation, .lanScan, .appConnections: .network
        case .securityAnalyzer, .firewall, .permissions: .security
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .hub: "Hub"
        case .smartScan: "Check Everything"
        case .settings: "Settings"
        case .dashboard: "Dashboard"
        case .history: "History"
        case .clipboard: "Clipboard History"
        case .systemJunk: "System Junk"
        case .developerJunk: "Developer Junk"
        case .trash: "Trash Bins"
        case .privacy: "Privacy"
        case .messengers: "Messenger Downloads"
        case .installers: "Installer Files"
        case .projectBuilds: "Project Build Files"
        case .spaceLens: "Space Lens"
        case .largeFiles: "Large & Old Files"
        case .duplicates: "Duplicates"
        case .disks: "Disk Utilities"
        case .folderOrganizer: "Keep Folders Tidy"
        case .fileRecovery: "File Recovery"
        case .deepSearch: "Deep Search"
        case .uninstaller: "Uninstaller"
        case .leftovers: "Leftovers"
        case .updater: "Updater"
        case .slimming: "Slim Down Apps"
        case .networkAdapters: "Network Adapters"
        case .securityAnalyzer: "Security Analyzer"
        case .loginItems: "Login Items"
        case .maintenance: "Maintenance"
        case .taskManager: "Task Manager"
        case .hiddenSettings: "Hidden Settings"
        case .terminal: "Terminal"
        case .addOns: "System Add-ons"
        case .menuBarTidy: "Menu Bar"
        case .windowTiling: "Window Layouts"
        case .audioSwitch: "Sound Output"
        case .displayControl: "Displays"
        case .batteryCare: "Battery"
        case .dockWidgets: "Dock & Widgets"
        case .batchRename: "Rename in Bulk"
        case .terminalThemes: "Terminal Themes"
        case .networkControl: "Network Settings"
        case .linkAggregation: "Combine Connections"
        case .firewall: "Firewall"
        case .permissions: "App Permissions"
        case .vault: "Vault"
        case .dns: "DNS & Domains"
        case .island: "Dynamic Island"
        case .assistant: "Assistant"
        case .timeMachine: "Time Machine"
        case .iCloudSync: "iCloud Sync"
        case .converter: "Convert Files"
        case .lanScan: "Who's on the Network"
        case .appConnections: "App Connections"
        }
    }

    /// The title as text, for searching. Beside the one above on purpose: the compiler
    /// reads translations out of that switch and cannot read them out of a String.
    var titleText: String {
        switch self {
        case .hub: String(localized: "Hub")
        case .smartScan: String(localized: "Check Everything")
        case .settings: String(localized: "Settings")
        case .dashboard: String(localized: "Dashboard")
        case .history: String(localized: "History")
        case .clipboard: String(localized: "Clipboard History")
        case .systemJunk: String(localized: "System Junk")
        case .developerJunk: String(localized: "Developer Junk")
        case .trash: String(localized: "Trash Bins")
        case .privacy: String(localized: "Privacy")
        case .messengers: String(localized: "Messenger Downloads")
        case .installers: String(localized: "Installer Files")
        case .projectBuilds: String(localized: "Project Build Files")
        case .spaceLens: String(localized: "Space Lens")
        case .largeFiles: String(localized: "Large & Old Files")
        case .duplicates: String(localized: "Duplicates")
        case .disks: String(localized: "Disk Utilities")
        case .folderOrganizer: String(localized: "Keep Folders Tidy")
        case .fileRecovery: String(localized: "File Recovery")
        case .deepSearch: String(localized: "Deep Search")
        case .uninstaller: String(localized: "Uninstaller")
        case .leftovers: String(localized: "Leftovers")
        case .updater: String(localized: "Updater")
        case .slimming: String(localized: "Slim Down Apps")
        case .networkAdapters: String(localized: "Network Adapters")
        case .securityAnalyzer: String(localized: "Security Analyzer")
        case .loginItems: String(localized: "Login Items")
        case .maintenance: String(localized: "Maintenance")
        case .taskManager: String(localized: "Task Manager")
        case .hiddenSettings: String(localized: "Hidden Settings")
        case .terminal: String(localized: "Terminal")
        case .addOns: String(localized: "System Add-ons")
        case .menuBarTidy: String(localized: "Menu Bar")
        case .windowTiling: String(localized: "Window Layouts")
        case .audioSwitch: String(localized: "Sound Output")
        case .displayControl: String(localized: "Displays")
        case .batteryCare: String(localized: "Battery")
        case .dockWidgets: String(localized: "Dock & Widgets")
        case .batchRename: String(localized: "Rename in Bulk")
        case .terminalThemes: String(localized: "Terminal Themes")
        case .networkControl: String(localized: "Network Settings")
        case .linkAggregation: String(localized: "Combine Connections")
        case .firewall: String(localized: "Firewall")
        case .permissions: String(localized: "App Permissions")
        case .vault: String(localized: "Vault")
        case .dns: String(localized: "DNS & Domains")
        case .island: String(localized: "Dynamic Island")
        case .assistant: String(localized: "Assistant")
        case .timeMachine: String(localized: "Time Machine")
        case .iCloudSync: String(localized: "iCloud Sync")
        case .converter: String(localized: "Convert Files")
        case .lanScan: String(localized: "Who's on the Network")
        case .appConnections: String(localized: "App Connections")
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .hub: "Everything this Mac can be told, in one ring."
        case .smartScan: "One pass over the whole Mac, and what to do about what it finds."
        case .settings: "Language, the menu bar, colours, and what is kept."
        case .dashboard: "Clean, optimize and protect your Mac."
        case .history: "Everything UniMacHub has removed, with dates, sizes and paths."
        case .clipboard: "The last hundred things you copied, instead of only the last one."
        case .systemJunk: "Caches, logs, crash reports and other system leftovers."
        case .developerJunk: "Xcode data, package manager caches, Docker and old node_modules."
        case .trash: "Empty the Trash on all connected drives."
        case .privacy: "Browser history, cookies and recent items."
        case .messengers: "What Telegram, WhatsApp and the others downloaded and kept."
        case .installers: "Disk images and packages left over after installing apps."
        case .projectBuilds: "Dependencies and build output inside your project folders."
        case .spaceLens: "An interactive map of what takes up your disk."
        case .largeFiles: "Find big and long-unused files."
        case .duplicates: "Find identical files and free up space."
        case .disks: "Disks, volumes, partitions, first aid, disk images and speed tests."
        case .folderOrganizer: "Rules that file what lands in a folder, previewed before anything moves."
        case .fileRecovery: "Bring back deleted files from the Trash, a snapshot, a backup or the disk itself."
        case .deepSearch: "Search everywhere by name, size, date or contents, including hidden files."
        case .uninstaller: "Remove apps together with all their leftovers."
        case .leftovers: "Files left behind by apps that are already deleted."
        case .updater: "Check your apps for updates."
        case .slimming: "Remove the machine code your Mac never runs."
        case .networkAdapters: "Every network interface, what it carries and which one macOS uses."
        case .securityAnalyzer: "Signatures, permissions, security settings and VirusTotal checks."
        case .loginItems: "Everything that starts with your Mac."
        case .maintenance: "Rebuild caches and indexes, flush DNS, verify the disk."
        case .taskManager: "Everything running now, with what it costs and what you can do about it."
        case .hiddenSettings: "macOS settings that are not in System Settings."
        case .terminal: "Settings zsh, Git and ssh already have, in words and switchable."
        case .addOns: "Extensions, plug-ins, software needing Rosetta and files iCloud already holds."
        case .menuBarTidy: "Hide the icons you do not need, and reach them when you do."
        case .windowTiling: "Put windows side by side with the keyboard."
        case .audioSwitch: "Change output and per-app volume without opening Settings."
        case .displayControl: "Brightness and resolution, including on external screens."
        case .batteryCare: "Health, cycles, and holding the charge where it wears least."
        case .dockWidgets: "A Dock of your own, with the apps you choose as live widgets."
        case .batchRename: "Rename many files at once, by a rule you can see first."
        case .terminalThemes: "Colours for Terminal, built to be read for hours."
        case .networkControl: "The order macOS tries adapters in, and what is switched on."
        case .linkAggregation: "Use Wi-Fi and Ethernet at once, adding up their speed."
        case .firewall: "What is allowed to listen, and what is reaching out."
        case .permissions: "Which apps hold which permissions, in one list."
        case .vault: "Encrypted folders in a single file, opened with a password."
        case .dns: "DNS servers, encrypted DNS, development domains and temporary hosts entries."
        case .island: "Music, progress and what needs you, around the notch."
        case .assistant: "Ask by voice or text, in Ukrainian or English, and it acts on this Mac."
        case .timeMachine: "Whether backups are really happening, and any file back from them."
        case .iCloudSync: "What iCloud is uploading and downloading, and what is stuck."
        case .converter: "Drop a file and choose what it should become."
        case .lanScan: "Devices on your network and the services they offer."
        case .appConnections: "Which app is talking to which server, right now."
        }
    }

    var symbol: String {
        switch self {
        case .hub: "circle.hexagongrid"
        case .smartScan: "wand.and.sparkles"
        case .settings: "gearshape"
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .history: "list.bullet.rectangle.portrait"
        case .clipboard: "doc.on.clipboard"
        case .systemJunk: "sparkles"
        case .developerJunk: "hammer"
        case .trash: "trash"
        case .privacy: "hand.raised"
        case .messengers: "bubble.left.and.bubble.right"
        case .installers: "shippingbox.and.arrow.backward"
        case .projectBuilds: "shippingbox"
        case .spaceLens: "chart.pie"
        case .largeFiles: "doc.badge.clock"
        case .duplicates: "doc.on.doc"
        case .disks: "internaldrive"
        case .folderOrganizer: "folder.badge.gearshape"
        case .fileRecovery: "clock.arrow.circlepath"
        case .deepSearch: "magnifyingglass"
        case .uninstaller: "trash.square"
        case .leftovers: "shippingbox"
        case .updater: "arrow.down.app"
        case .slimming: "arrow.down.right.and.arrow.up.left"
        case .networkAdapters: "network"
        case .securityAnalyzer: "checkmark.shield"
        case .loginItems: "power"
        case .maintenance: "wrench.and.screwdriver"
        case .taskManager: "cpu"
        case .hiddenSettings: "slider.horizontal.3"
        case .terminal: "terminal"
        case .addOns: "puzzlepiece.extension"
        case .menuBarTidy: "menubar.rectangle"
        case .windowTiling: "rectangle.split.2x1"
        case .audioSwitch: "speaker.wave.2"
        case .displayControl: "display"
        case .batteryCare: "battery.100percent"
        case .dockWidgets: "squares.below.rectangle"
        case .batchRename: "character.cursor.ibeam"
        case .terminalThemes: "paintpalette"
        case .networkControl: "dot.radiowaves.left.and.right"
        case .linkAggregation: "arrow.triangle.merge"
        case .firewall: "flame"
        case .permissions: "hand.raised.square"
        case .vault: "lock.rectangle.stack"
        case .dns: "globe"
        case .island: "rectangle.topthird.inset.filled"
        case .assistant: "waveform.circle"
        case .timeMachine: "clock.arrow.2.circlepath"
        case .iCloudSync: "icloud.and.arrow.up"
        case .converter: "arrow.triangle.2.circlepath"
        case .lanScan: "wifi.router"
        case .appConnections: "point.3.connected.trianglepath.dotted"
        }
    }

    /// The one thing worth knowing before using a tool, said once on the first visit.
    /// Nil where the summary already says everything there is to say.
    var firstVisitNote: LocalizedStringKey? {
        switch self {
        case .systemJunk, .developerJunk, .privacy:
            "Everything found is listed before anything goes. What is safe to lose is ticked already; the rest is left for you to look at."
        case .projectBuilds:
            "A folder called build or dist is made by a tool in one project and written by hand in another, so those are never ticked for you."
        case .uninstaller:
            "Each leftover says why it was matched. An app Homebrew installed is removed by Homebrew, which is the only way its records stay true."
        case .slimming:
            "This cannot be undone without reinstalling, and an update brings the removed half back. Leave out anything you open with Rosetta."
        case .fileRecovery:
            "Recovery works on external media. The internal disk discards deleted blocks as it goes, so there is nothing left there to find."
        case .disks:
            "The disk macOS is running from is never offered for anything destructive, whatever is selected."
        case .folderOrganizer:
            "Nothing moves until the whole plan is on screen, and a sort can be put back in one press."
        case .terminal:
            "Everything written goes between two marked lines in your own files. Turning a setting off takes its lines back out and leaves the rest as it was."
        case .clipboard:
            "Anything a password manager marks as concealed is skipped, and the list never leaves this Mac."
        case .taskManager:
            "Quitting asks the program to stop and save. Forcing it does not, and anything unsaved is lost."
        case .vault:
            "A vault is an ordinary encrypted disk image: it opens in Disk Utility on any Mac, with or without UniMacHub. Forget the password and nothing can open it, not UniMacHub and not Apple."
        case .dns:
            "Each change here is for the whole Mac, so macOS asks for your password. Everything UniMacHub writes can be taken back out from this screen."
        case .securityAnalyzer:
            "A finding is a question, not a verdict. Settling one with a clean VirusTotal result or your own judgement keeps it settled until the file changes."
        default:
            nil
        }
    }

    /// What a planned screen says when opened: the shape of the thing, and what it will cost.
    /// Nil for everything built, which answers for itself on its own screen.
    var plannedNote: LocalizedStringKey? {
        switch self {
        case .menuBarTidy:
            "A crowded menu bar hides what matters. This will put the icons you rarely need behind a divider, and bring them back on a click."
        case .windowTiling:
            "Halves, quarters and thirds from the keyboard. This one needs permission to move other apps' windows, which is a larger thing to ask than anything here does today."
        case .audioSwitch:
            "Headphones to speakers in one click, and a volume slider for each app rather than one for everything."
        case .displayControl:
            "Brightness on an external screen, which macOS leaves to the monitor's own buttons, and a quick change of resolution."
        case .batteryCare:
            "Cycles, capacity and wear. Holding the charge below full is what makes a battery last, and that part depends on the Mac's own controller."
        case .dockWidgets:
            "A Dock with the apps you choose shown as small live widgets. macOS never gives up its own Dock, so this hides it rather than replacing it, and puts it back when you quit."
        case .batchRename:
            "Numbering, find and replace, dates from the file itself — with the whole list of new names shown before a single file moves."
        case .terminalThemes:
            "Colour schemes for Terminal that hold up over a long day, applied to its profiles."
        case .networkControl:
            "Reorder the adapters macOS tries and switch a service off, each needing your password, as these are settings for the whole Mac. DNS has a screen of its own now."
        case .linkAggregation:
            "Sending different connections over Wi-Fi and Ethernet at once, so their speeds add up. This needs a virtual network device and administrator rights, which changes how much trust the app is asking for."
        case .firewall:
            "What may listen for connections and what is reaching out, with a switch for each."
        case .permissions:
            "Camera, microphone, screen, files and automation: which app was granted what, gathered in one list instead of a dozen panes."
        case .island:
            "A live strip around the notch: volume and brightness, music, scans in progress, files to hand on, and coding agents that are waiting for you. On a screen without a notch, a small tab at the top."
        case .assistant:
            "Your choice of model: Claude through your own gateway or key, OpenAI, or one running on this Mac. Three modes: limited to UniMacHub, free, or exactly what you allow. Deleting, erasing, changing settings or sending anything always waits for your yes."
        case .timeMachine:
            "A watch on backups that quietly stopped, a search for deleted files across every backup, restoring into any folder, and a warning before Time Machine thins away the last copy of something."
        case .iCloudSync:
            "Every transfer with its progress, the files iCloud keeps failing on, and a history of what finished."
        case .converter:
            "Images, video, audio and PDF turned into other formats, made smaller or stripped of their metadata, with what macOS already has, saved beside the original."
        case .lanScan:
            "Every device on the local network by name and address, and which services each one offers. Your own network only."
        case .appConnections:
            "Live connections grouped by app, domain or address, so an app phoning home is easy to spot."
        default:
            nil
        }
    }
}
