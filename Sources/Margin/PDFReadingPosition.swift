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
    private let edges: PageEdges?

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
        return read(viewers[0], hit: (hit, point))
    }

    func sharesViewer(with other: Self) -> Bool { CFEqual(viewer, other.viewer) }

    func refreshed() -> Self? { Self.read(viewer) }

    /// Positive offsets mean the candidate's text lies farther right or down.
    func displacement(from original: Self, crop: CGRect?) -> CGSize? {
        guard pageNumber == original.pageNumber, zoomPercent == original.zoomPercent else { return nil }
        if let shift = Self.lineDisplacement(lines, from: original.lines) { return shift }
        // Pages with few text landmarks can still have directly comparable paper edges.
        guard lines.count < 3 || original.lines.count < 3, let crop,
              let current = edges?.fullFrame(for: crop), let prior = original.edges?.fullFrame(for: crop),
              abs(current.width - prior.width) <= 1 else { return nil }
        let shift = CGSize(width: current.minX - prior.minX, height: current.minY - prior.minY)
        let landmarks = lines.compactMap { line, rect -> (CGPoint, CGPoint)? in
            guard let reference = original.lines[line] else { return nil }
            return (CGPoint(x: reference.midX + shift.width, y: reference.midY + shift.height),
                    CGPoint(x: rect.midX, y: rect.midY))
        }
        return Self.confirmsOrientation(landmarks, in: current, tolerance: 1) ? shift : nil
    }

    /// The toolbar rounds zoom to a whole percent. Match the actual size of the same page in both viewers.
    func zoomCorrection(to original: Self) -> CGFloat? {
        guard pageNumber == original.pageNumber else { return nil }
        if let current = edges?.visible.width, let target = original.edges?.visible.width {
            return target / current
        }
        return Self.lineScale(lines, to: original.lines)
    }

    static func lineScale(_ lines: [String: CGRect], to original: [String: CGRect]) -> CGFloat? {
        let widths = lines.compactMap { line, rect -> (current: CGFloat, target: CGFloat)? in
            guard let reference = original[line], min(rect.width, reference.width) >= 36 else { return nil }
            return (rect.width, reference.width)
        }
        guard widths.count >= 3 else { return nil }
        let median = widths.map { $0.target / $0.current }.sorted()[widths.count / 2]
        // A link can split a line differently in the staged viewer. Average matching widths to reduce pixel rounding.
        let agreeing = widths.filter { abs($0.current * median - $0.target) <= 2 }
        guard agreeing.count >= 3, agreeing.count * 4 >= widths.count * 3 else { return nil }
        return agreeing.reduce(0) { $0 + $1.target } / agreeing.reduce(0) { $0 + $1.current }
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

    static func canReplaceViewer(editControls: [String: Bool]) -> Bool {
        // Chrome omits the entire ink toolbar when its PDF annotation feature is disabled.
        editControls.isEmpty || (editControls["Draw"] == true && editControls["Undo"] == true &&
                                 editControls["Redo"] == true && editControls.values.allSatisfy { $0 })
    }

    private static func read(_ viewer: AXUIElement, hit: (element: AXUIElement, point: CGPoint)? = nil) -> Self? {
        var pageNumbers: [Int] = [], zoomLevels: [Int] = []
        var pages: [Int: AXUIElement] = [:]
        var duplicatePage = false
        var editControls: [String: Bool] = [:]
        guard walk(viewer, reading: [kAXTitleAttribute, kAXValueAttribute, kAXEnabledAttribute, kAXDescriptionAttribute], visit: { node, attributes in
            let role = attributes[0] as? String
            let label = attributes[2] as? String ?? ""
            let title = label.isEmpty ? (attributes[5] as? String ?? "") : label
            // Chrome keeps its undo history after the drawing toolbar closes.
            if ["Draw", "Add text annotations", "Add signature"].contains(title), role == kAXCheckBoxRole || role == kAXButtonRole {
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
        }), !duplicatePage, canReplaceViewer(editControls: editControls),
              pageNumbers.count == 1, zoomLevels.count == 1 else { return nil }

        var pageNumber = pageNumbers[0]
        if let hit {
            // Chrome can hit the plugin's document container even over text or blank paper.
            let matches = pages.filter { _, page in
                guard let rect = frame(page), rect.width > 1, rect.height > 1 else { return false }
                return rect.contains(hit.point)
            }
            guard matches.count == 1, let matched = matches.first else { return nil }
            pageNumber = matched.key
        }
        guard let page = pages[pageNumber] else { return nil }
        // The innermost web area is the PDF plugin, below the toolbar and beside the sidebar.
        let plugin = firstAncestor(of: page) { ancestor in
            var role: CFTypeRef?
            return AXUIElementCopyAttributeValue(ancestor, kAXRoleAttribute as CFString, &role) == .success &&
                role as? String == "AXWebArea"
        }
        if let hit {
            guard let plugin, !CFEqual(plugin, viewer),
                  firstAncestor(of: hit.element, where: { CFEqual($0, plugin) }) != nil else { return nil }
        }
        let edges = PageEdges(visible: frame(page) ?? .null, viewport: plugin.flatMap(frame) ?? .null)

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
        }) else { return nil }
        return Self(pageNumber: pageNumber, zoomPercent: zoomLevels[0], viewer: viewer, lines: lines, edges: edges)
    }

    func stickyAnchor(at point: CGPoint, in bytes: Data) -> StickyAnchor? {
        guard let document = PDFDocument(data: bytes), let pages = PDFHighlightDocument.annotatablePages(in: document),
              pageNumber > 0, pageNumber <= pages.count else { return nil }
        let page = pages[pageNumber - 1]
        guard page.rotation == 0 else { return nil }
        let crop = page.bounds(for: .cropBox)
        let text = (page.string ?? "") as NSString
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
        if let edges, let full = edges.fullFrame(for: crop), edges.visible.contains(point), full.contains(point) {
            // A rotated viewer can have the same page bounds. Verify its orientation against any available text.
            let scale = full.width / crop.width
            let tolerance = max(3, 4 * scale)
            let landmarks = samples.map {
                (CGPoint(x: full.minX + scale * ($0.paper.midX - crop.minX),
                         y: full.minY + scale * (crop.maxY - $0.paper.midY)),
                 CGPoint(x: $0.screen.midX, y: $0.screen.midY))
            }
            if Self.confirmsOrientation(landmarks, in: full, tolerance: tolerance) {
                return StickyAnchor(x: (point.x - full.minX) / full.width,
                                    y: (point.y - full.minY) / full.height, page: pageNumber)
            }
        }
        return Self.stickyAnchor(at: point, page: pageNumber, crop: crop, samples: samples)
    }

    static func confirmsOrientation(_ landmarks: [(CGPoint, CGPoint)], in frame: CGRect, tolerance: CGFloat) -> Bool {
        // A centered heading can stay in place even after a half turn.
        let offCenter = landmarks.filter { expected, _ in
            max(abs(expected.x - frame.midX), abs(expected.y - frame.midY)) > 2 * tolerance
        }
        let aligned = offCenter.filter { expected, actual in
            abs(expected.x - actual.x) <= tolerance && abs(expected.y - actual.y) <= tolerance
        }
        return aligned.count * 2 > offCenter.count
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

    struct PageEdges {
        let visible: CGRect
        let top: CGFloat?
        let bottom: CGFloat?

        init?(visible: CGRect, viewport: CGRect) {
            // Chrome clips its accessibility frames. An edge at the viewport boundary may be offscreen.
            guard !visible.isEmpty, !viewport.isEmpty, visible.minX > viewport.minX + 1,
                  visible.maxX < viewport.maxX - 1 else { return nil }
            self.visible = visible
            top = visible.minY > viewport.minY + 1 ? visible.minY : nil
            bottom = visible.maxY < viewport.maxY - 1 ? visible.maxY : nil
        }

        func fullFrame(for crop: CGRect) -> CGRect? {
            guard !crop.isEmpty, !crop.isInfinite else { return nil }
            let height = visible.width * crop.height / crop.width
            guard visible.height <= height + 2 else { return nil }
            if top != nil, bottom != nil { return abs(visible.height - height) <= 2 ? visible : nil }
            guard let y = top ?? bottom.map({ $0 - height }) else { return nil }
            return CGRect(x: visible.minX, y: y, width: visible.width, height: height)
        }
    }

    private static func firstAncestor(of node: AXUIElement, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var ancestor = node
        for _ in 0..<32 {
            if matches(ancestor) { return ancestor }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ancestor, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            ancestor = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return nil
    }

    private static func frame(_ node: AXUIElement) -> CGRect? {
        let keys = [kAXPositionAttribute, kAXSizeAttribute]
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(node, keys as CFArray, [], &result) == .success,
              let values = result as? [AXValue], values.count == 2 else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetType(values[0]) == .cgPoint, AXValueGetType(values[1]) == .cgSize,
              AXValueGetValue(values[0], .cgPoint, &origin), AXValueGetValue(values[1], .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
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
