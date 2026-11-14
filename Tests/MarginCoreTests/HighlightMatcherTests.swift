import XCTest
@testable import MarginCore

final class HighlightMatcherTests: XCTestCase {
    func testUniquePhraseAcrossLinesNormalizesCaseAndWhitespace() {
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(
            quote: "QUOTED\n  text continues here",
            lines: ["Earlier text", "The quoted text", "", " continues\there and ends.", "Later text"]
        ), [1, 3])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(
            quote: "In the following sections, we describe self-attention.",
            lines: ["Earlier text", "In the follow-", "ing sections, we describe self-", "attention."]
        ), [1, 2, 3])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(
            quote: "The efficient model's layers", lines: ["The efﬁcient model’s lay\u{00AD}ers"]
        ), [0])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(
            quote: "a quote", lines: ["Native text without the quote"], fallbackLines: ["Earlier text", "a quote"]
        ), [2])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(
            quote: "a quote", lines: ["a quote"], fallbackLines: ["a quote"]
        ), [0])
    }

    func testDuplicateOccurrencesAreAmbiguousIncludingOverlappingMatches() {
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: "a quote", lines: ["a quote", "A QUOTE"]), [])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: "a quote", lines: ["a quote and a quote"]), [])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: "aa", lines: ["aaa"]), [])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(
            quote: "following", lines: ["following", "follow-", "ing"]
        ), [])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(
            quote: "a quote", lines: ["a quote", "A QUOTE"], fallbackLines: ["a quote"]
        ), [])
    }

    func testAbsentOrEmptyPhraseDoesNotMatch() {
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: "A long quote", lines: ["A very long quote"]), [])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: "well known", lines: ["well-known"]), [])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: " \n\t", lines: ["Some text"]), [])
        XCTAssertEqual(HighlightMatcher.matchedLineIndices(quote: "Some text", lines: []), [])
    }
}
