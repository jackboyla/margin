import Foundation
import SQLite3
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

    private func sql(_ sql: String, in directory: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteTests", code: Int(sqlite3_errcode(database)))
        }
    }

    @MainActor
    func testHighlightsAndIndependentThreadsSurviveReopening() async throws {
        let directory = try temporaryDirectory()
        let source = SourceContext(documentID: "paper", appName: "Safari", bundleID: "com.apple.Safari",
                                   title: "A paper", url: "https://example.com/paper", text: "Full context",
                                   selection: "A useful quote")
        let highlight = Highlight(documentID: source.documentID, quote: "A useful quote\0with a null and ' quote", contextText: source.text)
        let store = try LibraryStore(directory: directory)
        try await store.update {
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
        ], providerSessionID: "session-one", agent: AgentConfiguration())
        let second = ThreadRecord(documentID: source.documentID, title: "Another question", messages: [
            ChatMessage(role: .user, body: "What are the limits?", context: source),
        ], providerSessionID: "session-two")
        try await reopened.update { $0.threads = [first, second] }
        try await reopened.update { $0.threads[0].messages[1].body = "Updated explanation" }

        let final = try LibraryStore(directory: directory)
        XCTAssertEqual(final.state, reopened.state)
        XCTAssertEqual(final.state.highlights, [highlight])
        XCTAssertEqual(final.state.threads[1], second)
        XCTAssertEqual(final.state.threads[0].providerSessionID, "session-one")
        XCTAssertEqual(final.state.threads[0].messages[0].context, source)
        XCTAssertEqual(final.state.threads[0].agent, first.agent)

        try await final.update {
            $0.documents.append(DocumentRecord(id: "other", title: "Other", appName: "Preview"))
            $0.documents.reverse()
            $0.highlights.append(Highlight(documentID: "other", quote: "Another quote"))
            $0.highlights.reverse()
            $0.threads.reverse()
            $0.threads[1].messages.reverse()
            $0.threads[1].messages[0].id = UUID()
        }
        XCTAssertEqual(try LibraryStore(directory: directory).state, final.state)
        try await final.update {
            $0.documents.removeLast()
            $0.documents[0].id = "renamed"
            $0.highlights.removeLast()
            $0.highlights[0].id = UUID()
            $0.threads.removeFirst()
            $0.threads[0].messages.removeLast()
        }
        XCTAssertEqual(try LibraryStore(directory: directory).state, final.state)
        try await final.update { $0.threads[0].id = UUID() }
        XCTAssertEqual(try LibraryStore(directory: directory).state, final.state)
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
        try await store.update { $0.threads.append(ThreadRecord(documentID: "paper", messages: messages)) }

        let restarted = try LibraryStore(directory: directory)
        var expected = store.state
        expected.threads[0].messages[1].status = .interrupted
        XCTAssertEqual(restarted.state, expected)
        XCTAssertEqual(try LibraryStore(directory: directory).state, expected)
    }

    @MainActor
    func testRejectedMutationAndDatabaseFailureRollBackWithoutPublishing() async throws {
        enum TestError: Error { case rejected }
        let directory = try temporaryDirectory()
        let store = try LibraryStore(directory: directory)
        try await store.update {
            $0.documents.append(DocumentRecord(id: "paper", title: "Original", appName: "Preview"))
            $0.highlights.append(Highlight(documentID: "paper", quote: "Keep this"))
        }
        let saved = store.state

        do {
            try await store.update {
                $0.highlights.removeAll()
                throw TestError.rejected
            }
            XCTFail("A rejected mutation must not be saved")
        } catch TestError.rejected {}
        XCTAssertEqual(store.state, saved)
        XCTAssertEqual(try LibraryStore(directory: directory).state, saved)

        try sql("CREATE TRIGGER reject_highlight BEFORE INSERT ON highlights BEGIN SELECT RAISE(ABORT, 'write rejected'); END", in: directory)
        do {
            try await store.update {
                $0.documents[0].title = "Must roll back with failed highlight"
                $0.highlights[0].quote = "Must roll back"
            }
            XCTFail("A SQLite failure must also roll back the earlier document write")
        } catch LibraryStore.StoreError.database {}
        XCTAssertEqual(store.state, saved)
        XCTAssertEqual(try LibraryStore(directory: directory).state, saved)
        try sql("DROP TRIGGER reject_highlight", in: directory)
        try await store.update { $0.highlights[0].quote = "Saved after rollback" }
        XCTAssertEqual(try LibraryStore(directory: directory).state, store.state)

        let beforeDuplicate = store.state
        do {
            try await store.update { $0.highlights.append($0.highlights[0]) }
            XCTFail("Duplicate IDs must fail without replacing saved records")
        } catch LibraryStore.StoreError.invalidLibrary {}
        XCTAssertEqual(store.state, beforeDuplicate)
        XCTAssertEqual(try LibraryStore(directory: directory).state, beforeDuplicate)

        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite").path, &lock), SQLITE_OK)
        defer { sqlite3_close(lock) }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let start = ProcessInfo.processInfo.systemUptime
        do {
            try await store.update { $0.highlights[0].quote = "Blocked write" }
            XCTFail("Another writer's lock must fail without publishing")
        } catch LibraryStore.StoreError.database(let message) {
            XCTAssertTrue(message.contains("locked"))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1,
                          "The UI must not wait several seconds for another writer")
        XCTAssertEqual(store.state, beforeDuplicate)
        XCTAssertEqual(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try LibraryStore(directory: directory).state, beforeDuplicate)
    }

    @MainActor
    func testLegacyMigrationPreservesBackupAndDoesNotImportTwice() async throws {
        let directory = try temporaryDirectory()
        let original = LibraryState(
            documents: [DocumentRecord(id: "paper", title: "Paper", appName: "Preview")],
            highlights: [Highlight(documentID: "paper", quote: "Old highlight")],
            threads: [ThreadRecord(documentID: "paper", messages: [
                ChatMessage(role: .assistant, body: "Partial answer", status: .running),
            ], agent: AgentConfiguration())])
        let legacy = directory.appendingPathComponent("library.json")
        let backup = directory.appendingPathComponent("library.json.migrated")
        let bytes = try JSONEncoder().encode(original)
        try bytes.write(to: legacy)
        let store = try LibraryStore(directory: directory)
        var expected = original
        expected.threads[0].messages[0].status = .interrupted
        XCTAssertEqual(store.state, expected)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        try await store.update { $0.highlights[0].quote = "Changed in SQLite" }

        // Simulate a crash after SQLite committed but before the legacy file was renamed.
        try FileManager.default.moveItem(at: backup, to: legacy)
        let reopened = try LibraryStore(directory: directory)
        XCTAssertEqual(reopened.state, store.state)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))

        try bytes.write(to: legacy)
        XCTAssertEqual(try LibraryStore(directory: directory).state, store.state)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
    }

    @MainActor
    func testInvalidLegacyAndUnsupportedDatabaseAreNeverReplaced() async throws {
        for contents in [Data("broken json".utf8), try JSONEncoder().encode(LibraryState(schemaVersion: 99))] {
            let directory = try temporaryDirectory()
            let file = directory.appendingPathComponent("library.json")
            try contents.write(to: file)
            XCTAssertThrowsError(try LibraryStore(directory: directory))
            XCTAssertEqual(try Data(contentsOf: file), contents)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("library.json.migrated").path))
            // A rejected migration must leave no schema that hides the still-unmigrated file.
            try JSONEncoder().encode(LibraryState()).write(to: file)
            XCTAssertEqual(try LibraryStore(directory: directory).state, LibraryState())
        }
        let directory = try temporaryDirectory()
        let store = try LibraryStore(directory: directory)
        try await store.update { $0.highlights.append(Highlight(documentID: "paper", quote: "Keep this")) }
        try sql("PRAGMA user_version = 99", in: directory)
        XCTAssertThrowsError(try LibraryStore(directory: directory)) { error in
            XCTAssertEqual(error as? LibraryStore.StoreError, .unsupportedSchema(99))
        }
        try sql("PRAGMA user_version = 1", in: directory)
        XCTAssertEqual(try LibraryStore(directory: directory).state, store.state)
    }

    @MainActor
    func testStaleInstanceCannotOverwriteAnotherSave() async throws {
        let directory = try temporaryDirectory()
        let first = try LibraryStore(directory: directory)
        let second = try LibraryStore(directory: directory)
        try await first.update { $0.highlights.append(Highlight(documentID: "paper", quote: "First save")) }
        do {
            try await second.update { $0.highlights.removeAll() }
            XCTFail("A stale instance must not discard another save")
        } catch LibraryStore.StoreError.conflict {}
        XCTAssertEqual(second.state, LibraryState())
        XCTAssertEqual(try LibraryStore(directory: directory).state, first.state)
    }
}
