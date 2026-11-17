import AppKit
import MarginCore

@MainActor
final class HighlightOverlays {
    private weak var model: AppModel?
    private let window: NSWindow
    private let drawing = HighlightDrawingView()
    private var settlingTask: Task<Void, Never>?
    private var refreshRunning = false
    private var needsRefresh = false
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
            if let active = try? self.model?.capture.currentTarget(),
               active.pid == result.target.pid, active.windowID == result.target.windowID {
                self.pendingCapture = result
            } else {
                self.pendingCapture = nil
                self.needsRescan = true
            }
            self.requestRefresh()
        }
        model.onLibraryChange = { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.needsRescan = true
            self.requestRefresh()
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseUp, .leftMouseDragged, .keyUp]) { [weak self] event in
            let moved = event.type == .scrollWheel || event.type == .leftMouseDragged || event.type == .keyUp
            Task { @MainActor in self?.interaction(moved: moved) }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model?.capture.prepareAccessibilityForFrontmostApplication()
                if let target = try? self.model?.capture.currentTarget(),
                   target.pid != self.tracked?.target.pid || target.windowID != self.tracked?.target.windowID {
                    self.generation += 1
                    self.tracked = nil
                    self.window.orderOut(nil)
                }
                self.interaction(moved: true)
            }
        }
        model.capture.prepareAccessibilityForFrontmostApplication()
        requestRefresh()
    }

    private func interaction(moved: Bool) {
        if moved { recognizedIsCurrent = false; viewportRevision += 1 }
        requestRefresh()
        scheduleSettledRefresh()
    }

    private func scheduleSettledRefresh() {
        settlingTask?.cancel()
        settlingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            // A cached native range follows scrolling without another screenshot or tree walk.
            if self.tracked == nil || self.tracked?.hasUnmatchedQuotes == true ||
                !(self.tracked?.recognizedRectangles.isEmpty ?? true) { self.needsRescan = true }
            self.requestRefresh()
        }
    }

    private func requestRefresh() {
        needsRefresh = true
        guard !refreshRunning else { return }
        refreshRunning = true
        Task {
            defer { refreshRunning = false }
            while needsRefresh || needsRescan || pendingCapture != nil {
                needsRefresh = false
                let rescan = needsRescan
                needsRescan = false
                let captured = pendingCapture
                pendingCapture = nil
                let revision = generation
                let viewport = viewportRevision
                guard let model, !model.library.highlights.isEmpty else {
                    tracked = nil
                    window.orderOut(nil)
                    continue
                }
                do {
                    if let captured {
                        let candidate = try await makeTracking(captured, model: model)
                        guard revision == generation else { needsRefresh = true; continue }
                        tracked = candidate
                        recognizedIsCurrent = false
                        if !(tracked?.recognizedRectangles.isEmpty ?? true) { needsRescan = true }
                    } else if rescan || tracked == nil {
                        let pinned = try model.capture.currentTarget()
                        let target = try await model.capture.resolve(target: pinned)
                        guard revision == generation else { needsRefresh = true; continue }
                        let key = SourceIdentity.documentID(bundleID: target.bundleID, title: target.title, url: target.url)
                        guard model.library.highlights.contains(where: { $0.documentID == key }) else {
                            tracked = nil
                            window.orderOut(nil)
                            continue
                        }
                        let result = try await model.capture.capture(target: target, attachmentDirectory: model.attachments, persistImage: false)
                        let candidate = try await makeTracking(result, model: model)
                        guard revision == generation else { needsRefresh = true; continue }
                        tracked = candidate
                        recognizedIsCurrent = viewport == viewportRevision
                        if !recognizedIsCurrent, !candidate.recognizedRectangles.isEmpty { scheduleSettledRefresh() }
                    }
                    guard revision == generation, let tracked else { needsRefresh = true; continue }
                    let includesRecognized = recognizedIsCurrent && !tracked.recognizedRectangles.isEmpty
                    let frame = try await model.capture.highlightFrame(tracked, includeRecognized: includesRecognized)
                    guard revision == generation else { needsRefresh = true; continue }
                    if includesRecognized, viewport != viewportRevision { needsRefresh = true; continue }
                    show(frame)
                } catch {
                    let hadTracking = tracked != nil
                    tracked = nil
                    window.orderOut(nil)
                    if hadTracking, captured != nil || !rescan { needsRescan = true }
                }
            }
        }
    }

    private func makeTracking(_ captured: CapturedWindow, model: AppModel) async throws -> TrackedHighlights {
        let quotes = model.library.highlights.filter { $0.documentID == captured.context.documentID }.map(\.quote)
        return try await model.capture.trackHighlights(in: captured, quotes: quotes)
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

final class HighlightDrawingView: NSView {
    var rectangles: [NSRect] = [] {
        didSet { if oldValue != rectangles { needsDisplay = true } }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemYellow.withAlphaComponent(0.22).setFill()
        for rect in rectangles { NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill() }
    }
}
