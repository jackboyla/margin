import AppKit
import MarginCore
import SwiftUI

struct ComposerView: View {
    @ObservedObject var model: AppModel
    var close: () -> Void
    var history: () -> Void
    var resize: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "text.bubble.fill").foregroundStyle(.orange)
                Text("Margin").font(.headline)
                Spacer()
                Button(action: history) { Image(systemName: "sidebar.right") }.help("Recent threads · ⌃⇧H")
                Button(action: close) { Image(systemName: "xmark") }.help("Close · Esc")
            }.buttonStyle(.plain)
            ConversationView(model: model)
        }
        .padding(18)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { resize(geometry.size) }
                    .onChange(of: geometry.size) { _, size in resize(size) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.10)))
        .onExitCommand(perform: close)
    }
}

struct ConversationView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let context = model.context {
                HStack(alignment: .top) {
                    Image(systemName: "macwindow").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.title).font(.caption.weight(.medium)).lineLimit(2)
                        if let url = context.url {
                            Text(URL(string: url)?.host ?? url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Button { model.saveHighlight() } label: { Image(systemName: "highlighter") }
                        .help("Save the current selection without asking a question").disabled(model.capturing)
                    Button { model.beginCapture(newThread: false) } label: { Image(systemName: "arrow.clockwise") }
                        .help("Capture the source window again").disabled(model.capturing)
                }.buttonStyle(.plain)
                if let selection = context.selection, !selection.isEmpty {
                    HStack(alignment: .top) {
                        Rectangle().fill(.yellow.opacity(0.8)).frame(width: 3)
                        Text(selection).font(.callout).lineLimit(4).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8).background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                Text("Open a page or document, then press Control–Shift–Space to ask about it.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let thread = model.selectedThread, !thread.messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(thread.messages) { message in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.role == .user ? "You" : "Margin")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    if message.status == .running {
                                        HStack(spacing: 8) {
                                            ProgressView().controlSize(.small)
                                            Text(model.activity.isEmpty ? "Working…" : model.activity).font(.callout).lineLimit(3)
                                        }
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
                    .frame(maxHeight: 290)
                    .onChange(of: thread.messages.count) { _, _ in
                        if let id = thread.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                Divider()
            }

            if model.capturing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading this window…").font(.caption) }
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }

            if let answer = model.unsavedAnswer {
                ScrollView { Text(answer).font(.callout).textSelection(.enabled) }.frame(maxHeight: 160)
            }
            TextField("Ask about this window…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain).font(.body).lineLimit(2...5).focused($focused)
                .padding(10).background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                .onSubmit { model.send() }
            HStack {
                Button("New thread") { model.newThread() }.buttonStyle(.plain).font(.caption)
                    .disabled(model.capturing)
                Spacer()
                if model.runningThreadID != nil {
                    Button("Stop", role: .destructive) { model.cancel() }
                } else {
                    Button("Ask", systemImage: "arrow.up") { model.send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent).tint(.orange)
                        .disabled(model.capturing || model.context == nil || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.onAppear { focused = true }
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    var close: () -> Void
    @State private var filter = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Margin").font(.title2.weight(.semibold))
                Spacer()
                Button { model.showingSettings.toggle() } label: { Image(systemName: "gearshape") }
                Button(action: close) { Image(systemName: "xmark") }
            }.buttonStyle(.plain)
            if model.showingSettings {
                SettingsView(model: model)
                Spacer()
            } else {
                Picker("History", selection: $filter) {
                    Text("Recent").tag(0)
                    Text("This page").tag(1)
                    Text("Highlights").tag(2)
                }.pickerStyle(.segmented)
                if filter != 0 {
                    Text(model.pageContext?.title ?? "Capture a window with Control–Shift–Space first.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if filter == 2 {
                            ForEach(model.currentHighlights) { highlight in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(highlight.quote).font(.callout).lineLimit(5).textSelection(.enabled)
                                    HStack {
                                        Button("Ask about this") { model.useHighlight(highlight) }.disabled(model.capturing)
                                        Spacer()
                                        Button(role: .destructive) { model.removeHighlight(highlight.id) } label: { Image(systemName: "trash") }
                                            .help("Delete highlight")
                                    }.buttonStyle(.plain).font(.caption)
                                }.padding(10).background(.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                            }
                            if model.currentHighlights.isEmpty { empty("No saved highlights for this page.") }
                        } else {
                            let threads = filter == 0 ? model.recentThreads : model.currentThreads
                            ForEach(threads) { thread in
                                Button { model.openThread(thread) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(thread.title).font(.callout.weight(.medium)).lineLimit(2)
                                        Text(model.document(for: thread)?.title ?? "Window")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Text(thread.updatedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    .background(model.selectedThreadID == thread.id ? Color.orange.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                                }.buttonStyle(.plain).disabled(model.capturing)
                            }
                            if threads.isEmpty { empty("Your conversations will appear here.") }
                        }
                    }
                }.frame(maxHeight: model.selectedThread == nil ? 260 : 190)
                Divider()
                ConversationView(model: model)
                Spacer(minLength: 0)
            }
        }
        .padding(18).frame(width: 420)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .onExitCommand(perform: close)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var refresh = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Read where you are.").font(.headline)
            Text("Control–Shift–Space opens a question beside your pointer.\nControl–Shift–H opens your threads and highlights.").font(.callout)
            GroupBox("Window access") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Margin reads the window you choose. Questions send its captured text and image to your configured Codex agent; saved highlights stay on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(model.capture.accessibilityPermission ? "Accessibility enabled" : "Enable Accessibility") {
                        model.capture.requestAccessibilityPermission()
                        refresh.toggle()
                    }
                    Button(model.capture.screenCapturePermission ? "Screen capture enabled" : "Enable Screen Capture") {
                        model.capture.requestScreenCapturePermission()
                        refresh.toggle()
                    }
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
                    }.buttonStyle(.link)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }.id(refresh)
            GroupBox("Coding agent") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Codex executable").font(.caption)
                    TextField("Path to codex", text: $model.executablePath).textFieldStyle(.roundedBorder)
                    Text("Working folder").font(.caption)
                    TextField("Working folder", text: $model.workspacePath).textFieldStyle(.roundedBorder)
                    Text("Uses your existing Codex sign-in. This prototype runs tools in read-only mode. Each conversation retains its own agent session.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            Button("Open local library") { NSWorkspace.shared.open(model.directory) }
            Button("Done") { model.showingSettings = false }.buttonStyle(.borderedProminent).tint(.orange)
        }
    }
}
