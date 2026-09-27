import SwiftUI

enum SidebarSection: CaseIterable, Identifiable {
    case overview, cleanup, space, recovery, search, applications, security, optimization

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Cleanup"
        case .space: "Disk Space"
        case .recovery: "Recovery"
        case .search: "Search"
        case .applications: "Applications"
        case .security: "Security"
        case .optimization: "Optimization"
        }
    }

    var modules: [Module] {
        Module.allCases.filter { $0.section == self }
    }
}

enum Module: CaseIterable, Identifiable, Hashable {
    case dashboard
    case systemJunk, developerJunk, trash, privacy
    case spaceLens, largeFiles, duplicates, disks
    case fileRecovery
    case deepSearch
    case uninstaller, leftovers, updater
    case securityAnalyzer
    case loginItems, maintenance, taskManager, hiddenSettings

    var id: Self { self }

    var section: SidebarSection {
        switch self {
        case .dashboard: .overview
        case .systemJunk, .developerJunk, .trash, .privacy: .cleanup
        case .spaceLens, .largeFiles, .duplicates, .disks: .space
        case .fileRecovery: .recovery
        case .deepSearch: .search
        case .uninstaller, .leftovers, .updater: .applications
        case .securityAnalyzer: .security
        case .loginItems, .maintenance, .taskManager, .hiddenSettings: .optimization
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: "Dashboard"
        case .systemJunk: "System Junk"
        case .developerJunk: "Developer Junk"
        case .trash: "Trash Bins"
        case .privacy: "Privacy"
        case .spaceLens: "Space Lens"
        case .largeFiles: "Large & Old Files"
        case .duplicates: "Duplicates"
        case .disks: "Disk Utilities"
        case .fileRecovery: "File Recovery"
        case .deepSearch: "Deep Search"
        case .uninstaller: "Uninstaller"
        case .leftovers: "Leftovers"
        case .updater: "Updater"
        case .securityAnalyzer: "Security Analyzer"
        case .loginItems: "Login Items"
        case .maintenance: "Maintenance"
        case .taskManager: "Task Manager"
        case .hiddenSettings: "Hidden Settings"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .dashboard: "Clean, optimize and protect your Mac."
        case .systemJunk: "Caches, logs, crash reports and other system leftovers."
        case .developerJunk: "Xcode data, package manager caches, Docker and old node_modules."
        case .trash: "Empty the Trash on all connected drives."
        case .privacy: "Browser history, cookies and recent items."
        case .spaceLens: "An interactive map of what takes up your disk."
        case .largeFiles: "Find big and long-unused files."
        case .duplicates: "Find identical files and free up space."
        case .disks: "Disks, volumes, partitions, first aid, disk images and speed tests."
        case .fileRecovery: "Bring back deleted files from the Trash, a snapshot, a backup or the disk itself."
        case .deepSearch: "Search everywhere by name, size, date or contents, including hidden files."
        case .uninstaller: "Remove apps together with all their leftovers."
        case .leftovers: "Files left behind by apps that are already deleted."
        case .updater: "Check your apps for updates."
        case .securityAnalyzer: "Signatures, permissions, security settings and VirusTotal checks."
        case .loginItems: "Everything that starts with your Mac."
        case .maintenance: "Rebuild caches and indexes, flush DNS, verify the disk."
        case .taskManager: "Everything running now, with what it costs and what you can do about it."
        case .hiddenSettings: "macOS settings that are not in System Settings."
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .systemJunk: "sparkles"
        case .developerJunk: "hammer"
        case .trash: "trash"
        case .privacy: "hand.raised"
        case .spaceLens: "chart.pie"
        case .largeFiles: "doc.badge.clock"
        case .duplicates: "doc.on.doc"
        case .disks: "internaldrive"
        case .fileRecovery: "clock.arrow.circlepath"
        case .deepSearch: "magnifyingglass"
        case .uninstaller: "trash.square"
        case .leftovers: "shippingbox"
        case .updater: "arrow.down.app"
        case .securityAnalyzer: "checkmark.shield"
        case .loginItems: "power"
        case .maintenance: "wrench.and.screwdriver"
        case .taskManager: "cpu"
        case .hiddenSettings: "slider.horizontal.3"
        }
    }

    /// Roadmap phase from PLAN.md in which the module gets implemented.
    var plannedPhase: Int {
        switch self {
        case .dashboard: 0
        case .spaceLens, .largeFiles: 1
        case .systemJunk, .developerJunk, .trash: 2
        case .securityAnalyzer: 3
        case .uninstaller, .leftovers: 4
        case .duplicates: 5
        case .deepSearch: 6
        case .privacy, .loginItems, .maintenance, .taskManager, .hiddenSettings: 8
        case .disks, .fileRecovery: 10
        case .updater: 9
        }
    }
}
