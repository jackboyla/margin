import AppKit
import MarginCore

@MainActor
final class HighlightOverlays {
    private weak var model: AppModel?
    private let window: NSWindow
    private let drawing = HighlightDrawingView()
    private var settlingTask: Task<Void, Never>?
    private var pageCheckTask: Task<Void, Never>?
    private var refreshRunning = false
    private var needsRefresh = false
    private var needsPageCheck = true
    private var browserOwnsPage = false
    private var browserNeedsRetry = false
    private var needsRescan = false
    private var pendingCapture: CapturedWindow?
    private var tracked: TrackedHighlights?
    private var recognizedIsCurrent = false
    private var generation = 0
    private var viewportRevision = 0
    private var monitor: Any?
    private var activationObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = drawing
        model.onCapture = { [weak self] result in
            guard let self else { return }
            self.generation += 1
            self.pendingCapture = result
            self.needsPageCheck = true
            self.requestRefresh()
        }
        model.onLibraryChange = { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.tracked = nil
            self.browserNeedsRetry = true
            if self.model?.library.highlights.isEmpty == true { self.window.orderOut(nil) }
            self.requestRefresh()
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseUp, .leftMouseDragged, .keyUp]) { [weak self] event in
            let type = event.type
            Task { @MainActor in
                self?.interaction(viewportMoved: type != .leftMouseUp,
                                  checkPage: type == .leftMouseUp || type == .keyUp)
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model?.capture.prepareAccessibilityForFrontmostApplication()
                if let target = try? self.model?.capture.currentTarget(),
                   target.pid != self.tracked?.target.pid || target.windowID != self.tracked?.target.windowID {
                    self.tracked = nil
                    self.window.orderOut(nil)
                }
                self.interaction(viewportMoved: true, checkPage: true)
            }
        }
        model.capture.prepareAccessibilityForFrontmostApplication()
        // Navigation can commit after the click and its settling check have finished.
        pageCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if self.model?.library.highlights.isEmpty == false || self.model?.library.stickyNotes.isEmpty == false || self.browserNeedsRetry,
                   let target = try? self.model?.capture.currentTarget(),
                   self.model?.capture.isChromiumBrowser(target.bundleID) == true {
                    self.needsPageCheck = true
                    self.requestRefresh()
                }
            }
        }
        requestRefresh()
    }

    private func interaction(viewportMoved: Bool, checkPage: Bool) {
        if viewportMoved { recognizedIsCurrent = false; viewportRevision += 1 }
        if checkPage {
            generation += 1
            needsPageCheck = true
        }
        if checkPage || !browserOwnsPage { requestRefresh() }
        scheduleSettledRefresh()
    }

    private func scheduleSettledRefresh() {
        settlingTask?.cancel()
        settlingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            self.needsPageCheck = true
            if self.tracked?.hasUnmatchedQuotes == true || !(self.tracked?.recognizedRectangles.isEmpty ?? true) {
                self.needsRescan = true
            }
            self.requestRefresh()
        }
    }

    private func requestRefresh() {
        needsRefresh = true
        guard !refreshRunning else { return }
        refreshRunning = true
        Task {
            defer { refreshRunning = false }
            while needsRefresh || needsRescan {
                needsRefresh = false
                let rescan = needsRescan
                needsRescan = false
                let captured = pendingCapture
                pendingCapture = nil
                let checkPage = needsPageCheck || rescan || tracked == nil || captured != nil
                needsPageCheck = false
                let revision = generation
                let viewport = viewportRevision
                guard let model else { return }
                do {
                    if checkPage {
                        let pinned = try model.capture.currentTarget()
                        if model.library.highlights.isEmpty, !model.capture.isChromiumBrowser(pinned.bundleID) {
                            browserOwnsPage = false
                            tracked = nil
                            window.orderOut(nil)
                            continue
                        }
                        let target = try await model.capture.resolve(target: pinned)
                        guard generation == revision else { continue }
                        if !target.hasSameDocument(as: tracked?.target) {
                            tracked = nil
                            window.orderOut(nil)
                        }
                        let key = SourceIdentity.documentID(bundleID: target.bundleID, title: target.title, url: target.url)
                        let quotes = model.library.highlights.filter { $0.documentID == key }.map(\.quote)
                        let stickyURL = target.url.map(WindowCapture.stickyURL)
                        let notes = model.library.stickyNotes.filter { $0.url == stickyURL }
                        let paint = try await model.capture.paintBrowserHighlights(target: target, quotes: quotes, notes: notes) {
                            self.generation == revision && self.viewportRevision == viewport
                        }
                        guard generation == revision else { continue }
                        browserNeedsRetry = paint == .deferred
                        browserOwnsPage = paint != .unsupported
                        if browserOwnsPage || quotes.isEmpty {
                            tracked = nil
                            window.orderOut(nil)
                            continue
                        }
                        if let captured, target.hasSameDocument(as: captured.target), captured.target.frame == target.frame {
                            let candidate = try await model.capture.trackHighlights(in: captured, quotes: quotes)
                            guard generation == revision else { continue }
                            tracked = candidate
                            recognizedIsCurrent = false
                            if !candidate.recognizedRectangles.isEmpty { needsRescan = true }
                        } else if rescan || !target.hasSameDocument(as: tracked?.target) {
                            let result = try await model.capture.capture(target: target, attachmentDirectory: model.attachments,
                                                                         persistImage: false, askForAutomation: false)
                            guard generation == revision else { continue }
                            let candidate = try await model.capture.trackHighlights(in: result, quotes: quotes)
                            guard generation == revision else { continue }
                            tracked = candidate
                            recognizedIsCurrent = viewport == viewportRevision
                            if !recognizedIsCurrent, !candidate.recognizedRectangles.isEmpty { scheduleSettledRefresh() }
                        }
                    }
                    guard let tracked else { continue }
                    let includesRecognized = recognizedIsCurrent && !tracked.recognizedRectangles.isEmpty
                    let frame = try await model.capture.highlightFrame(tracked, includeRecognized: includesRecognized)
                    guard generation == revision else { continue }
                    if includesRecognized, viewport != viewportRevision { needsRefresh = true; continue }
                    show(frame)
                } catch {
                    guard generation == revision else { continue }
                    let hadTracking = tracked != nil
                    tracked = nil
                    window.orderOut(nil)
                    if !rescan, hadTracking || error as? WindowCaptureError == .sourceChanged { needsRescan = true }
                }
            }
        }
    }

    private func show(_ frame: HighlightFrame) {
        guard let model,
              let active = try? model.capture.currentTarget(),
              active.pid == frame.target.pid, active.windowID == frame.target.windowID,
              active.frame == frame.target.frame, !frame.rectangles.isEmpty else {
            window.orderOut(nil)
            return
        }
        let source = frame.target.frame
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let placement = NSRect(x: source.minX, y: desktopTop - source.maxY, width: source.width, height: source.height)
        if window.frame != placement { window.setFrame(placement, display: false) }
        drawing.rectangles = frame.rectangles.map { rect in
            NSRect(x: rect.minX - source.minX, y: source.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        if !window.isVisible { window.orderFrontRegardless() }
    }
}

private extension WindowTarget {
    func hasSameDocument(as other: WindowTarget?) -> Bool {
        guard let other, pid == other.pid, windowID == other.windowID else { return false }
        return url == other.url && (url != nil || title == other.title)
    }
}

final class HighlightDrawingView: NSView {
    var rectangles: [NSRect] = [] {
        didSet { if oldValue != rectangles { needsDisplay = true } }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemYellow.withAlphaComponent(0.22).setFill()
        for rect in rectangles { NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill() }
    }
}
