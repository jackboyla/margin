import XCTest
@testable import MarginCore

final class SourceIdentityTests: XCTestCase {
    private func identity(_ url: String?, bundleID: String = "com.apple.Safari", title: String = "Paper") -> String {
        SourceIdentity.documentID(bundleID: bundleID, title: title, url: url)
    }

    func testArxivFormatsShareIdentityWithoutMixingVersions() {
        let versioned = identity("https://arxiv.org/abs/2401.12345v2")
        XCTAssertEqual(identity("http://export.arxiv.org/pdf/2401.12345v2.pdf?utm_source=newsletter"), versioned)
        XCTAssertEqual(identity("https://arxiv.org/html/2401.12345v2"), versioned)
        XCTAssertNotEqual(identity("https://arxiv.org/abs/2401.12345v1"), versioned)
        XCTAssertNotEqual(identity("https://arxiv.org/abs/2401.12345"), versioned)
        XCTAssertEqual(identity("https://arxiv.org/pdf/hep-th/9901001v3.pdf"),
                       identity("https://arxiv.org/abs/hep-th/9901001v3"))
    }

    func testMeaningfulQueryAndFragmentRoutesRemainDistinct() {
        XCTAssertEqual(identity("https://EXAMPLE.com:443/read?id=7&utm_medium=email#section"),
                       identity("https://example.com/read?id=7#section"))
        XCTAssertNotEqual(identity("https://example.com/read?id=7"), identity("https://example.com/read?id=8"))
        XCTAssertNotEqual(identity("https://example.com/#/document/7"), identity("https://example.com/#/document/8"))
        XCTAssertNotEqual(identity("https://example.com/read?ref=chapter-a"), identity("https://example.com/read?ref=chapter-b"))
        XCTAssertNotEqual(identity("https://example.com/read"), identity("https://other.example/read"))
        XCTAssertEqual(identity("https://example.com/read", title: "Old title"),
                       identity("https://example.com/read", title: "New title"))
        XCTAssertEqual(identity("https://example.com/read?token=a%2Bb&utm_source=mail&filter=x%20y"),
                       identity("https://example.com/read?token=a%2Bb&filter=x%20y"))
    }

    func testWindowFallbackIncludesBothAppAndTitleWithoutSeparatorCollisions() {
        XCTAssertNotEqual(identity(nil, bundleID: "app.one"), identity(nil, bundleID: "app.two"))
        XCTAssertNotEqual(identity(nil, title: "First"), identity(nil, title: "Second"))
        XCTAssertNotEqual(identity(nil, bundleID: "a:b", title: "c"),
                          identity(nil, bundleID: "a", title: "b:c"))
        XCTAssertEqual(identity(""), identity(nil))
        XCTAssertEqual(identity("https:"), identity(nil))
    }
}
