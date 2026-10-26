import Foundation

/// A region of someone's configuration file that MacUtil owns, and nothing outside it.
///
/// These files are written by hand over years. Rewriting one to change a setting would be
/// the quickest way to lose work that cannot be got back, so everything MacUtil adds goes
/// between two marker lines: the rest of the file is copied through untouched, and removing
/// the block puts the file back exactly as it was.
public enum ManagedBlock {
    public static let begin = "# >>> MacUtil >>>"
    public static let end = "# <<< MacUtil <<<"
    static let note = "# Lines between these markers are MacUtil's. Everything else is yours."

    /// The lines MacUtil currently keeps in that file.
    public static func read(from path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return read(in: text)
    }

    static func read(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: begin), let finish = lines[start...].firstIndex(of: end),
              start + 1 < finish
        else { return [] }
        return Array(lines[(start + 1) ..< finish]).filter { $0 != note }
    }

    /// Replaces the block with these lines, or takes it out when there are none.
    ///
    /// The block goes at the end of the file. For `~/.ssh/config` that placement is not a
    /// detail: ssh keeps the first value it finds for a setting, so a catch-all at the end
    /// gives way to everything written above it.
    public static func write(_ lines: [String], to path: String) throws {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let updated = replacing(lines, in: existing)
        if updated.isEmpty, !FileManager.default.fileExists(atPath: path) { return }
        try FileManager.default.createDirectory(
            at: URL(filePath: path).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try updated.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func replacing(_ lines: [String], in text: String) -> String {
        var kept = text.components(separatedBy: "\n")
        if let start = kept.firstIndex(of: begin), let finish = kept[start...].firstIndex(of: end) {
            kept.removeSubrange(start ... finish)
            // A file that ended with the block keeps its single trailing newline.
            while kept.count > 1, kept.last == "", kept[kept.count - 2] == "" {
                kept.removeLast()
            }
        }
        guard !lines.isEmpty else {
            return kept.joined(separator: "\n")
        }

        while kept.last == "" { kept.removeLast() }
        if !kept.isEmpty { kept.append("") }
        kept.append(contentsOf: [begin, note] + lines + [end, ""])
        return kept.joined(separator: "\n")
    }

    public static func remove(from path: String) throws {
        try write([], to: path)
    }
}
