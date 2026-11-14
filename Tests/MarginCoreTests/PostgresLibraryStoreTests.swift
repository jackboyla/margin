import Foundation
import Logging
import PostgresNIO
import XCTest
@testable import MarginCore

final class PostgresLibraryStoreTests: XCTestCase {
    @MainActor
    func testRealPostgresPersistenceConflictRecoveryAndSerializedWrites() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["MARGIN_TEST_POSTGRES_HOST"] else {
            throw XCTSkip("Set MARGIN_TEST_POSTGRES_HOST to run against a disposable PostgreSQL database with TLS disabled.")
        }
        let configuration = PostgresConfiguration(
            host: host,
            port: Int(environment["MARGIN_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432,
            database: environment["MARGIN_TEST_POSTGRES_DATABASE"] ?? "postgres",
            username: environment["MARGIN_TEST_POSTGRES_USERNAME"] ?? "postgres",
            libraryID: "margin-test-\(UUID().uuidString)",
            tls: .disabled)
        let password = environment["MARGIN_TEST_POSTGRES_PASSWORD"] ?? ""
        addTeardownBlock {
            let logger = Logger(label: "Margin.PostgresTests", factory: { _ in SwiftLogNoOpLogHandler() })
            let connection = try await PostgresConnection.connect(
                configuration: .init(host: configuration.host, port: configuration.port,
                                     username: configuration.username, password: password,
                                     database: configuration.database, tls: .disable), id: 0, logger: logger)
            do {
                let rows = try await connection.query(
                    "DELETE FROM margin_libraries WHERE library_id = \(configuration.libraryID)", logger: logger)
                for try await _ in rows {}
                try await connection.closeGracefully()
            } catch {
                try? await connection.close()
                throw error
            }
        }

        let first = try await LibraryStore.openPostgres(configuration: configuration, password: password)
        let second = try await LibraryStore.openPostgres(configuration: configuration, password: password)
        let imported = LibraryState(
            documents: [DocumentRecord(id: "paper", title: "Paper", appName: "Preview")],
            highlights: [Highlight(documentID: "paper", quote: "A quote with ' SQL syntax; --")],
            threads: [ThreadRecord(documentID: "paper", messages: [
                ChatMessage(role: .assistant, body: "Partial answer", status: .running),
            ])])
        try await first.importIfEmpty(imported)
        let reopened = try await LibraryStore.openPostgres(configuration: configuration, password: password)
        XCTAssertEqual(reopened.state, imported, "Connecting must not replace data or interrupt another client's run")

        do {
            try await second.update { $0.highlights.removeAll() }
            XCTFail("A stale client must not overwrite the saved library")
        } catch LibraryStore.StoreError.conflict {}
        XCTAssertEqual(second.state, LibraryState())
        XCTAssertTrue(second.requiresReload)
        do {
            try await second.update { $0.highlights.removeAll() }
            XCTFail("A failed write must require reload before retry")
        } catch LibraryStore.StoreError.reloadRequired {}
        try await second.reload()
        XCTAssertEqual(second.state, imported)
        XCTAssertFalse(second.requiresReload)
        do {
            try await second.importIfEmpty(LibraryState())
            XCTFail("Import must refuse a populated remote library")
        } catch LibraryStore.StoreError.libraryNotEmpty {}

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask { @MainActor in
                    try await second.update {
                        $0.highlights.append(Highlight(documentID: "paper", quote: "Concurrent \(index)"))
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(second.state.highlights.count, 5)
        try await second.recoverInterruptedRuns()
        try await first.reload()
        XCTAssertEqual(first.state, second.state)
        XCTAssertEqual(first.state.threads[0].messages[0].status, .interrupted)

        var secure = configuration
        secure.tls = .verify
        do {
            _ = try await LibraryStore.openPostgres(configuration: secure, password: password)
            XCTFail("Verified TLS must not silently downgrade to plaintext")
        } catch LibraryStore.StoreError.remoteUnavailable {}
    }
}
