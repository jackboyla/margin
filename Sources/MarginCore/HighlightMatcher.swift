import Foundation

public enum HighlightMatcher {
    /// Returns indices into `lines + fallbackLines`; ambiguity in `lines` prevents fallback.
    public static func matchedLineIndices(quote: String, lines: [String], fallbackLines: [String] = []) -> [Int] {
        switch match(quote: quote, lines: lines) {
        case .unique(let indices): return indices
        case .ambiguous: return []
        case .missing:
            guard case .unique(let indices) = match(quote: quote, lines: fallbackLines) else { return [] }
            return indices.map { lines.count + $0 }
        }
    }

    private enum Match {
        case missing, ambiguous
        case unique([Int])
    }

    private static func match(quote: String, lines: [String]) -> Match {
        let phrase = normalized(quote)
        guard !phrase.isEmpty else { return .missing }

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
        guard let expression = try? NSRegularExpression(pattern: "(?=(\(pattern)))") else { return .missing }
        // Lookahead also counts overlapping occurrences, so ambiguous short quotes stay unpainted.
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return .missing }
        guard matches.count == 1 else { return .ambiguous }
        let match = matches[0].range(at: 1)
        return .unique(spans.filter { NSIntersectionRange($0.range, match).length > 0 }.map(\.line))
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
