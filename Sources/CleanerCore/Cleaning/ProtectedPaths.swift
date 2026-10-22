import Foundation

/// Places the person has told MacUtil to leave alone.
///
/// The built-in safety rules decide what is dangerous to remove; this decides what is
/// *wanted*, which is something only the person can know. A cache MacUtil considers
/// disposable may be the one that takes an hour to rebuild, so there has to be a way to
/// say so once instead of unticking it on every scan.
public struct ProtectedPaths: Sendable, Equatable {
    public static let defaultsKey = "protectedPaths"

    public let paths: [String]

    public init(paths: [String] = []) {
        // Resolved once, so a path added through a symlink still matches what the scanners see.
        self.paths = paths.map(Self.normalize)
    }

    /// The one spelling of a path this type works in.
    ///
    /// `realpath` only answers for paths that exist, and both ends of a comparison may name
    /// something that does not: a protected folder can be deleted and made again, and a
    /// scanned item sits inside one. So the longest part of the path that does exist is
    /// resolved and the rest is kept as written. Without this `/tmp/keep` would resolve to
    /// `/private/tmp/keep` while `/tmp/keep/inside` stayed as it was, and one would stop
    /// covering the other.
    static func normalize(_ path: String) -> String {
        guard path != "/" else { return path }
        var trailing: [String] = []
        var current = path as NSString
        while current.length > 1 {
            if FileManager.default.fileExists(atPath: current as String) {
                let resolved = SafetyGuard.resolve(current as String)
                return trailing.isEmpty ? resolved
                    : (resolved == "/" ? "" : resolved) + "/" + trailing.joined(separator: "/")
            }
            trailing.insert(current.lastPathComponent, at: 0)
            current = current.deletingLastPathComponent as NSString
        }
        return "/" + trailing.joined(separator: "/")
    }

    public static func current(_ defaults: UserDefaults = .standard) -> ProtectedPaths {
        ProtectedPaths(paths: defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    public var isEmpty: Bool { paths.isEmpty }

    /// True when the path is on the list or sits inside something on it.
    public func covers(_ path: String) -> Bool {
        guard !paths.isEmpty else { return false }
        let resolved = Self.normalize(path)
        return paths.contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
    }

    public func adding(_ path: String) -> ProtectedPaths {
        let resolved = Self.normalize(path)
        guard !paths.contains(resolved) else { return self }
        return ProtectedPaths(paths: (paths + [resolved]).sorted())
    }

    public func removing(_ path: String) -> ProtectedPaths {
        let resolved = Self.normalize(path)
        return ProtectedPaths(paths: paths.filter { $0 != resolved })
    }
}
