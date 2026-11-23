import AppKit
import ApplicationServices
import Carbon
import MarginCore
import ScreenCaptureKit
import Vision
import os

struct WindowTarget: Sendable {
    let pid: pid_t
    let windowID: CGWindowID
    let appName: String
    let bundleID: String
    let title: String
    let url: String?
    /// Screen coordinates, with the origin at the top left of the main display.
    let frame: CGRect
    var identityResolved = false
}

// Vision candidates are immutable; their range queries run on recognitionQueue.
struct PositionedTextLine: @unchecked Sendable {
    let text: String
    /// Vision coordinates: normalized to the captured window, origin at bottom left.
    let bounds: CGRect
    var recognizedText: VNRecognizedText? = nil
}

struct CapturedWindow: Sendable {
    let context: SourceContext
    let target: WindowTarget
    let accessibleLines: [PositionedTextLine]
    let ocrLines: [PositionedTextLine]
    let warnings: [String]
    var image: CGImage? = nil
    var textAnchors: [AccessibleTextAnchor] = []
}

struct AccessibleTextAnchor: @unchecked Sendable {
    let element: AXUIElement
    let text: String
}

struct TrackedHighlights: @unchecked Sendable {
    let target: WindowTarget
    let anchors: [AccessibleTextAnchor]
    let matches: [HighlightMatcher.TextMatch]
    let recognizedRectangles: [CGRect]
    let hasUnmatchedQuotes: Bool
}

struct HighlightFrame: Sendable {
    let target: WindowTarget
    /// Screen coordinates, with the origin at the top left.
    let rectangles: [CGRect]
}

enum WindowCaptureError: LocalizedError {
    case noSourceWindow
    case sourceChanged
    case browserURLUnavailable
    case noReadableContent
    case selectionLoading
    case selectionAccessDenied

    var errorDescription: String? {
        switch self {
        case .noSourceWindow:
            return "Open a document in Chrome, Safari, or another app, then try the shortcut again."
        case .sourceChanged:
            return "The source window or page changed. Open Margin again from the page you want to use."
        case .browserURLUnavailable:
            return "Margin could not read this page’s URL. Allow \(WindowCapture.accessibilityPermissionName) and browser Automation access in System Settings, then try again."
        case .selectionLoading:
            return "This document’s text selection is still loading. Wait a moment, then try again."
        case .selectionAccessDenied:
            return "Enable \(WindowCapture.accessibilityPermissionName) for Margin in System Settings → Privacy & Security to read selected text."
        case .noReadableContent:
            return "Margin could not read this window. Allow \(WindowCapture.accessibilityPermissionName) or Screen Recording access in System Settings, then try again."
        }
    }
}

@MainActor
final class WindowCapture {
    nonisolated static var accessibilityPermissionName: String {
        if #available(macOS 27, *) { return "Device Control" }
        return "Accessibility"
    }

    private var lastTarget: WindowTarget?
    private nonisolated let recognitionQueue = DispatchQueue(label: "com.jackboylan.margin.capture", qos: .userInitiated)

    nonisolated var accessibilityPermission: Bool { AXIsProcessTrusted() }
    nonisolated var screenCapturePermission: Bool { CGPreflightScreenCaptureAccess() }

    func requireSelectionAccess() throws {
        guard accessibilityPermission else { throw WindowCaptureError.selectionAccessDenied }
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @discardableResult
    func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func prepareAccessibilityForFrontmostApplication() {
        guard accessibilityPermission, let app = NSWorkspace.shared.frontmostApplication,
              isChromiumBrowser(app.bundleIdentifier ?? "") else { return }
        let pid = app.processIdentifier
        recognitionQueue.async {
            _ = self.attribute(AXUIElementCreateApplication(pid), kAXRoleAttribute)
        }
    }

    func currentTarget() throws -> WindowTarget {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw WindowCaptureError.noSourceWindow
        }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            guard let lastTarget else { throw WindowCaptureError.noSourceWindow }
            return lastTarget
        }
        guard let window = frontWindow(pid: app.processIdentifier) else {
            throw WindowCaptureError.noSourceWindow
        }
        let target = WindowTarget(pid: app.processIdentifier, windowID: window.id,
                                  appName: app.localizedName ?? "Untitled window",
                                  bundleID: app.bundleIdentifier ?? "pid:\(app.processIdentifier)",
                                  title: window.title, url: nil, frame: window.frame)
        lastTarget = target
        return target
    }

    func resolve(target: WindowTarget, askForAutomation: Bool = false) async throws -> WindowTarget {
        // Margin can be frontmost while its last source window navigates to a different page.
        try await queued { try self.validatedSource(target, askForAutomation: askForAutomation, matchDocument: false).target }
    }

    private nonisolated static let highlightLog = Logger(subsystem: "com.jackboylan.margin", category: "BrowserHighlights")

    private nonisolated static let browserHighlightScript = MarginResources.script("BrowserHighlights")
    private nonisolated static let pdfViewportScript = MarginResources.script("PDFViewport")
    private nonisolated static let stickyScript = MarginResources.script("BrowserStickyNotes")
    private let pdfRenderer = ChromePDFHighlights()
    private var pdfAccessibilityRequest: (pid: pid_t, time: ContinuousClock.Instant)?

    private func pdfPosition(in target: WindowTarget, excluding previous: PDFReadingPosition? = nil,
                             at point: CGPoint? = nil) async throws -> PDFReadingPosition? {
        let clock = ContinuousClock()
        let app = AXUIElementCreateApplication(target.pid)
        func requestFullTree() async {
            pdfAccessibilityRequest = (target.pid, clock.now)
            // Chrome's basic tree can omit checkbox states and PDF text ranges.
            // It publishes the full tree about two seconds after this assistive-technology request.
            await Task.detached(priority: .userInitiated) {
                _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }.value
        }
        func sample() async throws -> PDFReadingPosition? {
            try await Task.detached(priority: .userInitiated) {
                guard let window = self.element(app, kAXFocusedWindowAttribute), self.matches(window, frame: target.frame)
                else { throw WindowCaptureError.sourceChanged }
                return PDFReadingPosition.current(in: window, excluding: previous, at: point)
            }.value
        }
        guard accessibilityPermission else { return nil }
        if pdfAccessibilityRequest?.pid != target.pid { await requestFullTree() }
        if let result = try await sample() { return result }
        guard previous == nil else { return nil }
        if let request = pdfAccessibilityRequest, clock.now >= request.time + .seconds(30) { await requestFullTree() }
        // Background painting already retries. A first note must keep the user's original point while Chrome wakes.
        if point != nil, let request = pdfAccessibilityRequest {
            while clock.now < request.time + .seconds(4) {
                try await Task.sleep(for: .milliseconds(250))
                if let result = try await sample() { return result }
            }
        }
        return nil
    }

    func releaseSelection(target: WindowTarget, quote: String) async throws -> (url: String, anchor: WebQuoteAnchor)? {
        guard isChromiumBrowser(target.bundleID), let url = target.url,
              let script = Self.browserHighlightScript else { return nil }
        let sourceID = "url:" + url
        let detailURL = SourceIdentity.gitHubReleaseURL(for: sourceID)
        guard detailURL != nil || SourceIdentity.isGitHubReleaseIndex(sourceID) else { return nil }
        let reply = try await browserCommand(target, template: script, request: ["action": "anchor", "url": url, "quote": quote])
        guard reply.status == "anchored", let releaseURL = reply.releaseURL,
              let canonical = SourceIdentity.gitHubReleaseURL(for: "url:" + releaseURL),
              canonical == detailURL || SourceIdentity.gitHubReleaseIndexContains("url:" + canonical, indexDocumentID: sourceID),
              let prefix = reply.prefix, let suffix = reply.suffix,
              prefix.utf8.count <= 1024, suffix.utf8.count <= 1024 else { return nil }
        return (canonical, WebQuoteAnchor(prefix: prefix, suffix: suffix))
    }

    func paintBrowserHighlights(target: WindowTarget, highlights: [Highlight], notes: [StickyNote] = [],
                                isCurrent: @escaping @MainActor () -> Bool) async throws -> BrowserHighlightState {
        guard isChromiumBrowser(target.bundleID), let url = target.url else { return .unsupported }
        let quotes = highlights.map(\.quote)
        if let paper = ChromePDFHighlights.paperURL(url) {
            guard let template = Self.pdfViewportScript else { return .unsupported }
            let paint = try await pdfRenderer.paint(paper: paper, quotes: quotes, notes: notes.filter { $0.anchor.page != nil }, isCurrent: isCurrent) { arguments, input in
                var request = arguments
                request["url"] = url
                return try await self.browserCommand(target, template: template, request: request, input: input).status
            } position: { excluding in
                try await self.pdfPosition(in: target, excluding: excluding)
            }
            if paint != .unsupported { return paint }
        }
        guard let template = Self.browserHighlightScript else { return .unsupported }
        var script = "(() => { window[Symbol.for('com.jackboylan.margin.stickyNotes')]?.dispose(); return " + template + "\n})()"
        var request: [String: Any] = ["url": url, "quotes": quotes]
        if highlights.contains(where: { $0.webAnchor != nil || SourceIdentity.gitHubReleaseURL(for: $0.documentID) != nil }) {
            request["passages"] = highlights.map { highlight in
                var passage = ["quote": highlight.quote]
                passage["prefix"] = highlight.webAnchor?.prefix
                passage["suffix"] = highlight.webAnchor?.suffix
                passage["releaseURL"] = SourceIdentity.gitHubReleaseURL(for: highlight.documentID)
                return passage
            }
        }
        let webNotes = notes.filter { $0.anchor.page == nil }
        if !webNotes.isEmpty, let stickyScript = Self.stickyScript {
            request["action"] = "paint"
            request["notes"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(webNotes))
            script = "(() => {\n" + stickyScript + "\nreturn " + template + "\n})()"
        }
        return try await browserCommand(target, template: script, request: request).status == "owned" ? .current : .unsupported
    }

    static func stickyURL(_ url: String) -> String {
        ChromePDFHighlights.paperURL(url)?.absoluteString ?? url
    }

    func locateStickyNote(at point: CGPoint, expected: WindowTarget? = nil) async throws -> (url: String, anchor: StickyAnchor, id: UUID?) {
        try requireSelectionAccess()
        let pinned = try currentTarget()
        guard isChromiumBrowser(pinned.bundleID), pinned.frame.contains(point),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pinned.pid else { throw StickyPlacementError.outsidePage }
        let target = try await resolve(target: pinned, askForAutomation: true)
        if let expected, expected.windowID != target.windowID || expected.pid != target.pid ||
            expected.url != target.url || expected.frame != target.frame { throw WindowCaptureError.sourceChanged }
        guard let url = target.url, let scheme = URL(string: url)?.scheme,
              ["https", "http"].contains(scheme) else { throw StickyPlacementError.outsidePage }
        let allowed = try await queued { self.automationAllowed(target.bundleID, ask: true) }
        guard allowed else { throw StickyPlacementError.automation }
        let input = PDFInputSnapshot()
        let anchor: StickyAnchor
        var id: UUID?
        if let paper = ChromePDFHighlights.paperURL(url) {
            guard let template = Self.pdfViewportScript,
                  try await browserCommand(target, template: template, request: ["url": url, "action": "status", "token": "placement"]).status != "unsupported"
            else { throw StickyPlacementError.automation }
            guard let position = try await pdfPosition(in: target, at: point),
                  let placement = try await pdfRenderer.stickyAnchor(paper: paper, position: position, at: point)
            else { throw StickyPlacementError.outsidePaper }
            anchor = placement
        } else {
            let viewport = try await queued { try self.webViewport(at: point, in: target) }
            guard let template = Self.stickyScript else { throw StickyPlacementError.automation }
            let reply = try await browserCommand(target, template: template, request: [
                "url": url, "action": "locate", "fractionX": (point.x - viewport.minX) / viewport.width,
                "fractionY": (point.y - viewport.minY) / viewport.height
            ])
            if reply.status == "notHTML" { throw StickyPlacementError.unsupported }
            guard reply.status != "unsupported" else { throw StickyPlacementError.automation }
            guard reply.status == "point", let placement = reply.anchor,
                  placement.page == nil, placement.x.isFinite, placement.y.isFinite else { throw StickyPlacementError.outsidePage }
            anchor = placement
            id = reply.id
        }
        let active = try await resolve(target: pinned)
        guard active.url == url, input == PDFInputSnapshot() else { throw WindowCaptureError.sourceChanged }
        return (Self.stickyURL(url), anchor, id)
    }

    private nonisolated func webViewport(at point: CGPoint, in target: WindowTarget) throws -> CGRect {
        let app = AXUIElementCreateApplication(target.pid)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else {
            throw StickyPlacementError.outsidePage
        }
        var viewport: CGRect?
        for _ in 0..<100 {
            guard let node = hit else { break }
            if string(node, kAXRoleAttribute) == "AXWebArea" { viewport = frame(node) }
            if string(node, kAXRoleAttribute) == kAXWindowRole {
                guard matches(node, frame: target.frame), let viewport, viewport.contains(point),
                      viewport.width > 0, viewport.height > 0 else { break }
                return viewport
            }
            hit = element(node, kAXParentAttribute)
        }
        throw StickyPlacementError.outsidePage
    }

    private struct BrowserReply: Decodable {
        var status: String
        var matched: Int?
        var prefix: String?
        var suffix: String?
        var releaseURL: String?
        var anchor: StickyAnchor?
        var id: UUID?
    }

    private func browserCommand(_ target: WindowTarget, template: String, request: [String: Any], input: PDFInputSnapshot? = nil) async throws -> BrowserReply {
        guard let url = target.url, let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8) else { return BrowserReply(status: "unsupported") }
        return try await queued {
            guard self.singleBrowser(target.bundleID, pid: target.pid),
                  self.automationAllowed(target.bundleID, ask: false) else { return BrowserReply(status: "unsupported") }
            let javascript = template.replacingOccurrences(of: "__MARGIN_REQUEST__", with: json)
            func checkWindow() throws {
                guard let front = self.frontWindow(pid: target.pid), front.id == target.windowID,
                      front.frame == target.frame else { throw WindowCaptureError.sourceChanged }
            }
            try checkWindow()
            let frame = target.frame
            let coordinates = [frame.minX, frame.minY, frame.maxX, frame.maxY].map { String(Double($0)) }
            let script = NSAppleScript(source: """
                on paint(jsSource, expectedURL)
                    with timeout of 2 seconds
                        tell application id "\(target.bundleID)"
                            set win to front window
                            set pageTab to active tab of win
                            set winBounds to bounds of win
                            set expectedBounds to {\(coordinates.joined(separator: ", "))}
                            repeat with i from 1 to 4
                                set delta to (item i of winBounds) - (item i of expectedBounds)
                                if delta ≥ 3 or delta ≤ -3 then return "changed"
                            end repeat
                            considering case
                                if URL of pageTab is not expectedURL then return "changed"
                            end considering
                            set answer to execute pageTab javascript jsSource
                            if id of front window is not id of win or bounds of front window is not winBounds then return "changed"
                            if id of active tab of front window is not id of pageTab then return "changed"
                            considering case
                                if URL of pageTab is not expectedURL then return "changed"
                            end considering
                            return answer
                        end tell
                    end timeout
                end paint
                """)
            // Pass the page script and URL as data. Saved quotes can contain arbitrary AppleScript syntax.
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                               eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
                                               returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(string: "paint"), forKeyword: AEKeyword(keyASSubroutineName))
            let arguments = NSAppleEventDescriptor.list()
            arguments.insert(NSAppleEventDescriptor(string: javascript), at: 1)
            arguments.insert(NSAppleEventDescriptor(string: url), at: 2)
            event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
            var error: NSDictionary?
            if let input, PDFInputSnapshot() != input { return BrowserReply(status: "interrupted") }
            let reply = script?.executeAppleEvent(event, error: &error)
            try checkWindow()
            guard self.singleBrowser(target.bundleID, pid: target.pid) else { throw WindowCaptureError.sourceChanged }
            guard error == nil, let value = reply?.stringValue else {
                let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
                Self.highlightLog.info("Browser painting unavailable; AppleScript error \(code)")
                return BrowserReply(status: "unsupported")
            }
            if value == "changed" { throw WindowCaptureError.sourceChanged }
            guard let result = try? JSONDecoder().decode(BrowserReply.self, from: Data(value.utf8)) else { return BrowserReply(status: "unsupported") }
            if result.status == "changed" { throw WindowCaptureError.sourceChanged }
            if let matched = result.matched {
                Self.highlightLog.info("Browser paint \(result.status, privacy: .public); matched \(matched) quotes")
            }
            return result
        }
    }

    private func readSource(_ target: WindowTarget, includeContent: Bool = false,
                            askForAutomation: Bool) async throws -> SourceSnapshot {
        let pinned = includeContent && !target.identityResolved ? try await readSource(target, askForAutomation: askForAutomation).target : target
        let deadline = Date().addingTimeInterval(3)
        while true {
            do {
                return try await queued {
                    try self.validatedSource(pinned, includeContent: includeContent, askForAutomation: askForAutomation)
                }
            } catch WindowCaptureError.selectionLoading {
                guard Date() < deadline else { throw WindowCaptureError.selectionLoading }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func queued<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let result: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                recognitionQueue.async {
                    continuation.resume(with: Result {
                        guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
                        return try work()
                    })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        try Task.checkCancellation()
        return result
    }

    func capture(target: WindowTarget, attachmentDirectory: URL,
                 persistImage: Bool = true, askForAutomation: Bool = true) async throws -> CapturedWindow {
        try await capture(target: target, attachmentDirectory: attachmentDirectory,
                          persistImage: persistImage, reusing: nil, askForAutomation: askForAutomation)
    }

    private func capture(target: WindowTarget, attachmentDirectory: URL,
                         persistImage: Bool, reusing previous: CapturedWindow?,
                         askForAutomation: Bool) async throws -> CapturedWindow {
        let source = try await readSource(target, includeContent: true, askForAutomation: askForAutomation)
        let nativeText = source.accessibility.hasVisibleCoverage
            ? source.accessibility.visibleText : ""
        var warnings: [String] = []
        var image: CGImage?
        var lines: [PositionedTextLine] = []

        if !accessibilityPermission {
            warnings.append("\(Self.accessibilityPermissionName) access is off; selected text is unavailable.")
        }
        if screenCapturePermission, persistImage || nativeText.isEmpty {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: {
                    $0.windowID == target.windowID && $0.owningApplication?.processID == target.pid
                }) else { throw WindowCaptureError.sourceChanged }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                let scale = min(2, Double(filter.pointPixelScale))
                configuration.width = max(1, Int(window.frame.width * scale))
                configuration.height = max(1, Int(window.frame.height * scale))
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } catch let error as WindowCaptureError {
                throw error
            } catch {
                warnings.append("The window screenshot was unavailable: \(error.localizedDescription)")
            }
        } else if !screenCapturePermission {
            warnings.append("Screen Recording access is off; this message contains accessible text only.")
        }

        if let image, nativeText.isEmpty {
            do {
                // Vision blocks internally; keep it off Swift's cooperative thread pool.
                lines = try await queued {
                    if let previous, !previous.ocrLines.isEmpty, let priorImage = previous.image,
                       priorImage.width == image.width, priorImage.height == image.height,
                       priorImage.bytesPerRow == image.bytesPerRow,
                       priorImage.bitsPerPixel == image.bitsPerPixel,
                       priorImage.bitmapInfo == image.bitmapInfo,
                       let oldPixels = priorImage.dataProvider?.data,
                       let newPixels = image.dataProvider?.data, CFEqual(oldPixels, newPixels) {
                        return previous.ocrLines
                    }
                    func recognize(_ level: VNRequestTextRecognitionLevel) throws -> [VNRecognizedTextObservation] {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = level
                        request.usesLanguageCorrection = true
                        try VNImageRequestHandler(cgImage: image).perform([request])
                        return request.results ?? []
                    }
                    let observations: [VNRecognizedTextObservation]
                    do { observations = try recognize(.accurate) }
                    catch { observations = try recognize(.fast) }
                    return observations.compactMap { observation -> PositionedTextLine? in
                        guard let recognized = observation.topCandidates(1).first else { return nil }
                        return PositionedTextLine(text: recognized.string, bounds: observation.boundingBox, recognizedText: recognized)
                    }
                }
            } catch {
                warnings.append("Text recognition was unavailable: \(error.localizedDescription)")
            }
        }

        // Navigation during capture must not combine text from one page with another page’s image.
        let finalSource = try await readSource(source.target, includeContent: image != nil && !nativeText.isEmpty,
                                             askForAutomation: askForAutomation)
        if image != nil, !nativeText.isEmpty,
           !finalSource.accessibility.hasVisibleCoverage ||
            finalSource.accessibility.visibleText != nativeText {
            throw WindowCaptureError.sourceChanged
        }
        guard finalSource.target.frame == source.target.frame else { throw WindowCaptureError.sourceChanged }
        // Browser PDF accessibility can include every page, even when only one is visible.
        let visibleText = lines.map(\.text).joined(separator: "\n")
        let text = !nativeText.isEmpty ? nativeText : (visibleText.isEmpty ? source.accessibility.text : visibleText)
        guard image != nil || !text.isEmpty || source.accessibility.selection != nil else {
            throw WindowCaptureError.noReadableContent
        }

        let capturedImage = image
        let screenshotPath = persistImage ? try await queued { try self.persist(capturedImage, in: attachmentDirectory) } : nil

        let pinned = finalSource.target
        let context = SourceContext(
            documentID: SourceIdentity.documentID(bundleID: pinned.bundleID, title: pinned.title, url: pinned.url),
            appName: pinned.appName, bundleID: pinned.bundleID, title: pinned.title,
            url: pinned.url, text: text, selection: source.accessibility.selection,
            capturedAt: Date(), screenshotPath: screenshotPath
        )
        if lastTarget?.pid == pinned.pid, lastTarget?.windowID == pinned.windowID {
            lastTarget = pinned
        }
        return CapturedWindow(context: context, target: pinned, accessibleLines: source.accessibility.lines,
                              ocrLines: lines, warnings: warnings, image: image, textAnchors: source.accessibility.anchors)
    }

    func refresh(_ captured: CapturedWindow, attachmentDirectory: URL,
                 persistImage: Bool = false) async throws -> CapturedWindow {
        try await capture(target: captured.target, attachmentDirectory: attachmentDirectory,
                          persistImage: persistImage, reusing: captured, askForAutomation: true)
    }

    func trackHighlights(in captured: CapturedWindow, quotes: [String]) async throws -> TrackedHighlights {
        try await queued {
            let native = captured.textAnchors.map(\.text)
            let recognized = captured.ocrLines.map(\.text)
            let byQuote = quotes.map { quote in
                let found = HighlightMatcher.matchedRanges(quote: quote, lines: native, fallbackLines: recognized)
                if found.contains(where: { $0.line < native.count && self.bounds(captured.textAnchors[$0.line].element, range: $0.range) == nil }) {
                    return HighlightMatcher.matchedRanges(quote: quote, lines: [], fallbackLines: recognized).map {
                        HighlightMatcher.TextMatch(line: native.count + $0.line, range: $0.range)
                    }
                }
                return found
            }
            let matches = byQuote.flatMap { $0 }
            let rectangles = matches.compactMap { match -> CGRect? in
                guard match.line >= native.count else { return nil }
                let line = captured.ocrLines[match.line - native.count]
                guard let candidate = line.recognizedText,
                      let range = Range(match.range, in: candidate.string) else { return nil }
                // Accurate Vision supplies word boxes, so partial-word matches must stay unpainted.
                var partialWord = false
                candidate.string.enumerateSubstrings(in: candidate.string.startIndex..<candidate.string.endIndex, options: .byWords) { _, word, _, _ in
                    let span = NSRange(word, in: candidate.string)
                    let overlap = NSIntersectionRange(span, match.range).length
                    if overlap > 0, overlap < span.length { partialWord = true }
                }
                guard !partialWord, let observation = try? candidate.boundingBox(for: range) else { return nil }
                return observation.boundingBox
            }
            return TrackedHighlights(target: captured.target, anchors: captured.textAnchors,
                                     matches: matches.filter { $0.line < native.count },
                                     recognizedRectangles: rectangles, hasUnmatchedQuotes: byQuote.contains(where: \.isEmpty))
        }
    }

    func highlightFrame(_ tracked: TrackedHighlights, includeRecognized: Bool) async throws -> HighlightFrame {
        try await queued {
            let source = try self.validatedSource(tracked.target)
            let frame = source.target.frame
            var rectangles: [CGRect] = []
            for index in Set(tracked.matches.map(\.line)).sorted() {
                let anchor = tracked.anchors[index]
                guard let value = self.string(anchor.element, kAXValueAttribute),
                      value.utf16.starts(with: anchor.text.utf16),
                      let elementFrame = self.frame(anchor.element) else { throw WindowCaptureError.sourceChanged }
                let clip = frame.intersection(elementFrame)
                if clip.isEmpty { continue }
                for match in tracked.matches where match.line == index {
                    guard let bounds = TextRangeGeometry.rectangles(text: anchor.text, range: match.range, bounds: {
                        self.bounds(anchor.element, range: $0)
                    }) else { continue }
                    rectangles.append(contentsOf: bounds.compactMap { rect in
                        let visible = rect.intersection(clip)
                        return visible.isEmpty ? nil : visible
                    })
                }
            }
            if includeRecognized, frame == tracked.target.frame {
                rectangles.append(contentsOf: tracked.recognizedRectangles.map { rect in
                    CGRect(x: frame.minX + rect.minX * frame.width, y: frame.maxY - rect.maxY * frame.height,
                           width: rect.width * frame.width, height: rect.height * frame.height)
                })
            }
            let final = try self.validatedSource(source.target)
            guard final.target.frame == frame else { throw WindowCaptureError.sourceChanged }
            return HighlightFrame(target: final.target, rectangles: rectangles)
        }
    }

    private nonisolated func bounds(_ element: AXUIElement, range: NSRange) -> CGRect? {
        var span = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &span) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgRect, &rect),
              !rect.isNull, !rect.isInfinite else { return nil }
        return rect
    }

    private nonisolated func persist(_ image: CGImage?, in directory: URL) throws -> String? {
        guard let image else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString).png")
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: destination, options: .atomic)
        return destination.path
    }

    private struct WindowRecord {
        let id: CGWindowID
        let title: String
        let frame: CGRect
    }

    private struct AccessibleContent: Sendable {
        var url: String?
        var text = ""
        var selection: String?
        var lines: [PositionedTextLine] = []
        var anchors: [AccessibleTextAnchor] = []
        var hasVisibleCoverage = true
        var unpositionedText: [String] = []
        var visibleText: String { (lines.map(\.text) + unpositionedText).joined(separator: "\n") }
    }

    private struct SourceSnapshot: Sendable {
        let target: WindowTarget
        let accessibility: AccessibleContent
    }

    private nonisolated func frontWindow(pid: pid_t) -> WindowRecord? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = window[kCGWindowNumber as String] as? NSNumber,
                  let dictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  frame.width > 1, frame.height > 1 else { continue }
            return WindowRecord(id: number.uint32Value,
                                title: window[kCGWindowName as String] as? String ?? "", frame: frame)
        }
        return nil
    }

    private nonisolated func validatedSource(_ target: WindowTarget, includeContent: Bool = false,
                                             askForAutomation: Bool = false, matchDocument: Bool = true) throws -> SourceSnapshot {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              (app.bundleIdentifier ?? "pid:\(target.pid)") == target.bundleID,
              let window = frontWindow(pid: target.pid), window.id == target.windowID else {
            throw WindowCaptureError.sourceChanged
        }
        let source = try sourceSnapshot(window: window, app: app, includeContent: includeContent, askForAutomation: askForAutomation)
        if matchDocument {
            if let url = target.url {
                guard source.target.url == url else { throw WindowCaptureError.sourceChanged }
            } else {
                let title = target.identityResolved ? source.target.title : window.title
                guard title == target.title else { throw WindowCaptureError.sourceChanged }
            }
        }
        if isBrowser(target.bundleID), source.target.url == nil {
            throw WindowCaptureError.browserURLUnavailable
        }
        return source
    }

    private nonisolated func sourceSnapshot(window: WindowRecord, app: NSRunningApplication,
                                includeContent: Bool, askForAutomation: Bool) throws -> SourceSnapshot {
        let bundleID = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        func snapshot(title: String, content: AccessibleContent) -> SourceSnapshot {
            SourceSnapshot(target: WindowTarget(pid: app.processIdentifier, windowID: window.id,
                                                appName: app.localizedName ?? bundleID, bundleID: bundleID,
                                                title: title.isEmpty ? (app.localizedName ?? "Untitled window") : title,
                                                url: content.url, frame: window.frame, identityResolved: true),
                           accessibility: content)
        }
        if includeContent, askForAutomation, isChromiumBrowser(bundleID) {
            _ = automationAllowed(bundleID, ask: true)
        }
        // Restoring a Chrome page needs only its URL, even when its AX tree is large or unavailable.
        let readTabFirst = !includeContent && !askForAutomation && isChromiumBrowser(bundleID)
        if readTabFirst, let url = browserURL(bundleID: bundleID, pid: app.processIdentifier,
                                              window: window, askForAutomation: false) {
            return snapshot(title: window.title, content: AccessibleContent(url: url))
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        if accessibilityPermission, isChromiumBrowser(app.bundleIdentifier ?? "") {
            // Reading the role asks Chromium to enable its page accessibility tree.
            _ = attribute(application, kAXRoleAttribute)
            if includeContent {
                // A cold Chromium process exposes focused content asynchronously after the role read.
                let deadline = Date().addingTimeInterval(0.5)
                while element(application, kAXFocusedUIElementAttribute) == nil, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.025)
                }
                if let focused = element(application, kAXFocusedUIElementAttribute),
                   string(focused, kAXRoleAttribute) == kAXGroupRole,
                   let value = attribute(focused, kAXSelectedTextRangeAttribute),
                   CFGetTypeID(value) == AXValueGetTypeID() {
                    var range = CFRange(location: 0, length: 0)
                    if AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range),
                       range.location == 0, range.length == 0 {
                        // Chromium PDF groups report an empty range until their selection markers load.
                        guard attribute(focused, "AXSelectedTextMarkerRange") != nil else {
                            throw WindowCaptureError.selectionLoading
                        }
                    }
                }
            }
        }
        let focusedWindow = accessibilityPermission ? element(application, kAXFocusedWindowAttribute) : nil
        let matchingWindow = focusedWindow.flatMap { matches($0, frame: window.frame) ? $0 : nil }
        let title = matchingWindow.flatMap { string($0, kAXTitleAttribute) } ?? window.title
        var content = AccessibleContent()
        content.url = matchingWindow.flatMap { documentURL($0) }
        if isBrowser(bundleID), content.url == nil, let matchingWindow {
            content.url = accessibleContent(window: matchingWindow, application: application,
                                            frame: window.frame, captureLineBounds: false,
                                            includeContent: false).url
        }
        if isBrowser(bundleID), content.url == nil, !readTabFirst {
            content.url = browserURL(bundleID: bundleID, pid: app.processIdentifier, window: window,
                                     askForAutomation: askForAutomation)
        }
        if let matchingWindow, includeContent || content.url == nil {
            let accessible = accessibleContent(window: matchingWindow, application: application,
                                               frame: window.frame, captureLineBounds: true,
                                               includeContent: includeContent)
            content.url = content.url ?? accessible.url
            content.text = accessible.text
            content.selection = accessible.selection
            content.lines = accessible.lines
            content.anchors = accessible.anchors
            content.hasVisibleCoverage = accessible.hasVisibleCoverage
            content.unpositionedText = accessible.unpositionedText
        }
        return snapshot(title: title, content: content)
    }

    private nonisolated func accessibleContent(window: AXUIElement, application: AXUIElement,
                                   frame: CGRect, captureLineBounds: Bool, includeContent: Bool) -> AccessibleContent {
        var result = AccessibleContent()
        result.url = documentURL(window)
        if includeContent, let focused = element(application, kAXFocusedUIElementAttribute), belongsToWindow(focused, window: window) {
            result.selection = selection(focused)
        }

        var queue = [window]
        var index = 0
        var fragments: [String] = []
        var characters = 0
        let deadline = Date().addingTimeInterval(0.8)
        while index < queue.count, index < 1_200, characters < 60_000, Date() < deadline {
            if !includeContent, result.url != nil { break }
            let item = queue[index]
            index += 1
            if isSecure(item) { continue }
            let role = string(item, kAXRoleAttribute) ?? ""
            if [kAXToolbarRole, kAXMenuRole, kAXMenuBarRole].contains(role) { continue }
            if result.url == nil, role == "AXWebArea" { result.url = documentURL(item) }
            if includeContent, result.selection == nil {
                result.selection = selection(item)
            }
            if includeContent, [kAXImageRole, "AXCanvas"].contains(role),
               let bounds = self.frame(item) {
                let visible = bounds.intersection(frame)
                // Large images may contain text that the accessibility tree does not expose.
                if !visible.isEmpty, visible.width * visible.height > 20_000 {
                    result.hasVisibleCoverage = false
                }
            }
            if includeContent, [kAXStaticTextRole, kAXTextAreaRole].contains(role),
               let value = string(item, kAXValueAttribute), !value.isEmpty {
                let fragment = String(value.prefix(60_000 - characters))
                result.anchors.append(AccessibleTextAnchor(element: item, text: fragment))
                if captureLineBounds, Date() < deadline {
                    let positioned = positionedLines(item, text: fragment, windowFrame: frame, deadline: deadline)
                    result.lines.append(contentsOf: positioned.lines)
                    if !positioned.complete {
                        if role == kAXStaticTextRole, fragment.rangeOfCharacter(from: .newlines) == nil,
                           let bounds = self.frame(item), bounds.width > 1, bounds.height > 1,
                           frame.contains(bounds) {
                            // Static labels may omit usable range bounds. Keep their text out of highlight geometry.
                            result.unpositionedText.append(fragment)
                        } else {
                            result.hasVisibleCoverage = false
                        }
                    }
                }
                if fragment.count < value.count { result.hasVisibleCoverage = false }
                if fragments.last != fragment {
                    fragments.append(fragment)
                    characters += fragment.count
                }
            }
            if let children = attribute(item, kAXChildrenAttribute) as? [AXUIElement] {
                let remaining = max(0, 1_200 - queue.count)
                if children.count > remaining { result.hasVisibleCoverage = false }
                queue.append(contentsOf: children.prefix(remaining))
            }
        }
        if index < queue.count || Date() >= deadline { result.hasVisibleCoverage = false }
        result.text = fragments.joined(separator: "\n")
        return result
    }

    private nonisolated func positionedLines(_ element: AXUIElement, text: String, windowFrame: CGRect,
                                 deadline: Date) -> (lines: [PositionedTextLine], complete: Bool) {
        guard let elementFrame = frame(element) else { return ([], false) }
        let clip = elementFrame.intersection(windowFrame)
        guard elementFrame.width > 1, elementFrame.height > 1, !clip.isEmpty else { return ([], true) }
        let value = text as NSString
        var lines: [PositionedTextLine] = []
        var complete = true
        value.enumerateSubstrings(in: NSRange(location: 0, length: value.length), options: .byLines) {
            substring, range, _, stop in
            guard Date() < deadline else { complete = false; stop.pointee = true; return }
            guard let substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            var characterRange = CFRange(location: range.location, length: range.length)
            guard let parameter = AXValueCreate(.cfRange, &characterRange) else { complete = false; return }
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                             parameter, &result) == .success,
                  let result, CFGetTypeID(result) == AXValueGetTypeID() else {
                complete = false
                stop.pointee = true
                return
            }
            var bounds = CGRect.zero
            guard AXValueGetValue(unsafeBitCast(result, to: AXValue.self), .cgRect, &bounds) else {
                complete = false
                return
            }
            // Chromium range bounds are unclipped; its text element frame clips to the viewport.
            // Exclude clipped endpoint lines rather than include text outside the viewport.
            guard !bounds.isEmpty, !bounds.isInfinite else { complete = false; return }
            guard clip.contains(bounds) else { return }
            lines.append(PositionedTextLine(text: substring, bounds: CGRect(
                x: (bounds.minX - windowFrame.minX) / windowFrame.width,
                y: (windowFrame.maxY - bounds.maxY) / windowFrame.height,
                width: bounds.width / windowFrame.width, height: bounds.height / windowFrame.height
            )))
        }
        return (lines, complete)
    }

    private nonisolated func selection(_ element: AXUIElement) -> String? {
        guard !isSecure(element) else { return nil }
        if let text = string(element, kAXSelectedTextAttribute), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(text.prefix(60_000))
        }
        // WebKit exposes document selections as text markers rather than character ranges.
        for (rangeAttribute, stringAttribute) in [
            (kAXSelectedTextRangeAttribute, kAXStringForRangeParameterizedAttribute),
            ("AXSelectedTextMarkerRange", "AXStringForTextMarkerRange")
        ] {
            guard let range = attribute(element, rangeAttribute) else { continue }
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, stringAttribute as CFString,
                                                         range, &value) == .success,
               let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(text.prefix(60_000))
            }
        }
        return nil
    }

    private nonisolated func belongsToWindow(_ element: AXUIElement, window: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        let deadline = Date().addingTimeInterval(0.4)
        for _ in 0..<40 {
            guard Date() < deadline, let item = current, !isSecure(item) else { return false }
            if CFEqual(item, window) { return true }
            current = self.element(item, kAXParentAttribute)
        }
        return false
    }

    private nonisolated func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole ||
            (attribute(element, "AXProtectedContent") as? Bool == true)
    }

    private nonisolated func matches(_ element: AXUIElement, frame: CGRect) -> Bool {
        guard let bounds = self.frame(element) else { return false }
        return abs(bounds.minX - frame.minX) < 3 && abs(bounds.minY - frame.minY) < 3 &&
            abs(bounds.width - frame.width) < 3 && abs(bounds.height - frame.height) < 3
    }

    private nonisolated func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private nonisolated func documentURL(_ element: AXUIElement) -> String? {
        for name in [kAXDocumentAttribute, "AXURL"] {
            if let value = attribute(element, name) {
                let candidate = (value as? URL)?.absoluteString ?? (value as? String)
                if let candidate, URL(string: candidate)?.scheme != nil { return candidate }
            }
        }
        return nil
    }

    private nonisolated func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private nonisolated func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private nonisolated func isBrowser(_ bundleID: String) -> Bool {
        isChromiumBrowser(bundleID) ||
            ["com.apple.Safari", "com.apple.SafariTechnologyPreview",
             "company.thebrowser.Browser", "org.mozilla.firefox"].contains(bundleID)
    }

    nonisolated func isChromiumBrowser(_ bundleID: String) -> Bool {
        ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
         "com.google.Chrome.canary", "org.chromium.Chromium", "com.microsoft.edgemac",
         "com.brave.Browser"].contains(bundleID)
    }

    private nonisolated func singleBrowser(_ bundleID: String, pid: pid_t) -> Bool {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return instances.count == 1 && instances[0].processIdentifier == pid
    }

    private nonisolated func automationAllowed(_ bundleID: String, ask: Bool) -> Bool {
        let address = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(address.aeDesc, typeWildCard, typeWildCard, ask) == noErr
    }

    private nonisolated func browserURL(bundleID: String, pid: pid_t, window: WindowRecord, askForAutomation: Bool) -> String? {
        let property: String
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            property = "URL of current tab of front window"
        case let id where isChromiumBrowser(id):
            property = "URL of active tab of front window"
        default:
            return nil
        }
        // Bundle targeting is unambiguous only when one instance of this browser is running.
        guard singleBrowser(bundleID, pid: pid), frontWindow(pid: pid)?.id == window.id,
              automationAllowed(bundleID, ask: askForAutomation) else { return nil }
        let source = "with timeout of 2 seconds\n tell application id \"\(bundleID)\" to return {\(property), bounds of front window}\nend timeout"
        var error: NSDictionary?
        let response = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil, singleBrowser(bundleID, pid: pid), frontWindow(pid: pid)?.id == window.id,
              let value = response?.atIndex(1)?.stringValue,
              let bounds = response?.atIndex(2), bounds.numberOfItems == 4,
              URL(string: value)?.scheme != nil else { return nil }
        let coordinates = (1...4).map { CGFloat(bounds.atIndex($0)?.int32Value ?? Int32.min) }
        let frame = window.frame
        guard abs(coordinates[0] - frame.minX) < 3, abs(coordinates[1] - frame.minY) < 3,
              abs(coordinates[2] - frame.maxX) < 3, abs(coordinates[3] - frame.maxY) < 3 else { return nil }
        return value
    }
}
