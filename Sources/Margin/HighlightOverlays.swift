import AppKit
import MarginCore

@MainActor
final class HighlightOverlays {
    private weak var model: AppModel?
    private let window: NSWindow
    private let drawing = HighlightDrawingView()
    private var current: CapturedWindow?
    private var refreshTask: Task<Void, Never>?
    private var refreshRunning = false
    private var needsRefresh = false
    private var generation = 0
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
        model.onCapture = { [weak self] result in self?.show(result) }
        model.onLibraryChange = { [weak self] in
            guard let self, let current = self.current else { return }
            self.show(current)
        }
        // Redraw only after interaction settles. No continuous screen recording or timer.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseUp, .keyUp]) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.scheduleRefresh() } }
    }

    private func scheduleRefresh() {
        window.orderOut(nil)
        generation += 1
        needsRefresh = true
        refreshTask?.cancel()
        guard let model, !model.library.highlights.isEmpty else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.refreshIfNeeded()
        }
    }

    private func refreshIfNeeded() {
        guard needsRefresh, !refreshRunning, let model else { return }
        needsRefresh = false
        refreshRunning = true
        let revision = generation
        Task {
            defer {
                refreshRunning = false
                if needsRefresh { scheduleRefresh() }
            }
            do {
                let target = try model.capture.currentTarget()
                let key = SourceIdentity.documentID(bundleID: target.bundleID, title: target.title, url: target.url)
                guard model.library.highlights.contains(where: { $0.documentID == key }) else { return }
                let result = try await model.capture.capture(target: target, attachmentDirectory: model.attachments, persistImage: false)
                guard generation == revision else { return }
                show(result)
            } catch { window.orderOut(nil) }
        }
    }

    private func show(_ captured: CapturedWindow) {
        current = captured
        guard let model else { return }
        let saved = model.library.highlights.filter { $0.documentID == captured.context.documentID }
        let lines = captured.ocrLines
        let indices = Set(saved.flatMap { HighlightMatcher.matchedLineIndices(quote: $0.quote, lines: lines.map(\.text)) })
        guard !indices.isEmpty else { window.orderOut(nil); return }
        let frame = captured.target.frame
        // CoreGraphics uses a top-left desktop origin; AppKit uses a bottom-left origin.
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        window.setFrame(NSRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height), display: true)
        drawing.rectangles = indices.sorted().map { i in
            let rect = lines[i].bounds
            return NSRect(x: rect.minX * frame.width, y: rect.minY * frame.height,
                          width: rect.width * frame.width, height: rect.height * frame.height)
        }
        window.orderFrontRegardless()
    }
}

final class HighlightDrawingView: NSView {
    var rectangles: [NSRect] = [] { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemYellow.withAlphaComponent(0.22).setFill()
        for rect in rectangles { NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -1), xRadius: 2, yRadius: 2).fill() }
    }
}
