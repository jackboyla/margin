import Foundation
import XCTest
@testable import MarginCore

final class LibraryStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor
    func testHighlightsAndIndependentThreadsSurviveReopening() async throws {
        let directory = try temporaryDirectory()
        let source = SourceContext(documentID: "paper", appName: "Safari", bundleID: "com.apple.Safari",
                                   title: "A paper", url: "https://example.com/paper", text: "Full context",
                                   selection: "A useful quote")
        let highlight = Highlight(documentID: source.documentID, quote: "A useful quote", contextText: source.text)
        let store = try LibraryStore(directory: directory)
        try store.update {
            $0.documents.append(DocumentRecord(id: source.documentID, title: source.title,
                                               url: source.url, appName: source.appName))
            $0.highlights.append(highlight)
        }
        let reopened = try LibraryStore(directory: directory)
        XCTAssertEqual(reopened.state, store.state)
        XCTAssertTrue(reopened.state.threads.isEmpty)

        let first = ThreadRecord(documentID: source.documentID, title: "First question", messages: [
            ChatMessage(role: .user, body: "Explain this", context: source),
            ChatMessage(role: .assistant, body: "An explanation"),
        ], providerSessionID: "session-one")
        let second = ThreadRecord(documentID: source.documentID, title: "Another question", messages: [
            ChatMessage(role: .user, body: "What are the limits?", context: source),
        ], providerSessionID: "session-two")
        try reopened.update { $0.threads = [first, second] }
        try reopened.update { $0.threads[0].messages[1].body = "Updated explanation" }

        let final = try LibraryStore(directory: directory)
        XCTAssertEqual(final.state, reopened.state)
        XCTAssertEqual(final.state.highlights, [highlight])
        XCTAssertEqual(final.state.threads[1], second)
        XCTAssertEqual(final.state.threads[0].providerSessionID, "session-one")
        XCTAssertEqual(final.state.threads[0].messages[0].context, source)
    }

    @MainActor
    func testRestartPersistsInterruptionWithoutChangingOtherMessages() async throws {
        let directory = try temporaryDirectory()
        let store = try LibraryStore(directory: directory)
        let messages = [
            ChatMessage(role: .user, body: "Question"),
            ChatMessage(role: .assistant, body: "Partial answer", status: .running),
            ChatMessage(role: .assistant, body: "Old failure", status: .failed),
        ]
        try store.update { $0.threads.append(ThreadRecord(documentID: "paper", messages: messages)) }

        let restarted = try LibraryStore(directory: directory)
        var expected = store.state
        expected.threads[0].messages[1].status = .interrupted
        XCTAssertEqual(restarted.state, expected)
        XCTAssertEqual(try LibraryStore(directory: directory).state, expected)
        let disk = try JSONDecoder().decode(LibraryState.self,
            from: Data(contentsOf: directory.appendingPathComponent("library.json")))
        XCTAssertEqual(disk, expected)
    }

    @MainActor
    func testFailedMutationAndWriteKeepPublishedStateAndSavedData() async throws {
        enum TestError: Error { case rejected }
        let directory = try temporaryDirectory()
        let store = try LibraryStore(directory: directory)
        try store.update { $0.highlights.append(Highlight(documentID: "paper", quote: "Keep this")) }
        let saved = store.state
        let file = directory.appendingPathComponent("library.json")
        let originalData = try Data(contentsOf: file)

        XCTAssertThrowsError(try store.update {
            $0.highlights.removeAll()
            throw TestError.rejected
        })
        XCTAssertEqual(store.state, saved)
        XCTAssertEqual(try Data(contentsOf: file), originalData)

        let backup = directory.appendingPathComponent("saved.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.update { $0.highlights.removeAll() })
        XCTAssertEqual(store.state, saved)
        XCTAssertEqual(try Data(contentsOf: backup), originalData)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        XCTAssertEqual(try LibraryStore(directory: directory).state, saved)
    }

    @MainActor
    func testInvalidLibrariesAreReportedAndNeverOverwritten() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("library.json")
        let unsupported = try JSONEncoder().encode(LibraryState(schemaVersion: 99))
        for contents in [Data("broken json".utf8), unsupported] {
            try contents.write(to: file)
            XCTAssertThrowsError(try LibraryStore(directory: directory))
            XCTAssertEqual(try Data(contentsOf: file), contents)
        }
    }
}
