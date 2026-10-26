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
    case hub, dashboard, history, clipboard
    case systemJunk, developerJunk, projectBuilds, messengers, installers, trash, privacy
    case spaceLens, largeFiles, duplicates, disks, fileRecovery
    case uninstaller, leftovers, updater, slimming, addOns
    case folderOrganizer, deepSearch
    case taskManager, loginItems, maintenance, hiddenSettings, terminal
    case networkAdapters
    case securityAnalyzer

    // Planned, listed so the shape of the app is honest about where it is going.
    case menuBarTidy, windowTiling, audioSwitch, displayControl, batteryCare
    case dockWidgets, batchRename, terminalThemes
    case networkControl, linkAggregation
    case firewall, permissions

    var id: Self { self }

    /// Not built yet: shown with a mark, and opening one explains what it will do.
    var isPlanned: Bool {
        switch self {
        case .menuBarTidy, .windowTiling, .audioSwitch, .displayControl, .batteryCare,
             .dockWidgets, .batchRename, .terminalThemes, .networkControl, .linkAggregation,
             .firewall, .permissions:
            true
        default:
            false
        }
    }

    var section: SidebarSection {
        switch self {
        case .hub, .dashboard, .history, .clipboard: .overview
        case .systemJunk, .developerJunk, .projectBuilds, .messengers, .installers, .trash, .privacy: .cleanup
        case .spaceLens, .largeFiles, .duplicates, .disks, .fileRecovery: .storage
        case .uninstaller, .leftovers, .updater, .slimming, .addOns, .dockWidgets: .applications
        case .folderOrganizer, .deepSearch, .batchRename: .files
        case .taskManager, .loginItems, .maintenance, .hiddenSettings, .terminal,
             .terminalThemes, .menuBarTidy, .windowTiling, .audioSwitch, .displayControl, .batteryCare:
            .system
        case .networkAdapters, .networkControl, .linkAggregation: .network
        case .securityAnalyzer, .firewall, .permissions: .security
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .hub: "Hub"
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
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .hub: "Everything this Mac can be told, in one ring."
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
        case .networkControl: "Change DNS, the order of adapters, and what is switched on."
        case .linkAggregation: "Use Wi-Fi and Ethernet at once, adding up their speed."
        case .firewall: "What is allowed to listen, and what is reaching out."
        case .permissions: "Which apps hold which permissions, in one list."
        }
    }

    var symbol: String {
        switch self {
        case .hub: "circle.hexagongrid"
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
            "Change DNS servers, reorder the adapters macOS tries, and switch a service off — each needing your password, as these are settings for the whole Mac."
        case .linkAggregation:
            "Sending different connections over Wi-Fi and Ethernet at once, so their speeds add up. This needs a virtual network device and administrator rights, which changes how much trust the app is asking for."
        case .firewall:
            "What may listen for connections and what is reaching out, with a switch for each."
        case .permissions:
            "Camera, microphone, screen, files and automation: which app was granted what, gathered in one list instead of a dozen panes."
        default:
            nil
        }
    }
}
