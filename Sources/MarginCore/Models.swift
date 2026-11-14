import Foundation

public struct SourceContext: Codable, Sendable, Equatable {
    public var documentID: String
    public var appName: String
    public var bundleID: String
    public var title: String
    public var url: String?
    public var text: String
    public var selection: String?
    public var capturedAt: Date
    public var screenshotPath: String?

    public init(documentID: String, appName: String, bundleID: String, title: String,
                url: String? = nil, text: String, selection: String? = nil,
                capturedAt: Date = Date(), screenshotPath: String? = nil) {
        self.documentID = documentID
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.url = url
        self.text = text
        self.selection = selection
        self.capturedAt = capturedAt
        self.screenshotPath = screenshotPath
    }
}

public struct DocumentRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var url: String?
    public var appName: String
    public var updatedAt: Date

    public init(id: String, title: String, url: String? = nil, appName: String,
                updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.appName = appName
        self.updatedAt = updatedAt
    }
}

public struct Highlight: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var documentID: String
    public var quote: String
    public var contextText: String
    public var createdAt: Date

    public init(id: UUID = UUID(), documentID: String, quote: String,
                contextText: String = "", createdAt: Date = Date()) {
        self.id = id
        self.documentID = documentID
        self.quote = quote
        self.contextText = contextText
        self.createdAt = createdAt
    }
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case user, assistant
    }

    public enum Status: String, Codable, Sendable {
        case complete, running, interrupted, failed
    }

    public var id: UUID
    public var role: Role
    public var body: String
    public var status: Status
    public var createdAt: Date
    public var context: SourceContext?

    public init(id: UUID = UUID(), role: Role, body: String,
                status: Status = .complete, createdAt: Date = Date(),
                context: SourceContext? = nil) {
        self.id = id
        self.role = role
        self.body = body
        self.status = status
        self.createdAt = createdAt
        self.context = context
    }
}

public struct ThreadRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var documentID: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var providerSessionID: String?
    public var agent: AgentConfiguration?

    public init(id: UUID = UUID(), documentID: String, title: String = "New thread",
                createdAt: Date = Date(), updatedAt: Date = Date(),
                messages: [ChatMessage] = [], providerSessionID: String? = nil,
                agent: AgentConfiguration? = nil) {
        self.id = id
        self.documentID = documentID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.providerSessionID = providerSessionID
        self.agent = agent
    }
}

public struct LibraryState: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var documents: [DocumentRecord]
    public var highlights: [Highlight]
    public var threads: [ThreadRecord]

    public init(schemaVersion: Int = 1, documents: [DocumentRecord] = [],
                highlights: [Highlight] = [], threads: [ThreadRecord] = []) {
        self.schemaVersion = schemaVersion
        self.documents = documents
        self.highlights = highlights
        self.threads = threads
    }
}
