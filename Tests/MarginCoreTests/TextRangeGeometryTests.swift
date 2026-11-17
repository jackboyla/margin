import CoreGraphics
import XCTest
@testable import MarginCore

final class TextRangeGeometryTests: XCTestCase {
    func testWrappedSubstringUsesGlyphBoundsInsteadOfItsEnclosingParagraph() throws {
        let text = "abcdefghijklmnopqrstuvwxyz0123456789"
        let selected = NSRange(location: 7, length: 18)
        // A fixed-width layout with ten characters on each visual line, no newline in the text.
        func bounds(_ range: NSRange) -> CGRect? {
            (range.location..<NSMaxRange(range)).map { index in
                CGRect(x: (index % 10) * 8, y: (index / 10) * 20, width: 8, height: 16)
            }.reduce(CGRect.null) { $0.union($1) }
        }
        let actual = try XCTUnwrap(TextRangeGeometry.rectangles(text: text, range: selected, bounds: bounds))
        XCTAssertEqual(actual, [CGRect(x: 56, y: 0, width: 24, height: 16),
                                CGRect(x: 0, y: 20, width: 80, height: 16),
                                CGRect(x: 0, y: 40, width: 40, height: 16)])
        XCTAssertNotEqual(actual, [try XCTUnwrap(bounds(selected))])
        let translated = try XCTUnwrap(TextRangeGeometry.rectangles(text: text, range: selected) {
            bounds($0)?.offsetBy(dx: 0, dy: -11)
        })
        XCTAssertEqual(translated, actual.map { $0.offsetBy(dx: 0, dy: -11) })
        XCTAssertNil(TextRangeGeometry.rectangles(text: text, range: selected) { _ in nil })
    }

    func testDoesNotSplitComposedCharactersAndKeepsSeparateLines() throws {
        let text = "🙂e\u{0301}\nword"
        let ranges = [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2),
                      NSRange(location: 5, length: 1), NSRange(location: 6, length: 1),
                      NSRange(location: 7, length: 1), NSRange(location: 8, length: 1)]
        let boxes = [CGRect(x: 0, y: 0, width: 16, height: 16), CGRect(x: 16, y: 0, width: 8, height: 16)] +
            (0..<4).map { CGRect(x: $0 * 8, y: 20, width: 8, height: 16) }
        let actual = try XCTUnwrap(TextRangeGeometry.rectangles(text: text, range: NSRange(location: 0, length: 9)) { range in
            XCTAssertTrue(ranges.contains { $0.location == range.location })
            XCTAssertTrue(ranges.contains { NSMaxRange($0) == NSMaxRange(range) })
            return zip(ranges, boxes).filter { NSIntersectionRange($0.0, range).length > 0 }
                .reduce(CGRect.null) { $0.union($1.1) }
        })
        XCTAssertEqual(actual, [CGRect(x: 0, y: 0, width: 24, height: 16), CGRect(x: 0, y: 20, width: 32, height: 16)])
    }
}
