import AppKit
import MarginCore
import SwiftUI

private enum ReadingStyle {
    static let composer = Color(red: 0.085, green: 0.095, blue: 0.11)
    static let sidebar = Color(red: 0.035, green: 0.04, blue: 0.05)
    static let surface = Color.white.opacity(0.055)
    static let border = Color.white.opacity(0.09)
}

struct ComposerView: View {
    @ObservedObject var model: AppModel
    var close: () -> Void
    var history: () -> Void
    var resize: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack(alignment: .leading) {
                    WindowDragHandle()
                    HStack {
                        Text(model.context?.title ?? model.target?.appName ?? "Margin")
                            .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }.foregroundStyle(.secondary).allowsHitTesting(false)
                }.frame(maxWidth: .infinity).frame(height: 22).help("Drag to move Margin")
                SourceLink(value: model.context?.url, iconOnly: true)
                Button("Recent threads", systemImage: "sidebar.right", action: history)
                    .labelStyle(.iconOnly).help("Recent threads · ⌃⇧H")
                Button("Close", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly).help("Close · Esc")
            }.buttonStyle(ReadingIconStyle())
            ConversationView(model: model)
        }
        .padding(14)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { resize(geometry.size) }
                    .onChange(of: geometry.size) { _, size in resize(size) }
            }
        }
        .background(ReadingStyle.composer, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(ReadingStyle.border))
        .preferredColorScheme(.dark)
        .onExitCommand(perform: close)
    }
}

struct ConversationView: View {
    @ObservedObject var model: AppModel
    var compact = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let context = model.context {
                if !compact {
                    HStack(alignment: .top) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(context.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            SourceLink(value: context.url)
                        }
                        Spacer(minLength: 4)
                        Button("Refresh page context", systemImage: "arrow.clockwise") { model.beginCapture(newThread: false) }
                            .labelStyle(.iconOnly)
                            .help("Capture the source window again").disabled(model.preparingQuestion)
                            .buttonStyle(ReadingIconStyle())
                    }
                }
                if let selection = context.selection, !selection.isEmpty {
                    HStack(alignment: .top) {
                        Rectangle().fill(.yellow.opacity(0.5)).frame(width: 2)
                        Text(selection).font(.callout).foregroundStyle(.secondary).lineLimit(compact ? 3 : 5).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).background(ReadingStyle.surface, in: RoundedRectangle(cornerRadius: 9))
                }
            } else if !compact {
                Text(model.target?.appName ?? "Current window")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let thread = model.selectedThread, !thread.messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(thread.messages) { message in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.role == .user ? "You" : "Margin")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    if message.status == .running, model.runningThreadID == thread.id {
                                        if !model.liveAnswer.isEmpty {
                                            Text(.init(model.liveAnswer)).font(.callout).textSelection(.enabled)
                                        }
                                        HStack(spacing: 8) {
                                            ProgressView().controlSize(.small)
                                            Text(model.activity.isEmpty ? "Working…" : model.activity).font(.callout).lineLimit(3)
                                        }
                                    } else if message.status == .running {
                                        Text("Unfinished reply from another session. Send a follow-up to continue.")
                                            .font(.callout).foregroundStyle(.secondary)
                                    } else {
                                        Text(.init(message.body.isEmpty ? "Response interrupted. Send a follow-up to continue." : message.body))
                                            .font(.callout).textSelection(.enabled)
                                        if message.status != .complete {
                                            Text(message.status.rawValue.capitalized).font(.caption).foregroundStyle(.orange)
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                            }
                        }.padding(.vertical, 4)
                    }
                    .frame(maxHeight: compact ? (model.unsavedAnswer == nil ? 290 : 100) : .infinity)
                    .onAppear {
                        if let id = thread.messages.last?.id { proxy.scrollTo(id, anchor: .top) }
                    }
                    .onChange(of: thread.messages.count) { _, _ in
                        if let id = thread.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                Divider()
            }

            if model.capturing || model.preparingQuestion {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.preparingQuestion ? "Preparing your question…" : "Reading context · you can type now").font(.caption)
                }.foregroundStyle(.secondary)
            }
            if let error = model.error {
                ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    .frame(maxHeight: 64)
            } else if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }

            if let answer = model.unsavedAnswer {
                Text("Unsaved replies — copy before quitting").font(.caption.weight(.semibold))
                ScrollView { Text(answer).font(.callout).textSelection(.enabled) }.frame(maxHeight: 160)
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        if !NSPasteboard.general.setString(answer, forType: .string) {
                            model.error = "Could not copy the unsaved replies. Select the text and copy it manually."
                        }
                    }
                    Spacer()
                    Button("Discard unsaved replies", role: .destructive) { model.discardUnsavedAnswers() }
                }.font(.caption)
            }
            input
        }
        .onAppear { requestFocus() }
        .onChange(of: model.composerFocusRequest) { _, _ in
            if compact { requestFocus() }
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Ask about this window…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit((compact ? 1 : 2)...5).focused($focused)
                .padding(.horizontal, 3).padding(.top, 4)
                .onSubmit { model.send() }
            HStack(spacing: 6) {
                Button("New thread", systemImage: "plus") { model.newThread() }
                    .labelStyle(.iconOnly).help("New thread").disabled(model.preparingQuestion)
                if model.context != nil {
                    Button("Save highlight", systemImage: "highlighter") { model.saveHighlight() }
                        .labelStyle(.iconOnly).help("Save selected text · ⌃⇧S").disabled(model.preparingQuestion)
                    if compact {
                        Button("Refresh page context", systemImage: "arrow.clockwise") { model.beginCapture(newThread: false) }
                            .labelStyle(.iconOnly).help("Capture the source window again").disabled(model.preparingQuestion)
                    }
                }
                ModelChoiceView(model: model)
                Spacer(minLength: 4)
                if model.runningThreadID != nil {
                    Button("Stop", systemImage: "stop.fill") { model.cancel() }
                        .labelStyle(.iconOnly).buttonStyle(SendButtonStyle()).help("Stop response")
                } else {
                    Button("Ask", systemImage: "arrow.up") { model.send() }
                        .labelStyle(.iconOnly).keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(SendButtonStyle()).help("Ask · ⌘Return")
                        .disabled(!model.canAsk || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.buttonStyle(ReadingIconStyle())
        }
        .padding(compact ? 0 : 12)
        .background(compact ? Color.clear : ReadingStyle.composer, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(compact ? Color.clear : ReadingStyle.border))
    }

    private func requestFocus() {
        focused = false
        DispatchQueue.main.async { focused = true }
    }
}

struct ModelChoiceView: View {
    @ObservedObject var model: AppModel
    @State private var showingChoices = false

    var body: some View {
        Button { showingChoices.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                Text(model.activeAgent.label.isEmpty ? "Choose a model" : model.activeAgent.label)
                    .lineLimit(1).truncationMode(.middle)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(model.preparingQuestion || model.runningThreadID != nil)
        .popover(isPresented: $showingChoices, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Model for this conversation").font(.headline)
                Picker("Provider", selection: $model.composerConfiguration.backend) {
                    Text("Codex").tag(AgentConfiguration.Backend.codex)
                    Text("Claude Code").tag(AgentConfiguration.Backend.claude)
                    Text("OpenAI-compatible API").tag(AgentConfiguration.Backend.openAI)
                }.disabled(model.selectedThread != nil)
                ModelNamePicker(configuration: $model.composerConfiguration)
                if model.composerConfiguration.backend == .openAI {
                    Text(model.composerConfiguration.api.baseURL).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Toggle("Include window images", isOn: $model.composerConfiguration.includesImages)
                    Text("Configure the server and key in Settings → Models.").font(.caption).foregroundStyle(.secondary)
                }
                if model.selectedThread != nil {
                    Text("The next reply uses this model with the conversation’s history. Start a new thread to change providers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Use as default") { model.useComposerModelAsDefault() }
                    Spacer()
                    Button("Done") { showingChoices = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(16).frame(width: 300).preferredColorScheme(.dark)
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    var editNote: (StickyNote) -> Void
    var close: () -> Void
    @State private var filter = 0
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if model.sidebarShowsConversation, !model.showingSettings {
                    Button("Back to library", systemImage: "chevron.left") { model.sidebarShowsConversation = false }
                        .labelStyle(.iconOnly)
                } else {
                    Image(systemName: "sidebar.left").foregroundStyle(.secondary)
                }
                Text(model.showingSettings ? "Settings" : "Margin").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Settings", systemImage: "gearshape") { model.showingSettings.toggle() }.labelStyle(.iconOnly)
                Button("Close", systemImage: "xmark", action: close).labelStyle(.iconOnly)
            }.buttonStyle(ReadingIconStyle()).padding(.horizontal, 4)
            if model.showingSettings {
                SettingsView(model: model)
            } else if model.sidebarShowsConversation {
                ConversationView(model: model, compact: false)
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: $search).textFieldStyle(.plain)
                            .accessibilityLabel("Search your library")
                    }.font(.system(size: 14)).padding(10)
                        .background(ReadingStyle.surface, in: RoundedRectangle(cornerRadius: 9))
                    Button("New thread", systemImage: "square.and.pencil") {
                        model.newThread()
                        model.sidebarShowsConversation = true
                    }.labelStyle(.iconOnly).buttonStyle(ReadingIconStyle()).disabled(model.preparingQuestion)
                }
                Picker("Library filter", selection: $filter) {
                    Text("Recent").tag(0)
                    Text("This page").tag(1)
                    Text("Highlights").tag(2)
                    Text("Notes").tag(3)
                }.pickerStyle(.segmented).controlSize(.small).labelsHidden()
                if filter == 1 {
                    Text(model.pageContext?.title ?? "Capture a window with Control–Shift–Space first.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 8)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if filter == 3 {
                            let notes = model.library.stickyNotes.reversed().filter {
                                search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.url.localizedCaseInsensitiveContains(search)
                            }
                            ForEach(notes) { note in
                                VStack(alignment: .leading, spacing: 7) {
                                    Button { editNote(note) } label: {
                                        Label(note.text, systemImage: "note.text").lineLimit(4)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain).help("Edit sticky note")
                                    SourceLink(value: note.url)
                                }.padding(12).background(ReadingStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                            }
                            if notes.isEmpty { empty(search.isEmpty ? "Point at a Chrome page and press ⌃⇧N to add a sticky note." : "No matching notes.") }
                        } else if filter == 2 {
                            let highlights = model.library.highlights.sorted { $0.createdAt > $1.createdAt }
                                .filter { search.isEmpty || $0.quote.localizedCaseInsensitiveContains(search) }
                            ForEach(highlights) { highlight in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top, spacing: 10) {
                                        RoundedRectangle(cornerRadius: 1).fill(.yellow.opacity(0.5)).frame(width: 2)
                                        Text(highlight.quote).font(.system(size: 14)).lineLimit(5).textSelection(.enabled)
                                    }.fixedSize(horizontal: false, vertical: true)
                                    if let document = model.library.documents.first(where: { $0.id == highlight.documentID }) {
                                        Text(document.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        SourceLink(value: document.url)
                                    }
                                    HStack {
                                        Button("Ask about this", systemImage: "text.bubble") { model.useHighlight(highlight) }
                                            .disabled(model.preparingQuestion)
                                        Spacer()
                                        Button("Delete highlight", systemImage: "trash", role: .destructive) { model.removeHighlight(highlight.id) }
                                            .labelStyle(.iconOnly).help("Delete highlight")
                                    }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                                }.padding(12).background(ReadingStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                                    .padding(.bottom, 5)
                            }
                            if highlights.isEmpty { empty("No matching saved highlights.") }
                        } else {
                            let threads = filter == 0 ? model.recentThreads : model.currentThreads
                            let matching = threads.filter {
                                search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
                                    $0.messages.contains { $0.body.localizedCaseInsensitiveContains(search) }
                            }
                            ForEach(matching) { thread in
                                ReadingThreadRow(thread: thread, document: model.document(for: thread),
                                                 selected: model.selectedThreadID == thread.id,
                                                 running: model.runningThreadID == thread.id,
                                                 disabled: model.preparingQuestion) { model.openThread(thread) }
                            }
                            if matching.isEmpty { empty(search.isEmpty ? "Your conversations will appear here." : "No matching conversations.") }
                        }
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: "externaldrive")
                    Text("Saved on this Mac")
                    Spacer()
                    Text("⌃⇧H")
                }.font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 8)
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(4) }
            }
        }
        .padding(14).frame(width: 420)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ReadingStyle.sidebar)
        .overlay(Rectangle().strokeBorder(ReadingStyle.border))
        .preferredColorScheme(.dark)
        .onExitCommand(perform: close)
    }

    private func empty(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "text.bubble").font(.title2)
            Text(text).font(.callout)
            Text("Press ⌃⇧Space to ask, or ⌃⇧S to save a passage.").font(.caption)
        }.foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 28)
    }
}

private struct ReadingThreadRow: View {
    let thread: ThreadRecord
    let document: DocumentRecord?
    let selected: Bool
    let running: Bool
    let disabled: Bool
    var open: () -> Void
    @State private var hovered = false

    private var provider: String {
        switch thread.agent?.backend ?? .codex {
        case .codex: "Codex"
        case .claude: "Claude"
        case .openAI: "API"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 7) {
                        Image(systemName: document?.url == nil ? "macwindow" : "globe")
                            .font(.system(size: 12)).foregroundStyle(.mint)
                        Text(document?.title ?? "Window").lineLimit(1)
                        Spacer(minLength: 8)
                        if running {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.mini)
                                Text("Working")
                            }.foregroundStyle(.blue)
                        } else {
                            Text(thread.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                                .lineLimit(1).fixedSize()
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(thread.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(disabled)
            HStack {
                SourceLink(value: thread.messages.compactMap { $0.context?.url }.first ?? document?.url)
                Spacer()
                Text(provider).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(ReadingStyle.surface, in: Capsule())
            }
        }
        .padding(12)
        .background(Color.white.opacity(selected ? 0.10 : (hovered ? 0.045 : 0)), in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovered = $0 }
    }
}

private struct ReadingIconStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14)).foregroundStyle(.secondary)
            .frame(minWidth: 26, minHeight: 26)
            .background(Color.white.opacity(configuration.isPressed ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.35)
    }
}

private struct SendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold))
            .foregroundStyle(ReadingStyle.composer)
            .frame(width: 32, height: 32)
            .background(.white.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.25), in: Circle())
    }
}

private struct SourceLink: View {
    let value: String?
    var iconOnly = false

    var body: some View {
        if let value, let url = URL(string: value),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let host = url.host, !host.isEmpty, url.user == nil, url.password == nil {
            Link(destination: url) {
                if iconOnly {
                    Image(systemName: "globe").frame(width: 26, height: 26)
                } else {
                    Label(host, systemImage: "arrow.up.right.square").lineLimit(1)
                }
            }.font(.caption2).help("Open source: \(url.absoluteString)")
                .accessibilityLabel("Open source: \(host)")
        }
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
