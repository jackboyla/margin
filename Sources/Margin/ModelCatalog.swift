import Foundation
import MarginCore
import SwiftUI

struct ModelOption: Identifiable, Sendable {
    var id: String
    var name: String
}

struct ModelCatalogCredential: Equatable, Sendable {
    let account: String
    let key: String
}

enum ModelCatalog {
    static func load(_ configuration: AgentConfiguration, credential: ModelCatalogCredential?) async throws -> [ModelOption] {
        switch configuration.backend {
        case .claude:
            return ["sonnet", "opus", "haiku", "fable"].map { ModelOption(id: $0, name: $0.capitalized) }
        case .codex:
            return try await Task.detached {
                struct Cache: Decodable {
                    struct Entry: Decodable {
                        let slug: String
                        let display_name: String?
                        let visibility: String?
                    }
                    let models: [Entry]
                }
                let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
                let data = try Data(contentsOf: home.appendingPathComponent("models_cache.json"))
                let cache = try JSONDecoder().decode(Cache.self, from: data)
                return cache.models.filter { $0.visibility != "hide" }.map {
                    ModelOption(id: $0.slug, name: $0.display_name ?? $0.slug)
                }
            }.value
        case .openAI:
            let completion = try configuration.api.completionURL()
            let key: String
            if let credential, credential.account == "api:" + completion.absoluteString { key = credential.key }
            else { key = try await Task.detached { try Credentials.read("api:" + completion.absoluteString) }.value }
            let url = completion.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models")
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let session = URLSession(configuration: .ephemeral, delegate: CatalogRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw OpenAIClientError.configuration("The server could not list models (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Enter a model name manually, or check the server and key.")
            }
            struct Response: Decodable {
                struct Entry: Decodable { let id: String }
                let data: [Entry]
            }
            let ids = try JSONDecoder().decode(Response.self, from: data).data.map(\.id)
            return Set(ids).sorted().map { ModelOption(id: $0, name: $0) }
        }
    }
}

private final class CatalogRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ModelNamePicker: View {
    @Binding var configuration: AgentConfiguration
    var credential: ModelCatalogCredential? = nil
    @State private var options: [ModelOption] = []
    @State private var loading = false
    @State private var message: String?
    @State private var refresh = UUID()

    private var name: Binding<String> {
        Binding(get: {
            switch configuration.backend {
            case .codex: return configuration.codexModel ?? ""
            case .claude: return configuration.claudeModel ?? ""
            case .openAI: return configuration.api.model
            }
        }, set: { value in
            switch configuration.backend {
            case .codex: configuration.codexModel = value.isEmpty ? nil : value
            case .claude: configuration.claudeModel = value.isEmpty ? nil : value
            case .openAI: configuration.api.model = value
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Picker("Model", selection: name) {
                    Text(configuration.backend == .openAI ? "Choose a model" : "Runtime default").tag("")
                    ForEach(options) { option in Text(option.name).tag(option.id) }
                    if !name.wrappedValue.isEmpty, !options.contains(where: { $0.id == name.wrappedValue }) {
                        Text(name.wrappedValue).tag(name.wrappedValue)
                    }
                }.pickerStyle(.menu)
                if loading { ProgressView().controlSize(.small) }
                Button { refresh = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh available models").disabled(loading)
            }
            TextField("Custom model name", text: name).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Custom model name")
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if configuration.backend == .claude {
                Text("Aliases follow your Claude Code version and account. You can also enter a full model ID.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: [configuration.backend.rawValue, configuration.api.baseURL,
                   credential?.account ?? "", credential?.key ?? "", refresh.uuidString]) {
            options = []
            message = nil
            loading = true
            do {
                try await Task.sleep(for: .milliseconds(400))
                let result = try await ModelCatalog.load(configuration, credential: credential)
                try Task.checkCancellation()
                options = result
                if result.isEmpty { message = "No models were listed. Enter a custom model name." }
                else if configuration.backend == .codex { message = "From Codex’s local model cache. Run Codex to update its list." }
            } catch {
                guard !Task.isCancelled else { return }
                if configuration.backend == .codex {
                    message = "Codex’s model cache is unavailable. Run Codex once, then refresh, or enter a model name."
                } else if let error = error as? OpenAIClientError {
                    message = error.localizedDescription
                } else {
                    message = "Could not load models. Check the server and key, then refresh, or enter a model name manually."
                }
            }
            loading = false
        }
    }
}
