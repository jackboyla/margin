import AppKit
import ApplicationServices
import Carbon
import MarginCore
import ScreenCaptureKit
import Vision

struct WindowTarget {
    let pid: pid_t
    let windowID: CGWindowID
    let appName: String
    let bundleID: String
    let title: String
    let url: String?
    /// Screen coordinates, with the origin at the top left of the main display.
    let frame: CGRect
}

struct OCRLine {
    let text: String
    /// Vision coordinates: normalized to the captured window, origin at bottom left.
    let bounds: CGRect
}

struct CapturedWindow {
    let context: SourceContext
    let target: WindowTarget
    let ocrLines: [OCRLine]
    let warnings: [String]
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
            return "Margin could not read this page’s URL. Allow Accessibility and browser Automation access in System Settings, then try again."
        case .noReadableContent:
            return "Margin could not read this window. Allow Accessibility or Screen Recording access in System Settings, then try again."
        }
    }
}

@MainActor
final class WindowCapture {
    private var lastTarget: WindowTarget?
    private let recognitionQueue = DispatchQueue(label: "com.jackboylan.margin.ocr", qos: .userInitiated)

    var accessibilityPermission: Bool { AXIsProcessTrusted() }
    var screenCapturePermission: Bool { CGPreflightScreenCaptureAccess() }

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
            return try validatedSource(lastTarget).target
        }
        guard let window = frontWindow(pid: app.processIdentifier) else {
            throw WindowCaptureError.noSourceWindow
        }
        let source = sourceSnapshot(window: window, app: app)
        if isBrowser(app.bundleIdentifier ?? ""), source.target.url == nil {
            throw WindowCaptureError.browserURLUnavailable
        }
        lastTarget = source.target
        return source.target
    }

    func capture(target: WindowTarget, attachmentDirectory: URL,
                 persistImage: Bool = true) async throws -> CapturedWindow {
        let source = try validatedSource(target, includeContent: true)
        var warnings: [String] = []
        var image: CGImage?
        var lines: [OCRLine] = []

        if !accessibilityPermission {
            warnings.append("Accessibility access is off; selected text is unavailable.")
        }
        if screenCapturePermission {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: {
                    $0.windowID == target.windowID && $0.owningApplication?.processID == target.pid
                }) else { throw WindowCaptureError.sourceChanged }
                _ = try validatedSource(source.target)
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                let scale = min(2, Double(filter.pointPixelScale))
                configuration.width = max(1, Int(window.frame.width * scale))
                configuration.height = max(1, Int(window.frame.height * scale))
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                _ = try validatedSource(source.target)
            } catch let error as WindowCaptureError {
                throw error
            } catch {
                warnings.append("The window screenshot was unavailable: \(error.localizedDescription)")
            }
        } else {
            warnings.append("Screen Recording access is off; this message contains accessible text only.")
        }

        if let image {
            do {
                // Vision blocks internally; keep it off Swift's cooperative thread pool.
                lines = try await withCheckedThrowingContinuation { continuation in
                    recognitionQueue.async {
                        do {
                            let request = VNRecognizeTextRequest()
                            request.recognitionLevel = .accurate
                            request.usesLanguageCorrection = true
                            try VNImageRequestHandler(cgImage: image).perform([request])
                            let result = (request.results ?? []).compactMap { observation -> OCRLine? in
                                guard let text = observation.topCandidates(1).first?.string else { return nil }
                                return OCRLine(text: text, bounds: observation.boundingBox)
                            }
                            continuation.resume(returning: result)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            } catch {
                warnings.append("Text recognition was unavailable: \(error.localizedDescription)")
            }
        }

        // Navigation during capture must not combine text from one page with another page’s image.
        let finalSource = try validatedSource(source.target)
        let text = source.accessibility.text.isEmpty
            ? lines.map(\.text).joined(separator: "\n") : source.accessibility.text
        guard image != nil || !text.isEmpty || source.accessibility.selection != nil else {
            throw WindowCaptureError.noReadableContent
        }

        var screenshotPath: String?
        if persistImage, let image {
            try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
            let destination = attachmentDirectory.appendingPathComponent("\(UUID().uuidString).png")
            let representation = NSBitmapImageRep(cgImage: image)
            guard let data = representation.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: destination, options: .atomic)
            screenshotPath = destination.path
        }

        let pinned = finalSource.target
        let context = SourceContext(
            documentID: SourceIdentity.documentID(bundleID: pinned.bundleID, title: pinned.title, url: pinned.url),
            appName: pinned.appName, bundleID: pinned.bundleID, title: pinned.title,
            url: pinned.url, text: text, selection: source.accessibility.selection,
            capturedAt: Date(), screenshotPath: screenshotPath
        )
        lastTarget = pinned
        return CapturedWindow(context: context, target: pinned, ocrLines: lines, warnings: warnings)
    }

    private struct WindowRecord {
        let id: CGWindowID
        let title: String
        let frame: CGRect
    }

    private struct AccessibleContent {
        var url: String?
        var text = ""
        var selection: String?
    }

    private struct SourceSnapshot {
        let target: WindowTarget
        let accessibility: AccessibleContent
    }

    private func frontWindow(pid: pid_t) -> WindowRecord? {
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

    private func validatedSource(_ target: WindowTarget, includeContent: Bool = false) throws -> SourceSnapshot {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              (app.bundleIdentifier ?? "pid:\(target.pid)") == target.bundleID,
              let window = frontWindow(pid: target.pid), window.id == target.windowID else {
            throw WindowCaptureError.sourceChanged
        }
        let source = sourceSnapshot(window: window, app: app, includeContent: includeContent)
        if let url = target.url {
            guard source.target.url == url else { throw WindowCaptureError.sourceChanged }
        } else {
            guard source.target.title == target.title else { throw WindowCaptureError.sourceChanged }
        }
        if isBrowser(target.bundleID), source.target.url == nil {
            throw WindowCaptureError.browserURLUnavailable
        }
        return source
    }

    private func sourceSnapshot(window: WindowRecord, app: NSRunningApplication,
                                includeContent: Bool = false) -> SourceSnapshot {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let focusedWindow = accessibilityPermission ? element(application, kAXFocusedWindowAttribute) : nil
        let matchingWindow = focusedWindow.flatMap { matches($0, frame: window.frame) ? $0 : nil }
        let title = matchingWindow.flatMap { string($0, kAXTitleAttribute) } ?? window.title
        let bundleID = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        var content = AccessibleContent()
        content.url = matchingWindow.flatMap { documentURL($0) }
        if isBrowser(bundleID), content.url == nil {
            content.url = browserURL(bundleID: bundleID, pid: app.processIdentifier, window: window)
        }
        if let matchingWindow, includeContent || content.url == nil {
            let accessible = accessibleContent(window: matchingWindow, application: application,
                                               includeContent: includeContent)
            content.url = content.url ?? accessible.url
            content.text = accessible.text
            content.selection = accessible.selection
        }
        return SourceSnapshot(
            target: WindowTarget(pid: app.processIdentifier, windowID: window.id,
                                 appName: app.localizedName ?? bundleID, bundleID: bundleID,
                                 title: title.isEmpty ? (app.localizedName ?? "Untitled window") : title,
                                 url: content.url, frame: window.frame),
            accessibility: content
        )
    }

    private func accessibleContent(window: AXUIElement, application: AXUIElement,
                                   includeContent: Bool) -> AccessibleContent {
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
            if includeContent, result.selection == nil { result.selection = selection(item) }
            if includeContent, [kAXStaticTextRole, kAXTextAreaRole].contains(role),
               let value = string(item, kAXValueAttribute), !value.isEmpty {
                let fragment = String(value.prefix(60_000 - characters))
                if fragments.last != fragment {
                    fragments.append(fragment)
                    characters += fragment.count
                }
            }
            if queue.count < 1_200, let children = attribute(item, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(1_200 - queue.count))
            }
        }
        result.text = fragments.joined(separator: "\n")
        return result
    }

    private func selection(_ element: AXUIElement) -> String? {
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

    private func belongsToWindow(_ element: AXUIElement, window: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        let deadline = Date().addingTimeInterval(0.4)
        for _ in 0..<40 {
            guard Date() < deadline, let item = current, !isSecure(item) else { return false }
            if CFEqual(item, window) { return true }
            current = self.element(item, kAXParentAttribute)
        }
        return false
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole ||
            (attribute(element, "AXProtectedContent") as? Bool == true)
    }

    private func matches(_ element: AXUIElement, frame: CGRect) -> Bool {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return false }
        return abs(point.x - frame.minX) < 3 && abs(point.y - frame.minY) < 3 &&
            abs(dimensions.width - frame.width) < 3 && abs(dimensions.height - frame.height) < 3
    }

    private func documentURL(_ element: AXUIElement) -> String? {
        for name in [kAXDocumentAttribute, "AXURL"] {
            if let value = attribute(element, name) {
                let candidate = (value as? URL)?.absoluteString ?? (value as? String)
                if let candidate, URL(string: candidate)?.scheme != nil { return candidate }
            }
        }
        return nil
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func isBrowser(_ bundleID: String) -> Bool {
        ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
         "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
         "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser",
         "company.thebrowser.Browser", "org.mozilla.firefox"].contains(bundleID)
    }

    private func browserURL(bundleID: String, pid: pid_t, window: WindowRecord) -> String? {
        let property: String
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            property = "URL of current tab of front window"
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
             "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser":
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
