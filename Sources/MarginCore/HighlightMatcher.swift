import Foundation

public enum HighlightMatcher {
    public static func matchedLineIndices(quote: String, lines: [String]) -> [Int] {
        let phrase = normalized(quote)
        guard !phrase.isEmpty else { return [] }

        var text = ""
        var spans: [(line: Int, range: NSRange)] = []
        for (index, line) in lines.enumerated() {
            let content = normalized(line)
            guard !content.isEmpty else { continue }
            if !text.isEmpty { text += "\n" }
            let start = text.utf16.count
            text += content
            spans.append((index, NSRange(location: start, length: content.utf16.count)))
        }

        var pattern = ""
        var previous: Character?
        for character in phrase {
            if previous?.isLetter == true, character.isLetter {
                // A typeset line may split a word that accessibility returns whole.
                pattern += #"(?:-\n)?"#
            }
            if character == " " { pattern += #"\s+"# }
            else {
                pattern += NSRegularExpression.escapedPattern(for: String(character))
                if character == "-" { pattern += #"\n?"# }
            }
            previous = character
        }
        guard let expression = try? NSRegularExpression(pattern: "(?=(\(pattern)))") else { return [] }
        // Lookahead also counts overlapping occurrences, so ambiguous short quotes stay unpainted.
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1 else { return [] }
        let match = matches[0].range(at: 1)
        return spans.filter { NSIntersectionRange($0.range, match).length > 0 }.map(\.line)
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{2010}", with: "-")
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
