import Foundation

/// Describes one category of junk: where it lives, how safe it is to remove,
/// and which running apps make it unsafe to touch.
public struct JunkRule: Sendable, Identifiable {
    public enum Group: String, Sendable, CaseIterable {
        case system, developer
    }

    public enum Safety: Sendable {
        /// Regenerated automatically; selected by default.
        case safe
        /// Worth a look before removing; not selected by default.
        case review
    }

    public enum Source: Sendable {
        /// Every item directly inside a folder, except the listed names.
        case contents(of: String, excluding: Set<String> = [])
        /// Specific files or folders. `*` wildcards are allowed.
        case paths([String])
        /// Files with these extensions inside a folder, last modified before the cutoff.
        case oldFiles(in: String, extensions: Set<String>, olderThanDays: Int)
        /// Property lists in ~/Library/Preferences that macOS can no longer read.
        case brokenPreferences
        /// `node_modules` folders of projects nobody touched for a while.
        case staleNodeModules(olderThanDays: Int)
    }

    public let id: String
    public let group: Group
    public let title: LocalizedStringResource
    public let details: LocalizedStringResource
    public let safety: Safety
    public let sources: [Source]
    /// If any of these apps is running, the rule's items are shown but locked.
    public let appBundleIDs: Set<String>

    public init(
        id: String,
        group: Group,
        title: LocalizedStringResource,
        details: LocalizedStringResource,
        safety: Safety,
        sources: [Source],
        appBundleIDs: Set<String> = []
    ) {
        self.id = id
        self.group = group
        self.title = title
        self.details = details
        self.safety = safety
        self.sources = sources
        self.appBundleIDs = appBundleIDs
    }

    /// Folders the rule reads from, with `~` expanded. Used so a general rule
    /// (user caches) leaves items that a specific rule (Homebrew cache) claims.
    func roots(home: String) -> [String] {
        sources.flatMap { source -> [String] in
            switch source {
            case let .contents(folder, _): [JunkScanner.expand(folder, home: home)]
            case let .paths(paths): paths.filter { !$0.contains("*") }.map { JunkScanner.expand($0, home: home) }
            case let .oldFiles(folder, _, _): [JunkScanner.expand(folder, home: home)]
            case .brokenPreferences, .staleNodeModules: []
            }
        }
    }
}

public struct JunkItem: Sendable, Identifiable, Hashable {
    public let path: String
    public let size: Int64
    public let ruleID: String
    /// Bundle ID of a running app that owns the item; such items are not removed.
    public let inUseBy: String?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var isInUse: Bool { inUseBy != nil }
}

public struct JunkCategory: Sendable, Identifiable {
    public let rule: JunkRule
    public let items: [JunkItem]

    public var id: String { rule.id }

    public var size: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    public var removableSize: Int64 {
        items.filter { !$0.isInUse }.reduce(0) { $0 + $1.size }
    }
}
