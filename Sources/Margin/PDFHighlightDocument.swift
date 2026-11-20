import AppKit
import CoreText
import Foundation
import JavaScriptCore
import MarginCore
import PDFKit

enum PDFHighlightDocument {
    /// PDF incremental update to append to the original bytes. An empty update leaves all source objects intact.
    static func annotationUpdate(for original: Data, quotes: [String], notes: [StickyNote] = []) -> Data? {
        guard let document = PDFDocument(data: original), !document.isLocked,
              let catalog = document.documentRef?.catalog else { return nil }
        // Form values belong to the live viewer and may differ from the downloaded file.
        var form: CGPDFObjectRef?
        guard !CGPDFDictionaryGetObject(catalog, "AcroForm", &form) else { return nil }

        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        guard pages.count == document.pageCount,
              !pages.contains(where: { $0.annotations.contains(where: { $0.type == "Widget" }) })
        else { return nil }
        guard !quotes.isEmpty || !notes.isEmpty else { return Data() }
        let text = quotes.isEmpty ? [] : pages.map { $0.string ?? "" }
        var annotations: [[String: Any]] = []

        for quote in Set(quotes) {
            let matches = HighlightMatcher.matchedRanges(quote: quote, lines: text)
            guard !matches.isEmpty else { continue }
            var selected: [String] = []
            var markup: [[String: Any]] = []

            for match in matches {
                let page = pages[match.line]
                guard NSMaxRange(match.range) <= page.numberOfCharacters,
                      let selection = page.selection(for: match.range),
                      let passage = selection.string else { break }
                let lines = selection.selectionsByLine().map { $0.bounds(for: page) }
                guard !lines.isEmpty, lines.allSatisfy({ !$0.isEmpty && !$0.isInfinite }) else { break }
                let bounds = lines.reduce(CGRect.null) { $0.union($1) }
                let points = lines.flatMap { rect in
                    [rect.minX, rect.maxY, rect.maxX, rect.maxY, rect.minX, rect.minY, rect.maxX, rect.minY]
                }
                selected.append(passage)
                markup.append(["page": match.line, "bounds": [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY],
                               "quadPoints": points])
            }

            // Compatibility normalization can match part of a single glyph, such as ⅓.
            // Check PDFKit's actual selection before painting any part of this quote.
            guard markup.count == matches.count,
                  words(selected.joined(separator: " ")) == words(quote) else { continue }
            annotations.append(contentsOf: markup)
        }

        for note in notes {
            guard let number = note.anchor.page, number > 0, number <= pages.count,
                  (0...1).contains(note.anchor.x), (0...1).contains(note.anchor.y) else { continue }
            let page = pages[number - 1]
            guard page.rotation == 0, let mark = stickyAnnotation(note, on: page.bounds(for: .cropBox)) else { continue }
            annotations.append(mark)
        }

        guard !annotations.isEmpty else { return Data() }
        guard let library, let writer, let context = JSContext() else { return nil }
        context.evaluateScript(library)
        context.evaluateScript(writer)
        guard context.exception == nil, let function = context.objectForKeyedSubscript("highlightIncrement"),
              let promise = function.call(withArguments: [original.base64EncodedString(), annotations]) else { return nil }
        context.setObject(promise, forKeyedSubscript: "increment" as NSString)
        context.evaluateScript("var encoded; increment.then(value => { encoded = value }, () => {});")
        guard let value = context.objectForKeyedSubscript("encoded"), value.isString,
              let base64 = value.toString(), let suffix = Data(base64Encoded: base64), !suffix.isEmpty else { return nil }
        return suffix
    }

    private static func stickyAnnotation(_ note: StickyNote, on crop: CGRect) -> [String: Any]? {
        guard crop.width > 16, crop.height > 16, !crop.isInfinite, let number = note.anchor.page else { return nil }
        // Draw with the system fonts so the saved appearance includes glyphs outside PDF's standard fonts.
        let text = NSAttributedString(string: note.text, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                     .foregroundColor: NSColor.black])
        let layout = CTFramesetterCreateWithAttributedString(text)
        let width = min(160, crop.width)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(layout, CFRange(), nil,
            CGSize(width: width - 12, height: .greatestFiniteMagnitude), nil)
        let height = min(max(26, ceil(size.height) + 12), crop.height)
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0.94, blue: 0.65, alpha: 1))
        context.fill(box)
        let path = CGPath(rect: box.insetBy(dx: 6, dy: 6), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(layout, CFRange(), path, nil), context)
        context.endPDFPage()
        context.closePDF()

        let left = min(crop.minX + note.anchor.x * crop.width, crop.maxX - width)
        let top = max(crop.maxY - note.anchor.y * crop.height, crop.minY + height)
        return ["page": number - 1, "bounds": [left, top - height, left + width, top],
                "text": note.text, "id": note.id.uuidString, "appearance": (data as Data).base64EncodedString()]
    }

    private static let library = MarginResources.script("pdf-lib.min", in: "PDFWriter")
    private static let writer = MarginResources.script("annotations", in: "PDFWriter")

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }
}
