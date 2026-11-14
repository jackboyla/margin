import Foundation

public struct AgentConfiguration: Codable, Equatable, Sendable {
    public enum Backend: String, Codable, CaseIterable, Sendable {
        case codex, openAI
    }

    public var backend: Backend
    public var api: OpenAIConfiguration
    public var includesImages: Bool

    public init(backend: Backend = .codex,
                api: OpenAIConfiguration = .init(baseURL: "http://localhost:11434/v1", model: ""),
                includesImages: Bool = false) {
        self.backend = backend
        self.api = api
        self.includesImages = includesImages
    }

    public var label: String { backend == .codex ? "Codex" : api.model }
}
