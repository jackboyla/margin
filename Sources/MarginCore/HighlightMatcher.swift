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
            if !text.isEmpty { text += " " }
            let start = text.utf16.count
            text += content
            spans.append((index, NSRange(location: start, length: content.utf16.count)))
        }

        let searchable = text as NSString
        let match = searchable.range(of: phrase, options: .literal)
        guard match.location != NSNotFound else { return [] }
        let remaining = NSRange(location: match.location + 1, length: searchable.length - match.location - 1)
        guard searchable.range(of: phrase, options: .literal, range: remaining).location == NSNotFound else {
            return []
        }
        return spans.filter { NSIntersectionRange($0.range, match).length > 0 }.map(\.line)
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
