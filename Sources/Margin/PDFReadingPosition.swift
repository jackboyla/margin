import ApplicationServices
import Foundation
import MarginCore
import PDFKit

/// A reading position sampled from Chrome's PDF accessibility tree in screen points.
struct PDFReadingPosition {
    let pageNumber: Int
    let zoomPercent: Int
    private let viewer: AXUIElement
    private let lines: [String: CGRect]

    static func current(in window: AXUIElement, excluding previous: Self? = nil, at point: CGPoint? = nil) -> Self? {
        var viewers: [AXUIElement] = []
        guard walk(window, reading: ["AXURL"], visit: { node, attributes in
            if attributes[0] as? String == "AXWebArea",
               let address = (attributes[2] as? URL)?.absoluteString ?? (attributes[2] as? String),
               address == "chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/index.html" {
                if previous.map({ !CFEqual($0.viewer, node) }) ?? true { viewers.append(node) }
                return false
            }
            return true
        }), viewers.count == 1 else { return nil }
        guard let point else { return read(viewers[0]) }
        var pid: pid_t = 0
        var hit: AXUIElement?
        guard AXUIElementGetPid(window, &pid) == .success,
              AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        return read(viewers[0], hit: hit)
    }

    func sharesViewer(with other: Self) -> Bool { CFEqual(viewer, other.viewer) }

    func refreshed() -> Self? { Self.read(viewer) }

    /// Positive offsets mean the candidate's text lies farther right or down.
    func displacement(from original: Self) -> CGSize? {
        guard pageNumber == original.pageNumber, zoomPercent == original.zoomPercent else { return nil }
        return Self.lineDisplacement(lines, from: original.lines)
    }

    static func lineDisplacement(_ lines: [String: CGRect], from original: [String: CGRect]) -> CGSize? {
        // Chrome can split links into different accessibility runs in two views of the same PDF.
        let samples = lines.compactMap { line, rect -> (shift: CGSize, reference: CGRect)? in
            guard let reference = original[line],
                  abs(rect.width - reference.width) <= 1, abs(rect.height - reference.height) <= 1,
                  rect.width > 1, rect.height > 1 else { return nil }
            return (CGSize(width: rect.minX - reference.minX, height: rect.minY - reference.minY), reference)
        }
        guard samples.count >= 3 else { return nil }
        let middle = samples.count / 2
        let shift = CGSize(width: samples.map { $0.shift.width }.sorted()[middle],
                           height: samples.map { $0.shift.height }.sorted()[middle])
        let agreeing = samples.filter { abs($0.shift.width - shift.width) <= 1 && abs($0.shift.height - shift.height) <= 1 }
        guard agreeing.count >= 3, agreeing.count * 4 >= samples.count * 3,
              let top = agreeing.map({ $0.reference.maxY }).min(),
              let bottom = agreeing.map({ $0.reference.minY }).max(), bottom > top else { return nil }
        return shift
    }

    private static func read(_ viewer: AXUIElement, hit: AXUIElement? = nil) -> Self? {
        var pageNumbers: [Int] = [], zoomLevels: [Int] = []
        var pages: [Int: AXUIElement] = [:]
        var duplicatePage = false
        var editControls: [String: Bool] = [:]
        guard walk(viewer, reading: [kAXTitleAttribute, kAXValueAttribute, kAXEnabledAttribute, kAXDescriptionAttribute], visit: { node, attributes in
            let role = attributes[0] as? String
            let label = attributes[2] as? String ?? ""
            let title = label.isEmpty ? (attributes[5] as? String ?? "") : label
            // Chrome keeps its undo history after the drawing toolbar closes.
            if ["Draw", "Add text annotations"].contains(title), role == kAXCheckBoxRole || role == kAXButtonRole {
                let inactive = (attributes[3] as? NSNumber)?.intValue == 0
                editControls[title] = (editControls[title] ?? true) && inactive
            }
            if ["Undo", "Redo"].contains(title), role == kAXButtonRole {
                let disabled = (attributes[4] as? NSNumber)?.boolValue == false
                editControls[title] = (editControls[title] ?? true) && disabled
            }
            if role == kAXTextFieldRole, let value = attributes[3] as? String {
                if title == "Page number", let number = Int(value), number > 0 { pageNumbers.append(number) }
                if title == "Zoom level", value.hasSuffix("%"), let zoom = Int(value.dropLast()), zoom > 0 {
                    zoomLevels.append(zoom)
                }
            }
            if role == kAXGroupRole, title.hasPrefix("Page "), let number = Int(title.dropFirst(5)) {
                if pages.updateValue(node, forKey: number) != nil { duplicatePage = true }
                return false
            }
            return true
        }), !duplicatePage, editControls["Draw"] == true, editControls["Undo"] == true,
              editControls["Redo"] == true, editControls["Add text annotations"] != false,
              pageNumbers.count == 1, zoomLevels.count == 1 else { return nil }

        var pageNumber = pageNumbers[0]
        if let hit {
            var ancestor = hit
            var matched: Int?
            for _ in 0..<32 {
                if let entry = pages.first(where: { CFEqual($0.value, ancestor) }) {
                    matched = entry.key
                    break
                }
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(ancestor, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                ancestor = unsafeBitCast(parent, to: AXUIElement.self)
            }
            guard let matched else { return nil }
            pageNumber = matched
        }
        guard let page = pages[pageNumber] else { return nil }

        var lines: [String: CGRect] = [:]
        var seen: Set<String> = []
        guard walk(page, reading: [kAXValueAttribute], visit: { node, attributes in
            guard attributes[0] as? String == kAXStaticTextRole, let text = attributes[2] as? String else { return true }
            let string = text as NSString
            var start = 0
            while start < string.length {
                var end = 0, contentEnd = 0
                string.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: start, length: 0))
                guard end > start else { break }
                let range = NSRange(location: start, length: contentEnd - start)
                let line = string.substring(with: range)
                if range.length > 3 {
                    if seen.insert(line).inserted {
                        lines[line] = bounds(node, range: range)
                    } else {
                        lines.removeValue(forKey: line)
                    }
                }
                start = end
            }
            return false
        }), lines.count >= 2 else { return nil }
        return Self(pageNumber: pageNumber, zoomPercent: zoomLevels[0], viewer: viewer, lines: lines)
    }

    func stickyAnchor(at point: CGPoint, in bytes: Data) -> StickyAnchor? {
        guard let document = PDFDocument(data: bytes), let pages = PDFHighlightDocument.annotatablePages(in: document),
              pageNumber > 0, pageNumber <= pages.count else { return nil }
        let page = pages[pageNumber - 1]
        guard page.rotation == 0, let string = page.string else { return nil }
        let text = string as NSString
        // Chrome clips page-group frames to the viewport. Its text-range bounds stay in full screen coordinates.
        let samples = lines.compactMap { line, screen -> (paper: CGRect, screen: CGRect)? in
            let match = text.range(of: line, options: .literal)
            guard screen.width > 1, match.location != NSNotFound, NSMaxRange(match) <= page.numberOfCharacters,
                  match == text.range(of: line, options: [.literal, .backwards]),
                  let selection = page.selection(for: match) else { return nil }
            let rect = selection.bounds(for: page)
            guard rect.width >= 36, rect.height > 0, !rect.isInfinite else { return nil }
            return (rect, screen)
        }
        return Self.stickyAnchor(at: point, page: pageNumber, crop: page.bounds(for: .cropBox), samples: samples)
    }

    static func stickyAnchor(at point: CGPoint, page: Int, crop: CGRect,
                             samples: [(paper: CGRect, screen: CGRect)]) -> StickyAnchor? {
        guard samples.count >= 3, !crop.isEmpty, !crop.isInfinite else { return nil }
        let middle = samples.count / 2
        let scale = samples.map { $0.screen.width / $0.paper.width }.sorted()[middle]
        guard scale.isFinite, scale > 0 else { return nil }
        let origins = samples.map {
            CGPoint(x: $0.screen.midX - scale * ($0.paper.midX - crop.minX),
                    y: $0.screen.midY - scale * (crop.maxY - $0.paper.midY))
        }
        let origin = CGPoint(x: origins.map(\.x).sorted()[middle], y: origins.map(\.y).sorted()[middle])
        // PDFKit and PDFium round glyph bounds differently. Require agreement across separate lines.
        let tolerance = max(2, 3 * scale)
        let agreeing = samples.indices.filter {
            abs(origins[$0].x - origin.x) <= tolerance && abs(origins[$0].y - origin.y) <= tolerance
        }
        guard agreeing.count >= 3, agreeing.count * 2 > samples.count,
              let top = agreeing.map({ samples[$0].paper.midY }).max(),
              let bottom = agreeing.map({ samples[$0].paper.midY }).min(), top - bottom > 24 else { return nil }
        let x = (point.x - origin.x) / (crop.width * scale)
        let y = (point.y - origin.y) / (crop.height * scale)
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return StickyAnchor(x: x, y: y, page: page)
    }

    private static func bounds(_ node: AXUIElement, range: NSRange) -> CGRect? {
        var span = CFRange(location: range.location, length: range.length)
        var value: CFTypeRef?
        guard let parameter = AXValueCreate(.cfRange, &span),
              AXUIElementCopyParameterizedAttributeValue(node, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                        parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgRect, &rect),
              !rect.isInfinite, !rect.isEmpty else { return nil }
        return rect
    }

    // Batch each node's attributes into a single IPC. Stop at viewer or page boundaries.
    private static func walk(_ root: AXUIElement, reading extra: [String], visit: (AXUIElement, [Any]) -> Bool) -> Bool {
        let names = [kAXRoleAttribute, kAXChildrenAttribute] + extra
        var queue = [root]
        var index = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while index < queue.count {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            let node = queue[index]
            index += 1
            var result: CFArray?
            AXUIElementSetMessagingTimeout(node, 0.1)
            guard AXUIElementCopyMultipleAttributeValues(node, names as CFArray, [], &result) == .success,
                  let attributes = result as? [Any], attributes.count == names.count else { return false }
            if visit(node, attributes), let children = attributes[1] as? [AXUIElement] {
                guard queue.count + children.count <= 3000 else { return false }
                queue.append(contentsOf: children)
            }
        }
        return true
    }
}
