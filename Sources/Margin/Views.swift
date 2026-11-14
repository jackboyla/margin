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
                Image(systemName: "text.bubble.fill").foregroundStyle(.orange).font(.title3)
                Text("Margin").font(.headline)
                Text(model.activeAgent.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
    var compact = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let context = model.context {
                HStack(alignment: .top) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.title).font(.caption.weight(.medium)).lineLimit(2)
                        if let url = context.url {
                            Text(URL(string: url)?.host ?? url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Button { model.saveHighlight() } label: { Image(systemName: "highlighter") }
                        .help("Save the current selection without asking a question")
                        .disabled(model.capturing || !model.libraryReady)
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
                    .padding(10).background(.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
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
                    .frame(maxHeight: compact ? 290 : .infinity)
                    .onAppear {
                        if let id = thread.messages.last?.id { proxy.scrollTo(id, anchor: .top) }
                    }
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
                ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    .frame(maxHeight: 64)
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
                        .disabled(model.capturing || !model.libraryReady || model.context == nil || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if model.storageBusy {
                HStack { ProgressView().controlSize(.small); Text("Opening your library…").font(.caption) }
            }
        }.onAppear { focused = true }
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    var close: () -> Void
    @State private var filter = 0
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if model.sidebarShowsConversation, !model.showingSettings {
                    Button { model.sidebarShowsConversation = false } label: { Image(systemName: "chevron.left") }
                        .help("Back to your library")
                } else {
                    Image(systemName: "text.bubble.fill").foregroundStyle(.orange).font(.title2)
                }
                Text(model.showingSettings ? "Settings" : "Margin").font(.title2.weight(.semibold))
                Spacer()
                Button { model.showingSettings.toggle() } label: { Image(systemName: "gearshape") }
                Button(action: close) { Image(systemName: "xmark") }
            }.buttonStyle(.plain)
            if model.showingSettings {
                SettingsView(model: model)
            } else if model.sidebarShowsConversation {
                ConversationView(model: model, compact: false)
                Spacer(minLength: 0)
            } else {
                Picker("History", selection: $filter) {
                    Text("Recent").tag(0)
                    Text("This page").tag(1)
                    Text("Highlights").tag(2)
                }.pickerStyle(.segmented)
                TextField("Search your library", text: $search)
                    .textFieldStyle(.roundedBorder)
                if filter != 0 {
                    Text(model.pageContext?.title ?? "Capture a window with Control–Shift–Space first.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if filter == 2 {
                            ForEach(model.currentHighlights.filter { search.isEmpty || $0.quote.localizedCaseInsensitiveContains(search) }) { highlight in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(highlight.quote).font(.callout).lineLimit(5).textSelection(.enabled)
                                    HStack {
                                        Button("Ask about this", systemImage: "text.bubble") { model.useHighlight(highlight) }.disabled(model.capturing)
                                        Spacer()
                                        Button(role: .destructive) { model.removeHighlight(highlight.id) } label: { Image(systemName: "trash") }
                                            .help("Delete highlight")
                                    }.buttonStyle(.plain).font(.caption)
                                }.padding(13).background(.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                            }
                            if model.currentHighlights.isEmpty { empty("No saved highlights for this page.") }
                        } else {
                            let threads = filter == 0 ? model.recentThreads : model.currentThreads
                            ForEach(threads.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.messages.contains { $0.body.localizedCaseInsensitiveContains(search) } }) { thread in
                                Button { model.openThread(thread) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(thread.title).font(.callout.weight(.medium)).lineLimit(2)
                                        Text(model.document(for: thread)?.title ?? "Window")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Text(thread.updatedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(13)
                                    .background(model.selectedThreadID == thread.id ? Color.orange.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                                }.buttonStyle(.plain).disabled(model.capturing)
                            }
                            if threads.isEmpty { empty("Your conversations will appear here.") }
                        }
                    }
                }
                Divider()
                HStack {
                    Label(model.storageBackend == "local" ? "Saved on this Mac" : "PostgreSQL library", systemImage: "externaldrive")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("New thread", systemImage: "square.and.pencil") {
                        model.newThread()
                        model.sidebarShowsConversation = true
                    }.disabled(model.capturing || !model.libraryReady)
                }.buttonStyle(.plain)
                if model.storageBusy { ProgressView("Opening your library…").font(.caption) }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(4) }
            }
        }
        .padding(18).frame(width: 420)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .onExitCommand(perform: close)
    }

    private func empty(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "bookmark").font(.largeTitle).foregroundStyle(.orange.opacity(0.6))
            Text(text).font(.callout).foregroundStyle(.secondary)
            Text("Keep reading. Press ⌃⇧Space when something catches your attention.")
                .font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical, 28)
    }
}
