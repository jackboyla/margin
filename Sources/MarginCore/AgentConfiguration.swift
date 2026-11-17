import Foundation

public struct AgentConfiguration: Codable, Equatable, Sendable {
    public enum Backend: String, Codable, CaseIterable, Sendable {
        case codex, claude, openAI
    }

    public var backend: Backend
    public var api: OpenAIConfiguration
    public var includesImages: Bool
    public var codexModel: String?
    public var claudeModel: String?

    public init(backend: Backend = .codex,
                api: OpenAIConfiguration = .init(baseURL: "http://localhost:11434/v1", model: ""),
                includesImages: Bool = false, codexModel: String? = nil, claudeModel: String? = nil) {
        self.backend = backend
        self.api = api
        self.includesImages = includesImages
        self.codexModel = codexModel
        self.claudeModel = claudeModel
    }

    public var label: String {
        switch backend {
        case .codex: return codexModel.flatMap { $0.isEmpty ? nil : $0 } ?? "Codex automatic"
        case .claude: return claudeModel.flatMap { $0.isEmpty ? nil : $0 } ?? "Claude Code automatic"
        case .openAI: return api.model
        }
    }
}
