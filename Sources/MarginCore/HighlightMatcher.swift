import Foundation

public enum HighlightMatcher {
    public struct TextMatch: Equatable, Sendable {
        public let line: Int
        /// UTF-16 range in the original line.
        public let range: NSRange

        public init(line: Int, range: NSRange) {
            self.line = line
            self.range = range
        }
    }

    public static func matchedLineIndices(quote: String, lines: [String], fallbackLines: [String] = []) -> [Int] {
        matchedRanges(quote: quote, lines: lines, fallbackLines: fallbackLines).map(\.line)
    }

    /// Lines index into `lines + fallbackLines`. An ambiguous native match prevents fallback.
    public static func matchedRanges(quote: String, lines: [String], fallbackLines: [String] = []) -> [TextMatch] {
        switch match(quote: quote, lines: lines) {
        case .unique(let ranges): return ranges
        case .ambiguous: return []
        case .missing:
            guard case .unique(let ranges) = match(quote: quote, lines: fallbackLines) else { return [] }
            return ranges.map { TextMatch(line: lines.count + $0.line, range: $0.range) }
        }
    }

    private enum Match {
        case missing, ambiguous
        case unique([TextMatch])
    }

    private static func match(quote: String, lines: [String]) -> Match {
        let phrase = normalized(quote)
        guard !phrase.isEmpty else { return .missing }

        var text = ""
        var spans: [(line: Int, range: NSRange)] = []
        for (index, line) in lines.enumerated() {
            let content = normalizedLine(line)
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
        return .unique(spans.compactMap { span in
            let overlap = NSIntersectionRange(span.range, match)
            guard overlap.length > 0 else { return nil }
            let local = NSRange(location: overlap.location - span.range.location, length: overlap.length)
            return TextMatch(line: span.line, range: originalRange(local, in: lines[span.line],
                                                                   normalizedLength: span.range.length))
        })
    }

    private static func originalRange(_ range: NSRange, in line: String, normalizedLength: Int) -> NSRange {
        if line.utf8.count == normalizedLength, line.utf8.allSatisfy({ $0 < 128 }) { return range }

        // Measure the normalized text outside each end of the match. Searching original
        // grapheme boundaries keeps a partial match inside a ligature on its whole glyph.
        let boundaries = Array(line.indices) + [line.endIndex]
        func boundary(omitting units: Int, fromStart: Bool) -> String.Index {
            var low = 0
            var high = boundaries.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                let index = boundaries[fromStart ? middle : boundaries.count - 1 - middle]
                let outside = fromStart ? line[..<index] : line[index...]
                if normalizedLine(String(outside)).utf16.count <= units { low = middle }
                else { high = middle - 1 }
            }
            return boundaries[fromStart ? low : boundaries.count - 1 - low]
        }

        let start = boundary(omitting: range.location, fromStart: true)
        let end = boundary(omitting: normalizedLength - NSMaxRange(range), fromStart: false)
        return NSRange(start..<end, in: line)
    }

    private static func normalizedLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return normalized(text) }
        return text.split(whereSeparator: \.isNewline)
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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
