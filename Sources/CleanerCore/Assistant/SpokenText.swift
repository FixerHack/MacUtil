import Foundation

/// What macOS's recogniser hears, put together into what the person actually said.
public enum Transcript {
    /// The words of a text, lower case, without punctuation, for comparing.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’-")).inverted)
            .filter { !$0.isEmpty }
    }

    /// Takes in one partial result.
    ///
    /// macOS keeps revising its transcript ("В мене досить" becomes "У мене досить добре") and,
    /// after a pause, sometimes starts it afresh with only the new words. A revision replaces
    /// the current part; a fresh start is kept after it. A revision shares most of the current
    /// words; a fresh start does not.
    ///
    /// - Returns: what is settled so far, and the whole text with the new part.
    public static func merge(committed: String, latest: String, incoming: String) -> (committed: String, latest: String) {
        let current = String(latest.dropFirst(committed.count)).trimmingCharacters(in: .whitespaces)
        let old = words(current)
        let new = words(incoming)
        var committed = committed
        if !old.isEmpty, !new.isEmpty, !isRevision(old: old, new: new) {
            committed = latest.trimmingCharacters(in: .whitespaces) + " "
        }
        return (committed, committed + incoming)
    }

    /// Whether the new words rework the old ones rather than follow them.
    static func isRevision(old: [String], new: [String]) -> Bool {
        // Longer or as long, it carries on from where the old began, give or take a word.
        let shared = old.filter { word in new.contains { similar($0, word) } }.count
        if Double(shared) >= Double(old.count) * 0.5 { return true }
        // A much shorter text that shares nothing is a fresh start.
        return false
    }

    /// The same word, or one letter apart in a longer word ("кошик", "кошика").
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // A word heard half-way and then in full: "Від" and "Відкрий", "Уві" and "Увімкни".
        if min(a.count, b.count) >= 2, a.hasPrefix(b) || b.hasPrefix(a) { return true }
        guard min(a.count, b.count) >= 4 else { return false }
        let stemA = a.prefix(max(4, a.count - 2)), stemB = b.prefix(max(4, b.count - 2))
        return stemA.hasPrefix(stemB) || stemB.hasPrefix(stemA)
    }

    /// Takes out a phrase said, or stitched, twice in a row: "які файли в кошику які файли в
    /// кошику" becomes "які файли в кошику".
    public static func collapseRepeats(_ text: String) -> String {
        var tokens = text.split(separator: " ").map(String.init)
        var changed = true
        while changed {
            changed = false
            let plain = tokens.map { words($0).joined() }
            let count = tokens.count
            guard count >= 4 else { break }
            for length in stride(from: count / 2, through: 2, by: -1) {
                // The last `length` words equal the `length` words before them.
                let tail = Array(plain[(count - length)...])
                let before = Array(plain[(count - 2 * length) ..< (count - length)])
                if tail == before, !tail.joined().isEmpty {
                    tokens.removeLast(length)
                    changed = true
                    break
                }
            }
        }
        return tokens.joined(separator: " ")
    }
}

/// The word that wakes the assistant, heard however the recogniser spells it.
public enum WakeWord {
    /// The request around the wake word, without it; nil when the word was not said.
    ///
    /// "Хабе, відкрий ютуб", "відкрий ютуб, Хабе" and "Хаба відкрий ютуб" all give
    /// "відкрий ютуб". The word may come out a letter or two different, so a close match counts.
    public static func request(in text: String, word: String) -> String? {
        let target = Transcript.words(word)
        guard !target.isEmpty else { return nil }
        let tokens = text.split(separator: " ").map(String.init)
        let plain = tokens.map { Transcript.words($0).joined() }
        guard tokens.count >= target.count else { return nil }
        for start in 0 ... (tokens.count - target.count) {
            let window = Array(plain[start ..< start + target.count])
            if zip(window, target).allSatisfy({ close($0, $1) }) {
                var rest = tokens
                rest.removeSubrange(start ..< start + target.count)
                return rest.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            }
        }
        return nil
    }

    /// Equal, or for a word of four letters or more, at most one letter changed, added or
    /// dropped, with the first letter the same.
    static func close(_ heard: String, _ word: String) -> Bool {
        if heard == word { return true }
        guard word.count >= 4, heard.first == word.first else { return false }
        return distance(Array(heard), Array(word)) <= 1
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0 ... b.count)
        for (i, x) in a.enumerated() {
            var row = [i + 1]
            for (j, y) in b.enumerated() {
                row.append(min(previous[j + 1] + 1, row[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = row
        }
        return previous[b.count]
    }
}

/// A short goodbye that ends a spoken conversation without asking the model.
public enum Goodbye {
    /// Said at the end of anything short, they end it: "смішно, добре, відпочивай".
    static let strong = [
        "бувай", "па-па", "па па", "папа", "пока", "відбій", "на сьогодні все", "можеш іти", "відпочивай", "відпочинь",
        "відпочивати", "bye", "goodbye", "go rest", "that's all",
    ]
    /// Only on their own or with each other: "дякую" ends it, "відкрий ютуб, дякую" does not.
    static let weak = ["дякую", "все", "усе", "стоп", "досить", "вільний", "thanks", "thank", "you", "stop", "rest",
                       "ну", "добре", "окей", "ок", "ні", "гаразд", "ok", "okay", "no", "that's", "all", "it"]

    public static func isGoodbye(_ text: String) -> Bool {
        let words = Transcript.words(text)
        let plain = words.joined(separator: " ")
        guard !plain.isEmpty, words.count <= 5 else { return false }
        if strong.contains(where: { plain == $0 || plain.hasSuffix(" " + $0) }) { return true }
        let ending = ["дякую", "все", "усе", "стоп", "досить", "вільний", "thanks", "stop", "rest"]
        return words.allSatisfy { weak.contains($0) } && words.contains { ending.contains($0) }
    }
}
