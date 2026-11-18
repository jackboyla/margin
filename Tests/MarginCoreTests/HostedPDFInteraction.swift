import AppKit
import ApplicationServices
import XCTest
@testable import Margin

final class HostedPDFInteraction: XCTestCase {
    @MainActor func testTwoPDFEdits() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MARGIN_HOSTED_INTERACTION"] == "1")
        let capture = WindowCapture()
        print("API-TRACE trusted", capture.accessibilityPermission)
        let target = try await capture.resolve(target: capture.currentTarget())
        print("API-TRACE target", target.bundleID, target.url ?? "")
        XCTAssertEqual(target.bundleID, "com.google.Chrome")
        let app = AXUIElementCreateApplication(target.pid)
        var value: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value), .success)
        let window = unsafeBitCast(try XCTUnwrap(value), to: AXUIElement.self)
        let before = try XCTUnwrap(PDFReadingPosition.current(in: window))
        print("API-TRACE baseline", before.pageNumber, before.zoomPercent)
        XCTAssertEqual(before.pageNumber, 4)
        let first = "the best features for downstream tasks"
        let second = "tradeoff between speed and performance"
        for (step, quotes) in [[first], [first, second], [second], []].enumerated() {
            let result = try await capture.paintBrowserHighlights(target: target, quotes: quotes, isCurrent: { true })
            XCTAssertTrue(result)
            let source = NSAppleScript(source: """
              tell application "Google Chrome" to execute active tab of front window javascript "document.querySelector('iframe[title=\\"PDF with saved highlights\\"]')?.src ?? ''"
            """)
            var error: NSDictionary?
            let src = source?.executeAndReturnError(&error).stringValue ?? ""
            print("API-TRACE after", step, src.prefix(95), error?.description ?? "")
            XCTAssertTrue(src.hasPrefix("blob:https://arxiv.org/"))
            let position = try XCTUnwrap(PDFReadingPosition.current(in: window))
            let delta = try XCTUnwrap(position.displacement(from: before))
            XCTAssertLessThanOrEqual(abs(delta.width), 1)
            XCTAssertLessThanOrEqual(abs(delta.height), 1)
            try String(src).write(toFile: "/tmp/margin-hosted-frame-\(step)", atomically: true, encoding: .utf8)
        }
    }
}
