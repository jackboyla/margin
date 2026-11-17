import XCTest
@testable import MarginCore

final class HighlightMatcherTests: XCTestCase {
    func testUniquePhraseAcrossLinesNormalizesCaseAndWhitespace() {
        XCTAssertEqual(HighlightMatcher.matchedRanges(
            quote: "QUOTED\n  text continues here",
            lines: ["Earlier text", "The quoted text", "", " continues\there and ends.", "Later text"]
        ), [.init(line: 1, range: NSRange(location: 4, length: 11)),
            .init(line: 3, range: NSRange(location: 1, length: 14))])
        XCTAssertEqual(HighlightMatcher.matchedRanges(
            quote: "In the following sections, we describe self-attention.",
            lines: ["Earlier text", "In the follow-", "ing sections, we describe self-", "attention."]
        ), [.init(line: 1, range: NSRange(location: 0, length: 14)),
            .init(line: 2, range: NSRange(location: 0, length: 31)),
            .init(line: 3, range: NSRange(location: 0, length: 10))])
        let wrapped = "follow-\r\ning"
        let paragraph = "First the " + wrapped + " sections."
        XCTAssertEqual(HighlightMatcher.matchedRanges(quote: "following", lines: [paragraph]),
                       [.init(line: 0, range: (paragraph as NSString).range(of: wrapped))])
        let selected = "efﬁcient   model’s lay\u{00AD}ers"
        let original = " 📘 cafe\u{301}  " + selected + " ﬁnish"
        XCTAssertEqual(HighlightMatcher.matchedRanges(
            quote: "efficient model's layers", lines: [original]
        ), [.init(line: 0, range: (original as NSString).range(of: selected))])
        XCTAssertEqual(HighlightMatcher.matchedRanges(
            quote: "inish", lines: [original]
        ), [.init(line: 0, range: (original as NSString).range(of: "ﬁnish"))])
        XCTAssertEqual(HighlightMatcher.matchedRanges(
            quote: "a quote", lines: ["Native text without the quote"], fallbackLines: ["Earlier text", "Just a quote here"]
        ), [.init(line: 2, range: NSRange(location: 5, length: 7))])
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
