import CoreGraphics
import CryptoKit
import Foundation

@MainActor
final class ChromePDFHighlights {
    private var original: (url: URL, bytes: Data)?
    private(set) var awaitingClear = false
    private var retry: (token: String, after: Date)?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    static func paperURL(_ address: String) -> URL? {
        guard var parts = URLComponents(string: address), parts.scheme == "https", parts.host == "arxiv.org",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.range(of: #"^/pdf/(?:[0-9]{4}\.[0-9]{4,5}|[a-zA-Z][a-zA-Z0-9.\-]*/[0-9]{7})(?:v[0-9]+)?(?:\.pdf)?$"#,
                               options: .regularExpression) != nil else { return nil }
        parts.fragment = nil
        return parts.url
    }

    func paint(paper: URL, quotes: [String], isCurrent: @MainActor () -> Bool,
               command: ([String: Any], PDFInputSnapshot?) async throws -> String,
               position: (PDFReadingPosition?) async throws -> PDFReadingPosition?) async throws -> Bool {
        let key = try JSONEncoder().encode([paper.absoluteString] + quotes.sorted())
        let token = Data(SHA256.hash(data: key)).base64EncodedString()
        func send(_ action: String, _ fields: [String: Any] = [:], input: PDFInputSnapshot? = nil) async throws -> String {
            var request = fields
            request["action"] = action
            request["token"] = token
            return try await command(request, input)
        }
        let status = try await send("status")
        if quotes.isEmpty { awaitingClear = status != "active" && status != "original" }
        if status == "active" || (status == "original" && quotes.isEmpty) { return true }
        guard ["original", "different", "pending", "ready", "failed"].contains(status) else { return false }
        // On a supported PDF, keep the visible paper while a new copy loads or position is uncertain.
        guard isCurrent(), retry?.token != token || (retry?.after ?? .distantPast) < Date() else { return true }
        if status == "pending" || status == "ready" || status == "failed" {
            _ = try await send("cancel")
        }
        retry = (token, Date().addingTimeInterval(8))
        guard let source = try await position(nil), isCurrent() else { return true }
        let bytes: Data
        do {
            bytes = try await originalBytes(for: paper)
        } catch {
            return true
        }
        let marked = await Task.detached(priority: .utility) {
            PDFHighlightDocument.annotated(bytes, quotes: quotes)
        }.value
        guard let marked, isCurrent() else { return true }
        if marked == bytes && status == "original" {
            retry = (token, .distantFuture)
            return true
        }

        var zoom = 100.0
        var left = 0.0
        var top = 0.0
        do {
            for attempt in 0..<4 {
                guard isCurrent() else { break }
                var fields: [String: Any] = ["page": source.pageNumber, "zoom": zoom, "left": left, "top": top]
                if attempt == 0 { fields["bytes"] = marked.base64EncodedString() }
                var state = try await send("stage", fields)
                var candidate: PDFReadingPosition?
                let deadline = Date().addingTimeInterval(4)
                while isCurrent(), candidate == nil, Date() < deadline, ["pending", "ready"].contains(state) {
                    if state == "ready" { candidate = try await position(source) }
                    if candidate == nil {
                        try await Task.sleep(for: .milliseconds(100))
                        state = try await send("status")
                    }
                }
                guard let candidate, isCurrent() else { break }
                if candidate.zoomPercent != source.zoomPercent {
                    zoom *= Double(source.zoomPercent) / Double(candidate.zoomPercent)
                    continue
                }
                guard candidate.pageNumber == source.pageNumber,
                      let delta = candidate.displacement(from: source) else { break }
                if abs(delta.width) <= 1, abs(delta.height) <= 1 {
                    let input = PDFInputSnapshot()
                    let stillAligned = await Task.detached(priority: .userInitiated) {
                        guard let original = source.refreshed(), let staged = candidate.refreshed(),
                              let difference = staged.displacement(from: original) else { return false }
                        return abs(difference.width) <= 1 && abs(difference.height) <= 1
                    }.value
                    if stillAligned, isCurrent(), try await send("commit", input: input) == "active" {
                        if quotes.isEmpty { awaitingClear = false }
                        retry = nil
                        return true
                    }
                    break
                }
                let scale = Double(candidate.zoomPercent) / 100
                left += delta.width / scale
                top += delta.height / scale
            }
        } catch {
            _ = try? await send("cancel")
            throw error
        }
        _ = try await send("cancel")
        return true
    }

    private func originalBytes(for url: URL) async throws -> Data {
        if let original, original.url == url { return original.bytes }
        let (file, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url,
              http.mimeType == "application/pdf",
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 64 * 1024 * 1024 else { throw URLError(.cannotDecodeContentData) }
        let bytes = try Data(contentsOf: file)
        original = (url, bytes)
        return bytes
    }
}

/// Counts physical input across the final accessibility measurement and queued Apple Event.
struct PDFInputSnapshot: Equatable, Sendable {
    private let counts: [UInt32]

    init() {
        let events: [CGEventType] = [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                     .otherMouseDown, .otherMouseDragged, .keyDown]
        counts = events.map { CGEventSource.counterForEventType(.combinedSessionState, eventType: $0) }
    }
}
