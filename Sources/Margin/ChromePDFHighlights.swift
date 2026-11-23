import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation
import MarginCore
import os

enum BrowserHighlightState {
    case current, deferred, unsupported
}

@MainActor
final class ChromePDFHighlights {
    private struct OriginalPDF {
        let url: URL
        let bytes: Data
        let id: String
    }
    private var original: OriginalPDF?
    private var lastPlacement: (paper: URL, position: PDFReadingPosition, zoom: Double, left: Double, top: Double)?
    private let log = Logger(subsystem: "com.jackboylan.margin", category: "BrowserHighlights")
    private var unpaintableToken: String?
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

    func stickyAnchor(paper: URL, position: PDFReadingPosition, at point: CGPoint) async throws -> StickyAnchor? {
        let source = try await originalPDF(for: paper)
        return await Task.detached(priority: .utility) {
            position.stickyAnchor(at: point, in: source.bytes)
        }.value
    }

    func paint(paper: URL, quotes: [String], notes: [StickyNote] = [], isCurrent: @MainActor () -> Bool,
               command: ([String: Any], PDFInputSnapshot?) async throws -> String,
               position: (PDFReadingPosition?) async throws -> PDFReadingPosition?) async throws -> BrowserHighlightState {
        struct PaintKey: Encodable {
            let paper: URL
            let quotes: [String]
            let notes: [StickyNote]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let key = try encoder.encode(PaintKey(paper: paper, quotes: quotes.sorted(), notes: notes))
        let token = Data(SHA256.hash(data: key)).base64EncodedString()
        func send(_ action: String, _ fields: [String: Any] = [:], input: PDFInputSnapshot? = nil) async throws -> String {
            var request = fields
            request["action"] = action
            request["token"] = token
            return try await command(request, input)
        }
        let status = try await send("status")
        if status == "active" || (status == "original" && quotes.isEmpty && notes.isEmpty) {
            return .current
        }
        if status == "notPDF" { return .unsupported }
        if status == "original", token == unpaintableToken { return .current }
        guard ["original", "different", "pending", "ready", "failed"].contains(status) else {
            return lastPlacement?.paper == paper ? .deferred : .unsupported
        }
        guard isCurrent(), retry?.token != token || (retry?.after ?? .distantPast) < Date() else { return .deferred }
        if ["pending", "ready", "failed"].contains(status) { _ = try await send("cancel") }
        func deferPaint(_ reason: String, delay: TimeInterval = 1) -> BrowserHighlightState {
            log.info("Deferred PDF highlight reconciliation: \(reason, privacy: .public)")
            retry = (token, Date().addingTimeInterval(delay))
            return .deferred
        }
        let positionBeforeUpdate = try await position(nil)
        guard isCurrent() else { return .deferred }
        guard let source = positionBeforeUpdate else { return deferPaint("source position unavailable", delay: 2) }
        let base: OriginalPDF
        do {
            base = try await originalPDF(for: paper)
        } catch {
            return deferPaint("paper download unavailable", delay: 8)
        }
        let (update, crop) = await Task.detached(priority: .utility) {
            let pdf = CGDataProvider(data: base.bytes as CFData).flatMap { CGPDFDocument($0) }
            let page = pdf?.page(at: source.pageNumber)
            let crop = page?.rotationAngle == 0 ? page?.getBoxRect(.cropBox) : nil
            return (PDFHighlightDocument.annotationUpdate(for: base.bytes, quotes: quotes, notes: notes), crop)
        }.value
        guard isCurrent() else { return .deferred }
        if status == "original", update?.isEmpty != false {
            // Missing quotes and PDFs with editable forms must stay in the original viewer.
            unpaintableToken = token
            return .current
        }
        guard let update else { return deferPaint("PDF annotation update unavailable", delay: 8) }

        var zoom = 100.0
        var left = 0.0
        var top = 0.0
        // Edits on the same visible page usually need the last verified offsets again.
        if let last = lastPlacement, last.paper == paper, source.sharesViewer(with: last.position),
           source.pageNumber == last.position.pageNumber, source.zoomPercent == last.position.zoomPercent {
            zoom = last.zoom
            left = last.left
            top = last.top
        }
        var reason = "reader moved"
        do {
            for attempt in 0..<4 {
                guard isCurrent() else { break }
                var fields: [String: Any] = ["page": source.pageNumber, "zoom": zoom, "left": left, "top": top]
                if attempt == 0 {
                    fields["sourceID"] = base.id
                    fields["append"] = update.base64EncodedString()
                }
                var state = try await send("stage", fields)
                if state == "sourceNeeded" && attempt == 0 {
                    fields["sourceBytes"] = base.bytes.base64EncodedString()
                    state = try await send("stage", fields)
                }
                let deadline = Date().addingTimeInterval(8)
                var candidate: PDFReadingPosition?
                var displacement: CGSize?
                var zoomCorrection: CGFloat?
                // The PDF wrapper loads before Chrome publishes the requested page and its text bounds.
                while isCurrent(), Date() < deadline, ["pending", "ready"].contains(state) {
                    if state == "ready", let sample = try await position(source), sample.pageNumber == source.pageNumber {
                        if let delta = sample.displacement(from: source, crop: crop) {
                            candidate = sample
                            displacement = delta
                            break
                        }
                        let measured = sample.zoomCorrection(to: source)
                        if let measured, abs(measured - 1) > 0.0001 {
                            candidate = sample
                            zoomCorrection = measured
                            break
                        }
                        if sample.zoomPercent != source.zoomPercent {
                            candidate = sample
                            zoomCorrection = CGFloat(source.zoomPercent) / CGFloat(sample.zoomPercent)
                            break
                        }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    state = try await send("status")
                }
                guard let candidate, isCurrent() else {
                    reason = "staged page did not provide matching landmarks"
                    break
                }
                if let zoomCorrection {
                    zoom *= zoomCorrection
                    continue
                }
                guard let delta = displacement else { break }
                if abs(delta.width) <= 1, abs(delta.height) <= 1 {
                    let input = PDFInputSnapshot()
                    let stillAligned = await Task.detached(priority: .userInitiated) {
                        guard let original = source.refreshed(), let staged = candidate.refreshed(),
                              let difference = staged.displacement(from: original, crop: crop) else { return false }
                        return abs(difference.width) <= 1 && abs(difference.height) <= 1
                    }.value
                    guard stillAligned, isCurrent() else {
                        reason = "position changed before display"
                        break
                    }
                    let receipt = try await send("commit", input: input)
                    if receipt == "active" {
                        lastPlacement = (paper, candidate, zoom, left, top)
                        retry = nil
                        return .current
                    }
                    reason = "browser did not confirm the switch"
                    break
                }
                let scale = Double(candidate.zoomPercent) / 100
                left += delta.width / scale
                top += delta.height / scale
                reason = "viewport offsets did not converge"
            }
        } catch {
            _ = try? await send("cancel")
            throw error
        }
        _ = try await send("cancel")
        return deferPaint(reason)
    }

    private func originalPDF(for url: URL) async throws -> OriginalPDF {
        if let original, original.url == url { return original }
        let (file, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url,
              http.mimeType == "application/pdf",
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 64 * 1024 * 1024 else { throw URLError(.cannotDecodeContentData) }
        let bytes = try Data(contentsOf: file)
        let result = OriginalPDF(url: url, bytes: bytes, id: Data(SHA256.hash(data: bytes)).base64EncodedString())
        original = result
        return result
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
