import Foundation

/// Works out an arithmetic expression typed by hand, for the Dock's calculator.
///
/// A small parser of its own rather than `NSExpression`, which raises an Objective-C
/// exception, and so crashes, on a malformed formula. Numbers take a point or a comma;
/// `+ − × ÷ * / ^ %` and parentheses work, and `%` after a number means a hundredth of it.
public enum Arithmetic {
    public static func evaluate(_ text: String) -> Double? {
        var parser = Parser(Array(normalise(text)))
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    /// The answer as a person would write it: no trailing zeros, at most ten decimals.
    public static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let text = String(format: "%.10f", value)
        return text.replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private static func normalise(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
    }

    private struct Parser {
        let characters: [Character]
        var index = 0

        init(_ characters: [Character]) {
            self.characters = characters
        }

        var atEnd: Bool { index == characters.count }
        private var next: Character? { index < characters.count ? characters[index] : nil }

        /// Sums and differences.
        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let symbol = next, symbol == "+" || symbol == "-" {
                index += 1
                guard let right = term() else { return nil }
                value = symbol == "+" ? value + right : value - right
            }
            return value
        }

        /// Products and quotients.
        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let symbol = next, symbol == "*" || symbol == "/" {
                index += 1
                guard let right = power() else { return nil }
                if symbol == "/" {
                    guard right != 0 else { return nil }
                    value /= right
                } else {
                    value *= right
                }
            }
            return value
        }

        /// Powers, right to left: 2^3^2 is 2^9.
        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if next == "^" {
                index += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        mutating func unary() -> Double? {
            if next == "-" {
                index += 1
                return unary().map { -$0 }
            }
            if next == "+" {
                index += 1
                return unary()
            }
            return percent()
        }

        mutating func percent() -> Double? {
            guard var value = primary() else { return nil }
            while next == "%" {
                index += 1
                value /= 100
            }
            return value
        }

        mutating func primary() -> Double? {
            if next == "(" {
                index += 1
                guard let value = expression(), next == ")" else { return nil }
                index += 1
                return value
            }
            let start = index
            while let symbol = next, symbol.isNumber || symbol == "." {
                index += 1
            }
            guard index > start else { return nil }
            return Double(String(characters[start ..< index]))
        }
    }
}
