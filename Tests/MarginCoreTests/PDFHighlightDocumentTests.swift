import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Margin

final class PDFHighlightDocumentTests: XCTestCase {
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
            context.endPDFPage()
        }
        context.closePDF()
        let original = data as Data
        XCTAssertEqual(PDFHighlightDocument.annotated(original, quotes: ["repeated", "missing"]), original)

        let form = try XCTUnwrap(PDFDocument(data: original))
        let field = PDFAnnotation(bounds: CGRect(x: 30, y: 60, width: 180, height: 24),
                                  forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "Reader notes"
        try XCTUnwrap(form.page(at: 0)).addAnnotation(field)
        let formBytes = try XCTUnwrap(form.dataRepresentation())
        XCTAssertNil(PDFHighlightDocument.annotated(formBytes, quotes: ["first line"]))
        XCTAssertNil(PDFHighlightDocument.annotated(formBytes, quotes: []))

        let result = try XCTUnwrap(PDFHighlightDocument.annotated(original, quotes: ["first line next line", "repeated"]))
        let document = try XCTUnwrap(PDFDocument(data: result))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertEqual(document.page(at: 1)?.annotations.count, 0)
        let annotation = try XCTUnwrap(page.annotations.first)
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
