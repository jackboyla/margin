import AppKit
import MarginCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var section = 0
    @State private var apiKey = ""
    @State private var refresh = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Settings", selection: $section) {
                Text("Reading").tag(0)
                Text("Models").tag(1)
                Text("Library").tag(2)
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch section {
                    case 1: modelSettings
                    case 2: librarySettings
                    default: readingSettings
                    }
                    if let error = model.error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    } else if let notice = model.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { model.showingSettings = false }
                .buttonStyle(.borderedProminent).tint(.orange)
        }
        .onAppear {
            loadAPIKey()
        }
    }

    private var readingSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Stay with the page.").font(.title2.weight(.semibold))
                Text("Highlight a passage, ask a question, and keep the conversation beside what you're reading.")
                    .foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    shortcut("Ask beside the cursor", keys: "⌃⇧Space")
                    shortcut("Threads and highlights", keys: "⌃⇧H")
                    shortcut("Close the panel", keys: "Esc")
                }.padding(6)
            }
            GroupBox("Window access") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Margin reads the window you choose. Saved highlights stay in your library. Questions send captured text, and optional images, to your chosen model.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        dismissPanels()
                        model.capture.requestAccessibilityPermission()
                        refresh.toggle()
                    } label: {
                        Label(model.capture.accessibilityPermission ? "\(WindowCapture.accessibilityPermissionName) enabled" : "Enable \(WindowCapture.accessibilityPermissionName)",
                              systemImage: model.capture.accessibilityPermission ? "checkmark.circle.fill" : "cursorarrow.click")
                    }
                    Button {
                        dismissPanels()
                        model.capture.requestScreenCapturePermission()
                        refresh.toggle()
                    } label: {
                        Label(model.capture.screenCapturePermission ? "Screen capture enabled" : "Enable Screen Capture",
                              systemImage: model.capture.screenCapturePermission ? "checkmark.circle.fill" : "macwindow")
                    }
                    Button("Open Privacy Settings") {
                        dismissPanels()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
                    }.buttonStyle(.link)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }.id(refresh)
            Text("After granting access, press Control–Shift–H to return. Allow browser Automation when macOS asks so your notes return to the page's URL.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func dismissPanels() {
        for window in NSApp.windows where window is FloatingPanel { window.orderOut(nil) }
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your model, your choice.").font(.headline)
            Picker("Answer with", selection: $model.agentConfiguration.backend) {
                Text("Codex agent").tag(AgentConfiguration.Backend.codex)
                Text("OpenAI-compatible API").tag(AgentConfiguration.Backend.openAI)
            }.pickerStyle(.menu)
            if model.agentConfiguration.backend == .codex {
                Text("Uses your existing Codex sign-in and read-only tools. Each thread keeps its own agent session.")
                    .font(.caption).foregroundStyle(.secondary)
                field("Codex executable", text: $model.executablePath)
                field("Working folder", text: $model.workspacePath)
            } else {
                Menu("Start from a provider") {
                    Button("OpenAI") { preset("https://api.openai.com/v1", tokenField: .maxCompletionTokens) }
                    Button("Claude") { preset("https://api.anthropic.com/v1", tokenField: .maxTokens) }
                    Button("Ollama on this Mac") { preset("http://localhost:11434/v1", tokenField: .maxTokens) }
                    Button("LM Studio on this Mac") { preset("http://localhost:1234/v1", tokenField: .maxTokens) }
                }
                field("API base URL", text: $model.agentConfiguration.api.baseURL)
                    .onChange(of: model.agentConfiguration.api.baseURL) { _, _ in loadAPIKey() }
                field("Model name", text: $model.agentConfiguration.api.model)
                VStack(alignment: .leading, spacing: 5) {
                    Text("API key").font(.caption).foregroundStyle(.secondary)
                    SecureField("Optional for local servers", text: $apiKey).textFieldStyle(.roundedBorder)
                }
                Toggle("Include window images", isOn: $model.agentConfiguration.includesImages)
                Text("Enable images only for vision models. Text-only models still receive the selected passage, visible text and saved highlights.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Token limit field", selection: $model.agentConfiguration.api.tokenLimitField) {
                            Text("max_tokens").tag(OpenAIConfiguration.TokenLimitField.maxTokens)
                            Text("max_completion_tokens").tag(OpenAIConfiguration.TokenLimitField.maxCompletionTokens)
                        }
                        TextField("Maximum output tokens", value: Binding(
                            get: { model.agentConfiguration.api.maxTokens ?? 4096 },
                            set: { model.agentConfiguration.api.maxTokens = $0 }), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                        TextField("Anthropic workspace ID (optional)", text: Binding(
                            get: { model.agentConfiguration.api.anthropicWorkspaceID ?? "" },
                            set: { model.agentConfiguration.api.anthropicWorkspaceID = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder)
                    }.padding(.top, 8)
                }
                Text("Keys stay in macOS Keychain. API conversations use Chat Completions; coding-agent tools remain available through Codex.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Save model settings") {
                do { try model.saveAgentSettings(apiKey: apiKey) }
                catch { model.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent).tint(.orange)
            Text("New threads use these settings. Existing threads keep their original model and backend.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var librarySettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A home for your reading.").font(.headline)
            Text("Your highlights and conversations save automatically on this Mac and stay available offline.")
                .foregroundStyle(.secondary)
            Button("Open library folder") { NSWorkspace.shared.open(model.directory) }
            Text("To back up your reading history, quit Margin and copy the whole library folder. Keep the attachments with the database so your captured window images come with it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func preset(_ url: String, tokenField: OpenAIConfiguration.TokenLimitField) {
        model.agentConfiguration.api = OpenAIConfiguration(baseURL: url, model: "", tokenLimitField: tokenField)
        model.agentConfiguration.includesImages = false
        loadAPIKey()
    }

    private func loadAPIKey() {
        apiKey = ""
        guard let account = try? model.apiCredentialAccount(model.agentConfiguration.api) else { return }
        do { apiKey = try Credentials.read(account) }
        catch { model.error = error.localizedDescription }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Text(keys).font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}
