import CoreGraphics
import Foundation

public enum TextRangeGeometry {
    /// Splits a range's enclosing box at visual line breaks, using the text provider's glyph bounds.
    public static func rectangles(text: String, range: NSRange,
                                  bounds: (NSRange) -> CGRect?) -> [CGRect]? {
        let value = text as NSString
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= value.length else { return nil }
        var characters: [NSRange] = []
        value.enumerateSubstrings(in: range, options: .byComposedCharacterSequences) { part, span, _, _ in
            if let part, part.rangeOfCharacter(from: .newlines) == nil { characters.append(span) }
        }
        var cache: [NSRange: CGRect] = [:]
        func read(_ span: NSRange) -> CGRect? {
            if let rect = cache[span] { return rect }
            guard let rect = bounds(span), !rect.isNull, !rect.isInfinite else { return nil }
            cache[span] = rect
            return rect
        }
        func split(_ part: ArraySlice<NSRange>) -> [CGRect]? {
            guard let first = part.first, let last = part.last else { return [] }
            let whole = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            guard let rect = read(whole) else { return nil }
            if part.count == 1 { return rect.isEmpty ? [] : [rect] }
            guard let start = read(first), let end = read(last) else { return nil }
            let height = max(start.height, end.height)
            if !start.isEmpty, !end.isEmpty,
               abs(start.midY - end.midY) < min(start.height, end.height) * 0.4,
               rect.height <= height * 1.25 {
                return [rect]
            }
            let middle = part.index(part.startIndex, offsetBy: part.count / 2)
            guard let left = split(part[..<middle]), let right = split(part[middle...]) else { return nil }
            return left + right
        }
        guard let pieces = split(characters[...]) else { return nil }
        var result: [CGRect] = []
        for rect in pieces.sorted(by: { $0.midY == $1.midY ? $0.minX < $1.minX : $0.midY < $1.midY }) {
            if let previous = result.last,
               abs(previous.midY - rect.midY) < min(previous.height, rect.height) * 0.4,
               rect.minX <= previous.maxX + 1, previous.minX <= rect.maxX + 1 {
                result[result.count - 1] = previous.union(rect)
            } else { result.append(rect) }
        }
        return result
    }
}
