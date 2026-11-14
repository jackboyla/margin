import XCTest
@testable import MarginCore

final class OpenAIClientTests: XCTestCase {
    func testEndpointValidationAndRequestSerialization() throws {
        let client = OpenAIClient()
        var config = OpenAIConfiguration(baseURL: "http://localhost:11434/v1/", model: "local-model")
        let image = OpenAIMessage.imageDataURL(data: Data([0, 1, 2]))
        let request = try client.makeRequest(configuration: config, apiKey: nil, messages: [
            OpenAIMessage(role: .system, text: "Read the supplied passage."),
            OpenAIMessage(role: .user, text: "Explain it.", imageURL: image)
        ])
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? String, "Read the supplied passage.")
        let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        XCTAssertEqual((parts[1]["image_url"] as? [String: String])?["url"], "data:image/png;base64,AAEC")

        config.baseURL = "https://api.anthropic.com/v1/chat/completions"
        config.anthropicWorkspaceID = "workspace-one"
        config.tokenLimitField = .maxCompletionTokens
        let keyed = try client.makeRequest(configuration: config, apiKey: "private-key", messages: [.init(role: .user, text: "Hi")])
        XCTAssertEqual(keyed.url?.absoluteString, config.baseURL)
        XCTAssertEqual(keyed.value(forHTTPHeaderField: "Authorization"), "Bearer private-key")
        XCTAssertEqual(keyed.value(forHTTPHeaderField: "anthropic-workspace-id"), "workspace-one")
        let keyedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(keyed.httpBody)) as? [String: Any])
        XCTAssertNil(keyedBody["max_tokens"])
        XCTAssertEqual(keyedBody["max_completion_tokens"] as? Int, 4096)
        let saved = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(OpenAIConfiguration.self, from: saved), config)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("private-key"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("apiKey"))

        for invalid in ["", "file:///tmp/model", "localhost:11434", "https://", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#x"] {
            config.baseURL = invalid
            XCTAssertThrowsError(try config.completionURL(), invalid)
        }
        config.baseURL = "https://example.com/proxy/v1"
        XCTAssertEqual(try config.completionURL().absoluteString, "https://example.com/proxy/v1/chat/completions")
        config.maxTokens = 0
        XCTAssertThrowsError(try client.makeRequest(configuration: config, apiKey: nil, messages: [.init(role: .user, text: "Hi")]))
    }

    func testSSEFramingHandlesCRLFMultilineUnicodeCommentsAndEOF() throws {
        var parser = OpenAISSEParser()
        let wire = "\u{FEFF}: keepalive\r\nevent: message\r\ndata: {\"choices\": [\r\ndata: {\"index\":0,\"delta\":{\"content\":\"café 🐈\"}}]}\r\n\r\n" +
            "data: {\"choices\":[],\"usage\":{\"total_tokens\":3}}\n\n" +
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\r\r" +
            "data: [DONE]"
        var events = [String]()
        for byte in wire.utf8 { if let event = try parser.append(byte) { events.append(event) } }
        if let event = try parser.finish() { events.append(event) }
        XCTAssertEqual(events.count, 4)
        XCTAssertTrue(events[0].contains("\n"))
        var decoder = OpenAIStreamDecoder(apiKey: nil)
        XCTAssertEqual(try decoder.consume(events[0]), "café 🐈")
        XCTAssertNil(try decoder.consume(events[1]))
        XCTAssertFalse(decoder.receivedFinishReason)
        XCTAssertNil(try decoder.consume(events[2]))
        XCTAssertTrue(decoder.receivedFinishReason)
        XCTAssertFalse(decoder.finished)
        XCTAssertNil(try decoder.consume(events[3]))
        XCTAssertTrue(decoder.finished)
        XCTAssertNoThrow(try decoder.validateCompletion())
    }

    func testStreamingErrorsAndMalformedEventsDoNotExposeTheKey() throws {
        let secret = "sk-private-key"
        let payload = Data("{\"error\":{\"message\":\"Invalid key: sk-private-key\"}}".utf8)
        let error = OpenAIClient.httpError(status: 401, data: payload, apiKey: secret)
        XCTAssertFalse(error.localizedDescription.contains(secret))
        XCTAssertTrue(error.localizedDescription.contains("401"))
        XCTAssertTrue(error.localizedDescription.contains("[redacted]"))
        let htmlError = OpenAIClient.httpError(status: 404, data: Data("<html>\(secret)</html>".utf8), apiKey: secret)
        XCTAssertFalse(htmlError.localizedDescription.contains(secret))
        XCTAssertTrue(htmlError.localizedDescription.contains("base URL"))
        var decoder = OpenAIStreamDecoder(apiKey: secret)
        XCTAssertThrowsError(try decoder.validateCompletion())
        XCTAssertThrowsError(try decoder.consume(String(decoding: payload, as: UTF8.self))) { error in
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
        XCTAssertThrowsError(try decoder.consume("not JSON"))
        XCTAssertThrowsError(try decoder.consume("{\"unexpected\":true}"))
        XCTAssertEqual(try decoder.consume("{\"choices\":[{\"index\":0,\"delta\":{\"refusal\":\"Cannot help.\"}}]}"), "Cannot help.")
        _ = try decoder.consume("{\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}")
        XCTAssertThrowsError(try decoder.validateCompletion())
        var parser = OpenAISSEParser()
        _ = try parser.append(255)
        XCTAssertThrowsError(try parser.append(10))
        var oversized = OpenAISSEParser()
        XCTAssertThrowsError(try Array(repeating: UInt8(97), count: 1_048_577).forEach { _ = try oversized.append($0) })
    }

    func testCancellationPreventsEvenRequestConstruction() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OpenAIClient().stream(
                configuration: .init(baseURL: "not a URL", model: ""), apiKey: nil,
                messages: [.init(role: .user, text: "Hi")], onDelta: { _ in XCTFail("Cancelled request emitted output") })
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled request succeeded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
