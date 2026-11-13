import AppKit
import Combine
import SwiftUI

@main
enum MarginMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var item: NSStatusItem?
    private let shortcuts = GlobalShortcuts()
    private var composer: FloatingPanel?
    private var sidebar: FloatingPanel?
    private var overlays: HighlightOverlays?
    private var layoutSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let model = try AppModel(directory: support.appendingPathComponent("Margin", isDirectory: true))
            self.model = model
            layoutSubscription = model.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async { self?.fitComposer() }
            }
            setupMenu()
            overlays = HighlightOverlays(model: model)
            shortcuts.onComposer = { [weak self] in self?.showComposer() }
            shortcuts.onSidebar = { [weak self] in self?.toggleSidebar() }
            try shortcuts.register()
            if !UserDefaults.standard.bool(forKey: "hasOpenedMargin") {
                model.showingSettings = true
                showSidebar(capture: false)
                UserDefaults.standard.set(true, forKey: "hasOpenedMargin")
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Margin could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { model?.cancel() }

    private func setupMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Margin")
        let menu = NSMenu()
        menu.addItem(withTitle: "Ask about this window   ⌥`", action: #selector(ask), keyEquivalent: "")
        menu.addItem(withTitle: "Threads and highlights   ⌥⇧`", action: #selector(history), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Margin", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        item?.menu = menu
        let main = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func ask() { showComposer() }
    @objc private func history() { toggleSidebar() }
    @objc private func settings() { model?.showingSettings = true; showSidebar(capture: false) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showComposer() {
        guard let model else { return }
        model.beginCapture(newThread: model.selectedThreadID == nil)
        sidebar?.orderOut(nil)
        if composer == nil {
            composer = FloatingPanel()
            let view = ComposerView(model: model, close: { [weak self] in self?.composer?.orderOut(nil) },
                                    history: { [weak self] in self?.showSidebar(capture: false) })
            let host = FirstClickHostingView(rootView: view)
            host.sizingOptions = [.preferredContentSize]
            composer?.contentView = host
        }
        guard let composer else { return }
        fitComposer()
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = composer.frame.height
        composer.setFrameOrigin(NSPoint(x: min(max(point.x + 14, visible.minX), visible.maxX - 420),
                                       y: max(visible.minY, min(point.y - height - 12, visible.maxY - height))))
        composer.makeKeyAndOrderFront(nil)
    }

    private func fitComposer() {
        guard let composer, let content = composer.contentView else { return }
        let size = content.fittingSize
        guard size.height.isFinite, size.height > 0 else { return }
        let screen = composer.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = min(size.height, visible.height - 24)
        let top = min(composer.frame.maxY, visible.maxY - 12)
        composer.setFrame(NSRect(x: min(max(composer.frame.minX, visible.minX + 12), visible.maxX - 432),
                                y: max(visible.minY + 12, top - height), width: 420, height: height), display: true)
    }

    private func toggleSidebar() {
        if sidebar?.isVisible == true { sidebar?.orderOut(nil) }
        else { showSidebar(capture: true) }
    }

    private func showSidebar(capture: Bool) {
        guard let model else { return }
        if capture { model.beginCapture(newThread: true) }
        composer?.orderOut(nil)
        if sidebar == nil {
            sidebar = FloatingPanel()
            sidebar?.contentView = FirstClickHostingView(rootView: SidebarView(model: model, close: { [weak self] in self?.sidebar?.orderOut(nil) }))
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        sidebar?.setFrame(NSRect(x: frame.maxX - 440, y: frame.minY + 12, width: 420, height: frame.height - 24), display: true)
        sidebar?.makeKeyAndOrderFront(nil)
    }
}

final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
