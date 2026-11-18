import Foundation
import JavaScriptCore
import MarginCore
import PDFKit

enum PDFHighlightDocument {
    /// PDF incremental update to append to the original bytes. An empty update leaves all source objects intact.
    static func annotationUpdate(for original: Data, quotes: [String]) -> Data? {
        guard let document = PDFDocument(data: original), !document.isLocked,
              let catalog = document.documentRef?.catalog else { return nil }
        // Form values belong to the live viewer and may differ from the downloaded file.
        var form: CGPDFObjectRef?
        guard !CGPDFDictionaryGetObject(catalog, "AcroForm", &form) else { return nil }

        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        guard pages.count == document.pageCount,
              !pages.contains(where: { $0.annotations.contains(where: { $0.type == "Widget" }) })
        else { return nil }
        guard !quotes.isEmpty else { return Data() }
        let text = pages.map { $0.string ?? "" }
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

    private static let library = MarginResources.script("pdf-lib.min", in: "PDFWriter")
    private static let writer = MarginResources.script("annotations", in: "PDFWriter")

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }
}
