import ApplicationServices
import Foundation

/// A reading position sampled from Chrome's PDF accessibility tree in screen points.
struct PDFReadingPosition {
    let pageNumber: Int
    let zoomPercent: Int
    private let viewer: AXUIElement
    private let lines: [String: CGRect]

    static func current(in window: AXUIElement, excluding previous: Self? = nil) -> Self? {
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
        return read(viewers[0])
    }

    func refreshed() -> Self? { Self.read(viewer) }

    /// Positive offsets mean the candidate's text lies farther right or down.
    func displacement(from original: Self) -> CGSize? {
        guard pageNumber == original.pageNumber, zoomPercent == original.zoomPercent else { return nil }
        var offset: CGSize?
        var firstCenter: CGPoint?
        var separateLines = false
        for (line, rect) in lines {
            guard let reference = original.lines[line] else { continue }
            guard abs(rect.width - reference.width) <= 1, abs(rect.height - reference.height) <= 1 else { return nil }
            let delta = CGSize(width: rect.minX - reference.minX, height: rect.minY - reference.minY)
            if let offset {
                guard abs(offset.width - delta.width) <= 1, abs(offset.height - delta.height) <= 1 else { return nil }
            } else {
                offset = delta
            }
            if let firstCenter {
                if abs(firstCenter.y - reference.midY) > reference.height { separateLines = true }
            } else {
                firstCenter = CGPoint(x: reference.midX, y: reference.midY)
            }
        }
        return separateLines ? offset : nil
    }

    private static func read(_ viewer: AXUIElement) -> Self? {
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
              pageNumbers.count == 1, zoomLevels.count == 1,
              let page = pages[pageNumbers[0]] else { return nil }

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
        return Self(pageNumber: pageNumbers[0], zoomPercent: zoomLevels[0], viewer: viewer, lines: lines)
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
