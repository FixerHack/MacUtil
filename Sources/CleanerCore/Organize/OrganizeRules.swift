import Foundation

/// Sorts files into folders by rules, instead of removing them.
///
/// Everything else in MacUtil takes things away; this puts them in order. That makes the
/// risk a different one — a deleted file waits in the Trash, a moved file has to be found —
/// so nothing moves until the whole plan has been shown and accepted.

/// Sends files with these extensions into a folder.
public struct ExtensionRule: Codable, Sendable, Identifiable, Hashable {
    public var id = UUID()
    /// Written as people write it: "jpg, png, heic" or ".jpg".
    public var extensions: String
    /// A folder name, created inside the watched folder.
    public var destination: String
    public var isEnabled = true

    public init(extensions: String, destination: String, isEnabled: Bool = true) {
        self.extensions = extensions
        self.destination = destination
        self.isEnabled = isEnabled
    }

    public var list: [String] {
        extensions
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "").lowercased() }
            .filter { !$0.isEmpty }
    }

    public func matches(extension name: String) -> Bool {
        guard isEnabled else { return false }
        return list.contains(name.lowercased())
    }
}

/// Sends files whose name fits a pattern into a folder.
public struct NameRule: Codable, Sendable, Identifiable, Hashable {
    public var id = UUID()
    /// `Invoice*`, `*Screenshot*`, `report-2025.*`. Case does not matter.
    public var pattern: String
    public var destination: String
    /// Names this rule leaves alone even when the pattern fits.
    public var exceptions: [String] = []
    public var isEnabled = true

    public init(pattern: String, destination: String, exceptions: [String] = [], isEnabled: Bool = true) {
        self.pattern = pattern
        self.destination = destination
        self.exceptions = exceptions
        self.isEnabled = isEnabled
    }

    public func matches(name: String) -> Bool {
        guard isEnabled, !pattern.isEmpty else { return false }
        guard !exceptions.contains(where: { Self.fits(name: name, pattern: $0) }) else { return false }
        return Self.fits(name: name, pattern: pattern)
    }

    /// Shell-style matching with `*` and `?`, which is what people expect from a pattern box.
    static func fits(name: String, pattern: String) -> Bool {
        fnmatch(pattern, name, FNM_CASEFOLD) == 0
    }
}

/// A folder being kept in order.
public struct WatchedFolder: Codable, Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var path: String
    public var extensionRules: [ExtensionRule] = []
    public var nameRules: [NameRule] = []
    /// Sort new arrivals without being asked.
    public var organizesAutomatically = false

    public init(path: String, extensionRules: [ExtensionRule] = [], nameRules: [NameRule] = []) {
        self.path = path
        self.extensionRules = extensionRules
        self.nameRules = nameRules
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// Folder names the rules send things to; the planner must not sort those as well.
    var destinations: Set<String> {
        Set(extensionRules.filter(\.isEnabled).map(\.destination)
            + nameRules.filter(\.isEnabled).map(\.destination))
    }
}

/// One file and where a rule would put it.
public struct PlannedMove: Sendable, Identifiable, Hashable {
    public let source: String
    public let destination: String
    /// The folder the rule names, for grouping in the list.
    public let folder: String
    public let size: Int64
    /// True when something is already there, so the name gained a number.
    public let wasRenamed: Bool

    public var id: String { source }
    public var name: String { (source as NSString).lastPathComponent }
    public var newName: String { (destination as NSString).lastPathComponent }
}

public struct OrganizeResult: Sendable {
    public var moved: [PlannedMove] = []
    public var failures: [CleanupFailure] = []

    public var movedBytes: Int64 { moved.reduce(0) { $0 + $1.size } }
}

public enum FolderOrganizer {
    /// Ready-made rules for the kinds of file that pile up in a Downloads folder.
    public static var presets: [ExtensionRule] {
        [
            ExtensionRule(extensions: "jpg, jpeg, png, gif, webp, heic, bmp, tiff, svg", destination: "Images"),
            ExtensionRule(extensions: "raw, cr2, cr3, nef, arw, dng, orf, raf", destination: "RAW Photos"),
            ExtensionRule(extensions: "mp4, mov, mkv, avi, webm, flv, wmv, m4v", destination: "Videos"),
            ExtensionRule(extensions: "mp3, wav, flac, aac, m4a, ogg, aiff, opus", destination: "Audio"),
            ExtensionRule(extensions: "pdf, doc, docx, pages, odt, rtf, txt, md", destination: "Documents"),
            ExtensionRule(extensions: "xls, xlsx, numbers, csv, tsv, ods", destination: "Spreadsheets"),
            ExtensionRule(extensions: "ppt, pptx, key, odp", destination: "Presentations"),
            ExtensionRule(extensions: "zip, rar, 7z, tar, gz, bz2, xz, tgz", destination: "Archives"),
            ExtensionRule(extensions: "dmg, pkg, mpkg, xip, deb, rpm", destination: "Installers"),
            ExtensionRule(extensions: "json, xml, yaml, yml, sql, db, sqlite, plist", destination: "Data"),
            ExtensionRule(extensions: "swift, js, ts, py, rs, go, java, c, cpp, h, rb, sh", destination: "Code"),
            ExtensionRule(extensions: "psd, ai, xd, fig, sketch, blend, obj, stl", destination: "Design"),
            ExtensionRule(extensions: "epub, mobi, azw3, cbr, cbz", destination: "Books"),
            ExtensionRule(extensions: "ttf, otf, woff, woff2, ttc", destination: "Fonts"),
        ]
    }

    /// What would happen, without anything happening yet.
    ///
    /// Only the folder's own contents are considered, never what is already filed away, and
    /// name rules win over extension rules because they say something more specific.
    public static func plan(_ folder: WatchedFolder) -> [PlannedMove] {
        let fileManager = FileManager.default
        let root = URL(filePath: folder.path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey, .isHiddenKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        let destinations = folder.destinations
        // Names taken during this plan, so two files never aim at the same new path.
        var taken = Set<String>()
        var moves: [PlannedMove] = []

        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            // A folder a rule fills is not something to file away again.
            if isFolder, destinations.contains(url.lastPathComponent) { continue }
            // Plain folders are left alone: only files and bundles are sorted.
            if isFolder { continue }

            let name = url.lastPathComponent
            guard let destination = destination(for: name, in: folder) else { continue }

            let target = root.appending(path: destination)
            let free = freeName(for: name, in: target, taken: &taken)
            moves.append(PlannedMove(
                source: url.path(percentEncoded: false),
                destination: target.appending(path: free).path(percentEncoded: false),
                folder: destination,
                size: Int64(values?.totalFileAllocatedSize ?? 0),
                wasRenamed: free != name
            ))
        }
        return moves
    }

    /// A name rule beats an extension rule: "Invoice-2025.pdf" belongs with the invoices,
    /// not with every other PDF.
    static func destination(for name: String, in folder: WatchedFolder) -> String? {
        if let rule = folder.nameRules.first(where: { $0.matches(name: name) }) {
            return rule.destination
        }
        let suffix = (name as NSString).pathExtension
        guard !suffix.isEmpty else { return nil }
        return folder.extensionRules.first { $0.matches(extension: suffix) }?.destination
    }

    /// A name nothing else holds: "report.pdf", then "report 2.pdf", and so on.
    static func freeName(for name: String, in folder: URL, taken: inout Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        var candidate = name
        var counter = 1
        while taken.contains(folder.appending(path: candidate).path(percentEncoded: false))
            || FileManager.default.fileExists(atPath: folder.appending(path: candidate).path(percentEncoded: false))
        {
            counter += 1
            candidate = suffix.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(suffix)"
        }
        taken.insert(folder.appending(path: candidate).path(percentEncoded: false))
        return candidate
    }

    /// Carries out a plan that was shown first.
    public static func apply(_ moves: [PlannedMove]) async -> OrganizeResult {
        await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            var result = OrganizeResult()
            for move in moves {
                let destination = URL(filePath: move.destination)
                do {
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: URL(filePath: move.source), to: destination)
                    result.moved.append(move)
                } catch {
                    result.failures.append(CleanupFailure(
                        path: move.source, reason: (error as NSError).localizedDescription
                    ))
                }
            }
            return result
        }.value
    }

    /// Puts files back where they came from, for when a sort was not what was wanted.
    public static func undo(_ result: OrganizeResult) async -> OrganizeResult {
        let back = result.moved.map {
            PlannedMove(
                source: $0.destination, destination: $0.source, folder: $0.folder,
                size: $0.size, wasRenamed: false
            )
        }
        return await apply(back)
    }
}
