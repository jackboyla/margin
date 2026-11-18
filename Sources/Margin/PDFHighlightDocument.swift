import AppKit
import MarginCore
import PDFKit

enum PDFHighlightDocument {
    /// Rebuild from the original bytes so removing a saved passage also removes its markup.
    static func annotated(_ original: Data, quotes: [String]) -> Data? {
        guard let document = PDFDocument(data: original), !document.isLocked,
              let catalog = document.documentRef?.catalog else { return nil }
        // Form values belong to the live viewer and may differ from the downloaded file.
        var form: CGPDFObjectRef?
        guard !CGPDFDictionaryGetObject(catalog, "AcroForm", &form) else { return nil }

        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        guard pages.count == document.pageCount,
              !pages.contains(where: { $0.annotations.contains(where: { $0.type == PDFAnnotationSubtype.widget.rawValue }) })
        else { return nil }
        guard !quotes.isEmpty else { return original }
        let text = pages.map { $0.string ?? "" }
        var modified = false

        for quote in Set(quotes) {
            let matches = HighlightMatcher.matchedRanges(quote: quote, lines: text)
            guard !matches.isEmpty else { continue }
            var selected: [String] = []
            var markup: [(PDFPage, PDFAnnotation)] = []

            for match in matches {
                let page = pages[match.line]
                guard NSMaxRange(match.range) <= page.numberOfCharacters,
                      let selection = page.selection(for: match.range),
                      let passage = selection.string else { break }
                let lines = selection.selectionsByLine().map { $0.bounds(for: page) }
                guard !lines.isEmpty, lines.allSatisfy({ !$0.isEmpty && !$0.isInfinite }) else { break }
                let bounds = lines.reduce(CGRect.null) { $0.union($1) }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.yellow.withAlphaComponent(0.4)
                annotation.quadrilateralPoints = lines.flatMap { line -> [NSValue] in
                    let rect = line.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                    return [
                        NSValue(point: CGPoint(x: rect.minX, y: rect.maxY)),
                        NSValue(point: CGPoint(x: rect.maxX, y: rect.maxY)),
                        NSValue(point: CGPoint(x: rect.minX, y: rect.minY)),
                        NSValue(point: CGPoint(x: rect.maxX, y: rect.minY))
                    ]
                }
                selected.append(passage)
                markup.append((page, annotation))
            }

            // Compatibility normalization can match part of a single glyph, such as ⅓.
            // Check PDFKit's actual selection before painting any part of this quote.
            guard markup.count == matches.count,
                  words(selected.joined(separator: " ")) == words(quote) else { continue }
            for (page, annotation) in markup { page.addAnnotation(annotation) }
            modified = true
        }

        return modified ? document.dataRepresentation() : original
    }

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }
}
