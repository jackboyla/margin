import Foundation

public struct OpenAIConfiguration: Codable, Sendable, Equatable {
    public enum TokenLimitField: String, Codable, Sendable {
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
    }

    public var baseURL: String
    public var model: String
    public var maxTokens: Int?
    public var tokenLimitField: TokenLimitField
    public var anthropicWorkspaceID: String?

    public init(baseURL: String, model: String, maxTokens: Int? = 4096,
                tokenLimitField: TokenLimitField = .maxTokens, anthropicWorkspaceID: String? = nil) {
        self.baseURL = baseURL
        self.model = model
        self.maxTokens = maxTokens
        self.tokenLimitField = tokenLimitField
        self.anthropicWorkspaceID = anthropicWorkspaceID
    }

    public func completionURL() throws -> URL {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else {
            throw OpenAIClientError.configuration("Enter an HTTP or HTTPS API base URL without credentials, a query, or a fragment.")
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path == "chat/completions" || path.hasSuffix("/chat/completions") { return url }
        return url.appendingPathComponent("chat/completions")
    }
}

public struct OpenAIMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var text: String
    public var imageURL: String?

    public init(role: Role, text: String, imageURL: String? = nil) {
        self.role = role
        self.text = text
        self.imageURL = imageURL
    }

    public static func imageDataURL(data: Data, mimeType: String = "image/png") -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    fileprivate var json: [String: Any] {
        guard let imageURL else { return ["role": role.rawValue, "content": text] }
        return ["role": role.rawValue, "content": [
            ["type": "text", "text": text],
            ["type": "image_url", "image_url": ["url": imageURL]]
        ]]
    }
}

public enum OpenAIClientError: Error, LocalizedError, Sendable, Equatable {
    case configuration(String)
    case http(status: Int, message: String)
    case provider(String)
    case invalidResponse(String)
    case interrupted
    case transport(Int)

    public var errorDescription: String? {
        switch self {
        case .configuration(let message), .provider(let message), .invalidResponse(let message): return message
        case .http(let status, let message): return "API request failed (HTTP \(status)). \(message)"
        case .interrupted: return "The API stream ended before the answer finished. Try again."
        case .transport(let code):
            if code == URLError.timedOut.rawValue { return "The API request timed out. Check the server and try again." }
            if code == URLError.cannotConnectToHost.rawValue || code == URLError.cannotFindHost.rawValue {
                return "Could not connect to the API server. Check the base URL and that the server is running."
            }
            return "The API connection failed (network error \(code)). Check the server and connection."
        }
    }
}

public struct OpenAIClient: Sendable {
    public init() {}

    public func stream(configuration: OpenAIConfiguration, apiKey: String?, messages: [OpenAIMessage],
                       onDelta: @escaping @Sendable (String) async -> Void) async throws -> String {
        try Task.checkCancellation()
        let request = try makeRequest(configuration: configuration, apiKey: apiKey, messages: messages)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 120
        sessionConfiguration.timeoutIntervalForResource = 1800
        // A redirect must not silently send document content to another endpoint.
        let session = URLSession(configuration: sessionConfiguration, delegate: OpenAINoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw OpenAIClientError.invalidResponse("The API server did not return an HTTP response.")
            }
            guard (200..<300).contains(response.statusCode) else {
                var body = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    body.append(byte)
                    if body.count >= 16_384 { break }
                }
                throw Self.httpError(status: response.statusCode, data: body, apiKey: apiKey)
            }
            guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                throw OpenAIClientError.invalidResponse("The API did not return a Chat Completions stream. Check the base URL and streaming support.")
            }
            var parser = OpenAISSEParser()
            var decoder = OpenAIStreamDecoder(apiKey: apiKey)
            var answer = ""
            for try await byte in bytes {
                try Task.checkCancellation()
                if let event = try parser.append(byte), let delta = try decoder.consume(event) {
                    answer += delta
                    await onDelta(delta)
                }
                if decoder.finished { break }
            }
            if !decoder.finished, let event = try parser.finish(), let delta = try decoder.consume(event) {
                answer += delta
                await onDelta(delta)
            }
            try Task.checkCancellation()
            try decoder.validateCompletion()
            return answer
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let error = error as? OpenAIClientError { throw error }
            if let error = error as? URLError { throw OpenAIClientError.transport(error.code.rawValue) }
            throw OpenAIClientError.invalidResponse("The API response could not be read.")
        }
    }

    func makeRequest(configuration: OpenAIConfiguration, apiKey: String?, messages: [OpenAIMessage]) throws -> URLRequest {
        var request = URLRequest(url: try configuration.completionURL())
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw OpenAIClientError.configuration("Enter a model name from your API provider.") }
        guard configuration.maxTokens.map({ $0 > 0 }) ?? true else {
            throw OpenAIClientError.configuration("The output token limit must be greater than zero.")
        }
        guard !messages.isEmpty else { throw OpenAIClientError.configuration("Add a message before sending the request.") }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            guard !key.contains("\r"), !key.contains("\n") else {
                throw OpenAIClientError.configuration("The API key must be a single line.")
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let workspace = configuration.anthropicWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), !workspace.isEmpty {
            guard !workspace.contains("\r"), !workspace.contains("\n") else {
                throw OpenAIClientError.configuration("The workspace ID must be a single line.")
            }
            request.setValue(workspace, forHTTPHeaderField: "anthropic-workspace-id")
        }
        var body: [String: Any] = ["model": model, "messages": messages.map(\.json), "stream": true]
        if let limit = configuration.maxTokens { body[configuration.tokenLimitField.rawValue] = limit }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func httpError(status: Int, data: Data, apiKey: String?) -> OpenAIClientError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let fallback: String
        switch status {
        case 401, 403: fallback = "Check the API key and account permissions."
        case 404: fallback = "Check the API base URL and model name."
        case 429: fallback = "The provider's rate or usage limit was reached. Try again later."
        case 300..<400: fallback = "The endpoint redirected the request. Set the final API base URL directly."
        default: fallback = "Check the model, provider settings, and server status."
        }
        return .http(status: status, message: providerMessage(body, apiKey: apiKey).map { "\(fallback) \($0)" } ?? fallback)
    }

    fileprivate static func providerMessage(_ body: [String: Any]?, apiKey: String?) -> String? {
        let error = body?["error"]
        guard var message = (error as? [String: Any])?["message"] as? String ?? error as? String else { return nil }
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            message = message.replacingOccurrences(of: key, with: "[redacted]")
        }
        return String(message.prefix(1000))
    }
}

private final class OpenAINoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct OpenAIStreamDecoder {
    var apiKey: String?
    private(set) var finished = false
    private(set) var finishReason: String?
    var receivedFinishReason: Bool { finishReason != nil }

    func validateCompletion() throws {
        guard finished || receivedFinishReason else { throw OpenAIClientError.interrupted }
        switch finishReason {
        case "length": throw OpenAIClientError.provider("The answer reached the output token limit. Increase the limit or ask for a shorter answer.")
        case "content_filter": throw OpenAIClientError.provider("The provider stopped this answer because of its content filter.")
        case "tool_calls", "function_call": throw OpenAIClientError.provider("The model requested a tool instead of a text answer. Choose a chat model that answers directly.")
        default: break
        }
    }

    mutating func consume(_ event: String) throws -> String? {
        if event.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            finished = true
            return nil
        }
        guard let data = event.data(using: .utf8),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OpenAIClientError.invalidResponse("The API returned an invalid streaming event.")
        }
        if let message = OpenAIClient.providerMessage(body, apiKey: apiKey) { throw OpenAIClientError.provider(message) }
        guard let choices = body["choices"] as? [[String: Any]] else {
            throw OpenAIClientError.invalidResponse("The API returned an event without Chat Completions choices.")
        }
        guard let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return nil }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty { finishReason = reason }
        guard let delta = choice["delta"] as? [String: Any] else { return nil }
        let content = delta["content"] as? String ?? delta["refusal"] as? String
        return content?.isEmpty == false ? content : nil
    }
}

struct OpenAISSEParser {
    private var line = [UInt8]()
    private var dataLines = [String]()
    private var eventBytes = 0
    private var previousCR = false
    private var firstLine = true

    mutating func append(_ byte: UInt8) throws -> String? {
        if byte == 10 && previousCR { previousCR = false; return nil }
        previousCR = byte == 13
        if byte == 10 || byte == 13 { return try consumeLine() }
        line.append(byte)
        guard line.count + eventBytes <= 1_048_576 else {
            throw OpenAIClientError.invalidResponse("The API returned an oversized streaming event.")
        }
        return nil
    }

    mutating func finish() throws -> String? {
        if !line.isEmpty, let event = try consumeLine() { return event }
        return dispatch()
    }

    private mutating func consumeLine() throws -> String? {
        guard var value = String(bytes: line, encoding: .utf8) else {
            throw OpenAIClientError.invalidResponse("The API returned invalid UTF-8 in its stream.")
        }
        line.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if value.hasPrefix("\u{FEFF}") { value.removeFirst() } }
        if value.isEmpty { return dispatch() }
        if value == "data" || value.hasPrefix("data:") {
            var payload = value == "data" ? "" : String(value.dropFirst(5))
            if payload.first == " " { payload.removeFirst() }
            dataLines.append(payload)
            eventBytes += payload.utf8.count + 1
        }
        return nil
    }

    private mutating func dispatch() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let value = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        eventBytes = 0
        return value
    }
}
