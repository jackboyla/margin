import Foundation
import Logging
import NIOSSL
import PostgresNIO

public struct PostgresConfiguration: Codable, Equatable, Sendable {
    public enum TLS: String, Codable, CaseIterable, Sendable {
        case verify
        case disabled
    }

    public var host: String
    public var port: Int
    public var database: String
    public var username: String
    public var libraryID: String
    public var tls: TLS

    public init(host: String = "localhost", port: Int = 5432, database: String = "margin",
                username: String = "", libraryID: String = "personal", tls: TLS = .verify) {
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.libraryID = libraryID
        self.tls = tls
    }

    func validate() throws {
        guard (1...65535).contains(port),
              [host, database, username, libraryID].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LibraryStore.StoreError.invalidConfiguration
        }
    }
}

struct PostgresLibraryStorage {
    let configuration: PostgresConfiguration
    private let password: String
    private let logger = Logger(label: "Margin.Postgres", factory: { _ in SwiftLogNoOpLogHandler() })

    init(configuration: PostgresConfiguration, password: String) throws {
        try configuration.validate()
        self.configuration = configuration
        self.password = password
    }

    func open() async throws -> (LibraryState, UUID) {
        try await withConnection { connection in
            let create = try await connection.query("""
                CREATE TABLE IF NOT EXISTS margin_libraries (
                    library_id TEXT PRIMARY KEY,
                    revision UUID NOT NULL,
                    state JSONB NOT NULL
                )
                """, logger: logger)
            for try await _ in create {}
            let empty = String(decoding: try JSONEncoder().encode(LibraryState()), as: UTF8.self)
            let insert = try await connection.query("""
                INSERT INTO margin_libraries (library_id, revision, state)
                VALUES (\(configuration.libraryID), \(UUID()), \(empty)::jsonb)
                ON CONFLICT (library_id) DO NOTHING
                """, logger: logger)
            for try await _ in insert {}
            return try await read(from: connection)
        }
    }

    func read() async throws -> (LibraryState, UUID) {
        try await withConnection { try await read(from: $0) }
    }

    func write(_ state: LibraryState, replacing revision: UUID) async throws -> UUID {
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let nextRevision = UUID()
        return try await withConnection { connection in
            let rows = try await connection.query("""
                UPDATE margin_libraries SET state = \(json)::jsonb, revision = \(nextRevision)
                WHERE library_id = \(configuration.libraryID) AND revision = \(revision)
                RETURNING revision
                """, logger: logger)
            var savedRevision: UUID?
            for try await value in rows.decode(UUID.self) { savedRevision = value }
            guard let savedRevision else { throw LibraryStore.StoreError.conflict }
            return savedRevision
        }
    }

    private func read(from connection: PostgresConnection) async throws -> (LibraryState, UUID) {
        let rows = try await connection.query("""
            SELECT state::text, revision FROM margin_libraries WHERE library_id = \(configuration.libraryID)
            """, logger: logger)
        var snapshot: (LibraryState, UUID)?
        for try await (json, revision) in rows.decode((String, UUID).self) {
            do {
                snapshot = (try JSONDecoder().decode(LibraryState.self, from: Data(json.utf8)), revision)
            } catch {
                throw LibraryStore.StoreError.invalidRemoteLibrary
            }
        }
        guard let snapshot else { throw LibraryStore.StoreError.remoteLibraryMissing }
        return snapshot
    }

    private func withConnection<T>(_ operation: (PostgresConnection) async throws -> T) async throws -> T {
        do {
            let tls: PostgresConnection.Configuration.TLS
            switch configuration.tls {
            case .verify:
                tls = .require(try NIOSSLContext(configuration: .makeClientConfiguration()))
            case .disabled:
                tls = .disable
            }
            var settings = PostgresConnection.Configuration(
                host: configuration.host, port: configuration.port, username: configuration.username,
                password: password, database: configuration.database, tls: tls)
            settings.options.additionalStartupParameters = [("statement_timeout", "15000")]
            let connection = try await PostgresConnection.connect(configuration: settings, id: 0, logger: logger)
            do {
                let result = try await operation(connection)
                try? await connection.closeGracefully()
                return result
            } catch {
                try? await connection.close()
                throw error
            }
        } catch let error as LibraryStore.StoreError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Driver errors may contain connection details, bound library data or credentials.
            throw LibraryStore.StoreError.remoteUnavailable
        }
    }
}
