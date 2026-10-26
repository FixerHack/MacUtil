import Foundation

/// A region of someone's configuration file that MacUtil owns, and nothing outside it.
///
/// These files are written by hand over years. Rewriting one to change a setting would be
/// the quickest way to lose work that cannot be got back, so everything MacUtil adds goes
/// between two marker lines: the rest of the file is copied through untouched, and removing
/// the block puts the file back exactly as it was.
public enum ManagedBlock {
    public static let begin = "# >>> UniMacHub >>>"
    public static let end = "# <<< UniMacHub <<<"
    static let note = "# Lines between these markers are UniMacHub's. Everything else is yours."

    /// The markers written before the app was renamed. A block already in someone's file
    /// has to stay findable, or the app would lose the ability to take its own lines back out.
    static let previous = (begin: "# >>> MacUtil >>>", end: "# <<< MacUtil <<<")
    static let previousNote = "# Lines between these markers are MacUtil's. Everything else is yours."

    /// Where the block sits in these lines, under either pair of markers.
    static func range(in lines: [String]) -> ClosedRange<Int>? {
        for pair in [(begin, end), previous] {
            guard let start = lines.firstIndex(of: pair.0),
                  let finish = lines[start...].firstIndex(of: pair.1)
            else { continue }
            return start ... finish
        }
        return nil
    }

    /// The lines MacUtil currently keeps in that file.
    public static func read(from path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return read(in: text)
    }

    static func read(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let range = range(in: lines), range.lowerBound + 1 < range.upperBound else { return [] }
        return Array(lines[(range.lowerBound + 1) ..< range.upperBound])
            .filter { $0 != note && $0 != previousNote }
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
        if let range = range(in: kept) {
            kept.removeSubrange(range)
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
