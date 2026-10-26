import SwiftUI

enum SidebarSection: CaseIterable, Identifiable {
    case overview, cleanup, organize, space, recovery, search, applications, network, security, optimization

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Cleanup"
        case .organize: "Order"
        case .space: "Disk Space"
        case .recovery: "Recovery"
        case .search: "Search"
        case .applications: "Applications"
        case .network: "Network"
        case .security: "Security"
        case .optimization: "Optimization"
        }
    }

    var modules: [Module] {
        Module.allCases.filter { $0.section == self }
    }
}

enum Module: CaseIterable, Identifiable, Hashable {
    case dashboard, history, clipboard
    case systemJunk, developerJunk, trash, privacy, messengers, installers, projectBuilds
    case spaceLens, largeFiles, duplicates, disks
    case folderOrganizer
    case fileRecovery
    case deepSearch
    case uninstaller, leftovers, updater, slimming
    case networkAdapters
    case securityAnalyzer
    case loginItems, maintenance, taskManager, hiddenSettings, terminal, addOns

    var id: Self { self }

    var section: SidebarSection {
        switch self {
        case .dashboard, .history, .clipboard: .overview
        case .systemJunk, .developerJunk, .trash, .privacy, .messengers, .installers, .projectBuilds: .cleanup
        case .spaceLens, .largeFiles, .duplicates, .disks: .space
        case .folderOrganizer: .organize
        case .fileRecovery: .recovery
        case .deepSearch: .search
        case .uninstaller, .leftovers, .updater, .slimming: .applications
        case .networkAdapters: .network
        case .securityAnalyzer: .security
        case .loginItems, .maintenance, .taskManager, .hiddenSettings, .terminal, .addOns: .optimization
        }
    }

    var title: LocalizedStringKey {
        switch self {
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
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .dashboard: "Clean, optimize and protect your Mac."
        case .history: "Everything MacUtil has removed, with dates, sizes and paths."
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
        }
    }

    var symbol: String {
        switch self {
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
        }
    }

    /// Roadmap phase from PLAN.md in which the module gets implemented.
    var plannedPhase: Int {
        switch self {
        case .dashboard: 0
        case .history: 12
        case .clipboard: 16
        case .spaceLens, .largeFiles: 1
        case .systemJunk, .developerJunk, .trash: 2
        case .securityAnalyzer: 3
        case .uninstaller, .leftovers: 4
        case .duplicates: 5
        case .deepSearch: 6
        case .privacy, .loginItems, .maintenance, .taskManager, .hiddenSettings: 8
        case .messengers: 11
        case .installers, .projectBuilds: 12
        case .disks, .fileRecovery: 10
        case .folderOrganizer: 13
        case .networkAdapters: 14
        case .terminal, .addOns: 15
        case .updater: 9
        case .slimming: 12
        }
    }
}
