import AppKit
import CoreText
import JavaScriptCore
import PDFKit
import XCTest
@testable import Margin

final class PDFHighlightDocumentTests: XCTestCase {
    @MainActor
    func testDeletionWaitsForConfirmationFromTheVisiblePDF() async throws {
        let painter = ChromePDFHighlights()
        let paper = try XCTUnwrap(URL(string: "https://arxiv.org/pdf/2506.01844"))
        var status = "different"
        func reconcile() async throws -> BrowserHighlightState {
            try await painter.paint(paper: paper, quotes: [], isCurrent: { true }) { request, _ in
                XCTAssertEqual(request["action"] as? String, "status")
                return status
            } position: { _ in nil }
        }

        let waiting = try await reconcile()
        XCTAssertEqual(waiting, .deferred)
        status = "active"
        let confirmed = try await reconcile()
        XCTAssertEqual(confirmed, .current)
    }

    func testReadingPositionRequiresAgreementAcrossLines() {
        let original: [String: CGRect] = [
            "heading": CGRect(x: 90, y: 100, width: 130, height: 20),
            "body": CGRect(x: 90, y: 160, width: 240, height: 20),
            "caption": CGRect(x: 90, y: 220, width: 110, height: 16),
            "reference": CGRect(x: 430, y: 220, width: 50, height: 16),
            "wrapped link": CGRect(x: 90, y: 280, width: 320, height: 20)
        ]
        var staged = original.mapValues { $0.offsetBy(dx: 0, dy: 447) }
        staged["reference"]?.origin.x += 1011
        staged["wrapped link"]?.size.width -= 6
        XCTAssertEqual(PDFReadingPosition.lineDisplacement(staged, from: original), CGSize(width: 0, height: 447))
        staged["caption"]?.origin.y += 40
        XCTAssertNil(PDFReadingPosition.lineDisplacement(staged, from: original))
    }

    func testOnlySelectedWordsOnEachLineReceiveMarkup() throws {
        let data = NSMutableData()
        var size = CGRect(x: 0, y: 0, width: 480, height: 560)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &size, nil))
        for lines in [["prefix first line", "next line suffix", "repeated"], ["repeated"]] {
            context.beginPDFPage(nil)
            for (index, line) in lines.enumerated() {
                context.textPosition = CGPoint(x: 32, y: 420 - index * 24)
                let attributed = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 14)])
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            if lines.count > 1 {
                context.setURL(URL(string: "https://arxiv.org")! as CFURL, for: CGRect(x: 30, y: 310, width: 75, height: 18))
            }
            context.endPDFPage()
        }
        context.closePDF()
        let original = data as Data
        XCTAssertEqual(PDFHighlightDocument.annotationUpdate(for: original, quotes: ["repeated", "missing"]), Data())

        // Exercise a compressed cross-reference stream as well as CoreGraphics' classic table.
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(try XCTUnwrap(MarginResources.script("pdf-lib.min", in: "PDFWriter")))
        js.setObject(original.base64EncodedString(), forKeyedSubscript: "source" as NSString)
        js.evaluateScript("""
            var compressed;
            PDFLib.PDFDocument.load(source, {parseSpeed: Infinity}).then(document =>
                document.saveAsBase64({useObjectStreams: true, objectsPerTick: Infinity})
            ).then(bytes => { compressed = bytes });
            """)
        let encoded = try XCTUnwrap(js.objectForKeyedSubscript("compressed")?.toString())
        let compressed = try XCTUnwrap(Data(base64Encoded: encoded))
        let update = try XCTUnwrap(PDFHighlightDocument.annotationUpdate(for: compressed, quotes: ["first line"]))
        let compressedPage = try XCTUnwrap(PDFDocument(data: compressed + update)?.page(at: 0))
        XCTAssertEqual(compressedPage.annotations.filter { $0.type == "Highlight" }.count, 1)

        let form = try XCTUnwrap(PDFDocument(data: original))
        let field = PDFAnnotation(bounds: CGRect(x: 30, y: 60, width: 180, height: 24),
                                  forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "Reader notes"
        try XCTUnwrap(form.page(at: 0)).addAnnotation(field)
        let formBytes = try XCTUnwrap(form.dataRepresentation())
        XCTAssertNil(PDFHighlightDocument.annotationUpdate(for: formBytes, quotes: ["first line"]))
        XCTAssertNil(PDFHighlightDocument.annotationUpdate(for: formBytes, quotes: []))

        let result = original + (try XCTUnwrap(PDFHighlightDocument.annotationUpdate(for: original, quotes: ["first line next line", "repeated"])))
        let document = try XCTUnwrap(PDFDocument(data: result))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.annotations.count, 2)
        XCTAssertEqual(page.annotations.first(where: { $0.type == "Link" })?.url?.host, "arxiv.org")
        XCTAssertEqual(document.page(at: 1)?.annotations.count, 0)
        let annotation = try XCTUnwrap(page.annotations.first(where: { $0.type == "Highlight" }))
        let points = try XCTUnwrap(annotation.quadrilateralPoints)
        XCTAssertEqual(points.count, 8)
        guard points.count == 8 else { return }
        for (index, phrase) in ["first line", "next line"].enumerated() {
            let selection = try XCTUnwrap(document.findString(phrase, withOptions: []).first)
            let expected = selection.bounds(for: page)
            let upperLeft = points[index * 4].pointValue
            let lowerRight = points[index * 4 + 3].pointValue
            XCTAssertEqual(upperLeft.x + annotation.bounds.minX, expected.minX, accuracy: 1)
            XCTAssertEqual(upperLeft.y + annotation.bounds.minY, expected.maxY, accuracy: 1)
            XCTAssertEqual(lowerRight.x + annotation.bounds.minX, expected.maxX, accuracy: 1)
            XCTAssertEqual(lowerRight.y + annotation.bounds.minY, expected.minY, accuracy: 1)
        }
    }
}
