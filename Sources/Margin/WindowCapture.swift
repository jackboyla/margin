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

struct PositionedTextLine: Sendable {
    let text: String
    /// Vision coordinates: normalized to the captured window, origin at bottom left.
    let bounds: CGRect
}

struct CapturedWindow: Sendable {
    let context: SourceContext
    let target: WindowTarget
    let accessibleLines: [PositionedTextLine]
    let ocrLines: [PositionedTextLine]
    let warnings: [String]
    var image: CGImage? = nil
}

enum WindowCaptureError: LocalizedError {
    case noSourceWindow
    case sourceChanged
    case browserURLUnavailable
    case noReadableContent

    var errorDescription: String? {
        switch self {
        case .noSourceWindow:
            return "Open a document in Chrome, Safari, or another app, then try the shortcut again."
        case .sourceChanged:
            return "The source window or page changed. Open Margin again from the page you want to use."
        case .browserURLUnavailable:
            return "Margin could not read this page’s URL. Allow \(WindowCapture.accessibilityPermissionName) and browser Automation access in System Settings, then try again."
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

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @discardableResult
    func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
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

    func resolve(target: WindowTarget) async throws -> WindowTarget {
        try await readSource(target).target
    }

    private func readSource(_ target: WindowTarget, includeContent: Bool = false) async throws -> SourceSnapshot {
        try await queued {
            try self.validatedSource(target, includeContent: includeContent)
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
                 persistImage: Bool = true) async throws -> CapturedWindow {
        try await capture(target: target, attachmentDirectory: attachmentDirectory,
                          persistImage: persistImage, reusing: nil)
    }

    private func capture(target: WindowTarget, attachmentDirectory: URL,
                         persistImage: Bool, reusing previous: CapturedWindow?) async throws -> CapturedWindow {
        let source = try await readSource(target, includeContent: true)
        let nativeText = source.accessibility.hasVisibleCoverage
            ? source.accessibility.lines.map(\.text).joined(separator: "\n") : ""
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
                        guard let text = observation.topCandidates(1).first?.string else { return nil }
                        return PositionedTextLine(text: text, bounds: observation.boundingBox)
                    }
                }
            } catch {
                warnings.append("Text recognition was unavailable: \(error.localizedDescription)")
            }
        }

        // Navigation during capture must not combine text from one page with another page’s image.
        let finalSource = try await readSource(source.target, includeContent: image != nil && !nativeText.isEmpty)
        if image != nil, !nativeText.isEmpty,
           !finalSource.accessibility.hasVisibleCoverage ||
            finalSource.accessibility.lines.map(\.text).joined(separator: "\n") != nativeText {
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
        lastTarget = pinned
        return CapturedWindow(context: context, target: pinned, accessibleLines: source.accessibility.lines,
                              ocrLines: lines, warnings: warnings, image: image)
    }

    func refresh(_ captured: CapturedWindow, attachmentDirectory: URL,
                 persistImage: Bool = false) async throws -> CapturedWindow {
        try await capture(target: captured.target, attachmentDirectory: attachmentDirectory,
                          persistImage: persistImage, reusing: captured)
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
        var hasVisibleCoverage = true
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

    private nonisolated func validatedSource(_ target: WindowTarget, includeContent: Bool = false) throws -> SourceSnapshot {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              (app.bundleIdentifier ?? "pid:\(target.pid)") == target.bundleID,
              let window = frontWindow(pid: target.pid), window.id == target.windowID else {
            throw WindowCaptureError.sourceChanged
        }
        let source = sourceSnapshot(window: window, app: app, includeContent: includeContent)
        if let url = target.url {
            guard source.target.url == url else { throw WindowCaptureError.sourceChanged }
        } else {
            let title = target.identityResolved ? source.target.title : window.title
            guard title == target.title else { throw WindowCaptureError.sourceChanged }
        }
        if isBrowser(target.bundleID), source.target.url == nil {
            throw WindowCaptureError.browserURLUnavailable
        }
        return source
    }

    private nonisolated func sourceSnapshot(window: WindowRecord, app: NSRunningApplication,
                                includeContent: Bool = false) -> SourceSnapshot {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        if accessibilityPermission, isChromiumBrowser(app.bundleIdentifier ?? "") {
            // Reading the role asks Chromium to enable its page accessibility tree.
            _ = attribute(application, kAXRoleAttribute)
        }
        let focusedWindow = accessibilityPermission ? element(application, kAXFocusedWindowAttribute) : nil
        let matchingWindow = focusedWindow.flatMap { matches($0, frame: window.frame) ? $0 : nil }
        let title = matchingWindow.flatMap { string($0, kAXTitleAttribute) } ?? window.title
        let bundleID = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        var content = AccessibleContent()
        content.url = matchingWindow.flatMap { documentURL($0) }
        if isBrowser(bundleID), content.url == nil, let matchingWindow {
            content.url = accessibleContent(window: matchingWindow, application: application,
                                            frame: window.frame, captureLineBounds: false,
                                            includeContent: false).url
        }
        if isBrowser(bundleID), content.url == nil {
            content.url = browserURL(bundleID: bundleID, pid: app.processIdentifier, window: window)
        }
        if let matchingWindow, includeContent || content.url == nil {
            let accessible = accessibleContent(window: matchingWindow, application: application,
                                               frame: window.frame, captureLineBounds: true,
                                               includeContent: includeContent)
            content.url = content.url ?? accessible.url
            content.text = accessible.text
            content.selection = accessible.selection
            content.lines = accessible.lines
            content.hasVisibleCoverage = accessible.hasVisibleCoverage
        }
        return SourceSnapshot(
            target: WindowTarget(pid: app.processIdentifier, windowID: window.id,
                                 appName: app.localizedName ?? bundleID, bundleID: bundleID,
                                 title: title.isEmpty ? (app.localizedName ?? "Untitled window") : title,
                                 url: content.url, frame: window.frame, identityResolved: true),
            accessibility: content
        )
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
            if includeContent, result.selection == nil, role == "AXWebArea" {
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
                if captureLineBounds, Date() < deadline {
                    let positioned = positionedLines(item, text: fragment, windowFrame: frame, deadline: deadline)
                    result.lines.append(contentsOf: positioned.lines)
                    if !positioned.complete { result.hasVisibleCoverage = false }
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
        guard !clip.isEmpty else { return ([], true) }
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

    private nonisolated func isChromiumBrowser(_ bundleID: String) -> Bool {
        ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
         "com.google.Chrome.canary", "org.chromium.Chromium", "com.microsoft.edgemac",
         "com.brave.Browser"].contains(bundleID)
    }

    private nonisolated func browserURL(bundleID: String, pid: pid_t, window: WindowRecord) -> String? {
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
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard instances.count == 1, instances[0].processIdentifier == pid,
              frontWindow(pid: pid)?.id == window.id else { return nil }
        // Permission dialogs must not expire with the short browser-read timeout.
        let address = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard AEDeterminePermissionToAutomateTarget(address.aeDesc, typeWildCard, typeWildCard, true) == noErr else {
            return nil
        }
        let source = "with timeout of 2 seconds\n tell application id \"\(bundleID)\" to return {\(property), bounds of front window}\nend timeout"
        var error: NSDictionary?
        let response = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil, frontWindow(pid: pid)?.id == window.id,
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
