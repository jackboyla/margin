import AppKit
import MarginCore
import SwiftUI

enum StickyPlacementError: LocalizedError {
    case outsidePage, outsidePaper, automation, differentPage, unsupported

    var errorDescription: String? {
        switch self {
        case .outsidePage: return "Point at a webpage in Chrome to place a sticky note."
        case .outsidePaper: return "Margin couldn’t locate that spot on the PDF page. If Chrome’s drawing tools are active, close them and try again."
        case .unsupported: return "Sticky notes work on regular webpages and readable arXiv PDFs in Chrome."
        case .automation: return "Allow browser Automation for Margin and enable Chrome → View → Developer → Allow JavaScript from Apple Events."
        case .differentPage: return "Open this note’s original page in Chrome to move it."
        }
    }
}

@MainActor
final class StickyNotesController {
    private let model: AppModel
    private let notify: (String, Bool) -> Void
    private var editor: FloatingPanel?
    private var editedID: UUID?
    private var picker: FloatingPanel?
    private var activation: NSObjectProtocol?
    private var locating = false

    init(model: AppModel, notify: @escaping (String, Bool) -> Void) {
        self.model = model
        self.notify = notify
    }

    func openAtPointer() {
        if let editor, editor.isVisible { editor.makeKeyAndOrderFront(nil); return }
        guard let point = CGEvent(source: nil)?.location else { return }
        locate(point: point)
    }

    private func locate(point: CGPoint, expected: WindowTarget? = nil, moving: StickyNote? = nil) {
        guard !locating else { return }
        locating = true
        Task {
            defer { locating = false }
            do {
                let place = try await model.capture.locateStickyNote(at: point, expected: expected)
                var note: StickyNote
                if let moving {
                    guard moving.url == place.url else { throw StickyPlacementError.differentPage }
                    note = moving
                    note.anchor = place.anchor
                } else if let existing = model.library.stickyNotes.first(where: { $0.id == place.id && $0.url == place.url }) {
                    note = existing
                } else {
                    note = StickyNote(url: place.url, text: "", anchor: place.anchor)
                }
                edit(note)
            } catch {
                if let moving { edit(moving) }
                notify(error.localizedDescription, false)
            }
        }
    }

    func chooseSpot(moving: StickyNote? = nil) {
        guard picker == nil, !locating else { return }
        if moving == nil, let editor, editor.isVisible { editor.makeKeyAndOrderFront(nil); return }
        locating = true
        Task {
            defer { locating = false }
            do {
                try model.capture.requireSelectionAccess()
                let pinned = try model.capture.currentTarget()
                let target = try await model.capture.resolve(target: pinned, askForAutomation: true)
                guard model.capture.isChromiumBrowser(target.bundleID), let url = target.url,
                      ["http", "https"].contains(URL(string: url)?.scheme ?? "") else { throw StickyPlacementError.outsidePage }
                if let moving, moving.url != WindowCapture.stickyURL(url) { throw StickyPlacementError.differentPage }

                editor?.orderOut(nil)
                let panel = FloatingPanel()
                picker = panel
                panel.hasShadow = false
                panel.isMovable = false
                let surface = StickyPlacementView()
                surface.pick = { [weak self] point in
                    self?.endPlacement()
                    self?.locate(point: point, expected: target, moving: moving)
                }
                surface.cancel = { [weak self] in
                    self?.endPlacement()
                    if let moving { self?.edit(moving) }
                }
                panel.contentView = surface
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                let frame = target.frame
                panel.setFrame(NSRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height), display: false)
                activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil, queue: .main) { [weak self] notification in
                    let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                    if pid != target.pid && pid != ProcessInfo.processInfo.processIdentifier {
                        Task { @MainActor in
                            self?.endPlacement()
                            if moving != nil { self?.editor?.orderFront(nil) }
                        }
                    }
                }
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(surface)
            } catch { notify(error.localizedDescription, false) }
        }
    }

    private func endPlacement() {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        picker?.orderOut(nil)
        picker = nil
    }

    func edit(_ note: StickyNote) {
        endPlacement()
        if let editor, editor.isVisible {
            editor.makeKeyAndOrderFront(nil)
            if editedID != note.id { notify("Save or close the open sticky note before editing another.", false) }
            return
        }
        editedID = note.id
        let panel = editor ?? FloatingPanel()
        editor = panel
        let existing = model.library.stickyNotes.contains { $0.id == note.id }
        let close: () -> Void = { [weak self] in self?.editor?.orderOut(nil) }
        let view = StickyNoteEditor(note: note, exists: existing, save: { [model] edited in
            try await model.saveStickyNote(edited)
            close()
        }, remove: { [model] in
            try await model.deleteStickyNote(note.id)
            close()
        }, move: { [weak self] draft in self?.chooseSpot(moving: draft) }, close: { close() })
        panel.contentView = FirstClickHostingView(rootView: view.id(note.id))
        let point = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = NSSize(width: 308, height: 240)
        panel.setFrame(NSRect(x: max(visible.minX, min(point.x + 10, visible.maxX - size.width)),
                              y: max(visible.minY, min(point.y - size.height - 8, visible.maxY - size.height)),
                              width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

private final class StickyPlacementView: NSView {
    var pick: ((CGPoint) -> Void)?
    var cancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseUp(with event: NSEvent) {
        if let point = event.cgEvent?.location { pick?(point) }
    }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) { cancel?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { cancel?() } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.025).setFill()
        bounds.fill()
        let hint = "Click to place the sticky note   ·   Esc to cancel" as NSString
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let size = hint.size(withAttributes: style)
        let box = NSRect(x: (bounds.width - size.width) / 2 - 12, y: 18, width: size.width + 24, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.86).setFill()
        NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
        hint.draw(at: CGPoint(x: box.minX + 12, y: box.minY + 7), withAttributes: style)
    }
}

private struct StickyNoteEditor: View {
    @State var note: StickyNote
    let exists: Bool
    let save: (StickyNote) async throws -> Void
    let remove: () async throws -> Void
    let move: (StickyNote) -> Void
    let close: () -> Void
    @FocusState private var focused: Bool
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Sticky note", systemImage: "note.text")
                Spacer()
                Button("Close", systemImage: "xmark", action: close).labelStyle(.iconOnly)
            }.buttonStyle(.plain)
            TextEditor(text: $note.text).focused($focused).font(.body)
                .scrollContentBackground(.hidden).accessibilityLabel("Note text")
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if exists {
                    Button("Delete", systemImage: "trash", role: .destructive) { run { try await remove() } }
                        .labelStyle(.iconOnly).help("Delete note")
                }
                Button("Move…") { move(note) }
                Spacer()
                Button("Save") { run { try await save(note) } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(busy).padding(14).foregroundStyle(Color(red: 0.18, green: 0.15, blue: 0.08))
        .background(Color(red: 1, green: 0.94, blue: 0.69), in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .light)
        .onAppear { focused = true }
        .onExitCommand(perform: close)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}
