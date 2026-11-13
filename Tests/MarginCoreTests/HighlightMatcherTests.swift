import XCTest
@testable import MarginCore

final class HighlightMatcherTests: XCTestCase {
    func testUniquePhraseAcrossLinesNormalizesCaseAndWhitespace() {
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(
            quote: "QUOTED\n  text continues here",
            lines: ["Earlier text", "The quoted text", "", " continues\there and ends.", "Later text"]
        ), [1, 3])
    }

    func testDuplicateOccurrencesAreAmbiguousIncludingOverlappingMatches() {
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: "a quote", lines: ["a quote", "A QUOTE"]), [])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: "a quote", lines: ["a quote and a quote"]), [])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: "aa", lines: ["aaa"]), [])
    }

    func testAbsentOrEmptyPhraseDoesNotMatch() {
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: "A long quote", lines: ["A very long quote"]), [])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: "well known", lines: ["well-known"]), [])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: " \n\t", lines: ["Some text"]), [])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: "Some text", lines: []), [])
    }
}
