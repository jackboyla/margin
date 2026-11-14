import Foundation
import SQLite3

final class SQLiteLibrary {
    private var handle: OpaquePointer?
    private enum Value {
        case text(String), real(Double), integer(Int), null
        static func optional(_ value: String?) -> Value { value.map(Value.text) ?? .null }
    }

    init(directory: URL) throws {
        let path = directory.appendingPathComponent("library.sqlite").path
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let error = databaseError()
            sqlite3_close_v2(handle)
            handle = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(handle, 100)
            try execute("PRAGMA foreign_keys = ON")
            var version = 0
            try rows("PRAGMA user_version") { version = Int(sqlite3_column_int($0, 0)) }
            guard version == 0 || version == 1 else {
                throw LibraryStore.StoreError.unsupportedSchema(version)
            }
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            let legacyURL = directory.appendingPathComponent("library.json")
            if version == 0 {
                try transaction {
                    var tableCount = 0
                    try rows("SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") {
                        tableCount = Int(sqlite3_column_int($0, 0))
                    }
                    guard tableCount == 0 else { throw LibraryStore.StoreError.invalidLibrary }
                    let hasLegacy = FileManager.default.fileExists(atPath: legacyURL.path)
                    let initial = hasLegacy
                        ? try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: legacyURL))
                        : LibraryState()
                    try validate(initial)
                    try createSchema()
                    try execute("INSERT INTO metadata VALUES (1, ?, ?)", [.text(UUID().uuidString), .integer(hasLegacy ? 1 : 0)])
                    try updateRows(initial, previous: LibraryState())
                    guard try readState() == initial else { throw LibraryStore.StoreError.invalidLibrary }
                    try execute("PRAGMA user_version = 1")
                }
            }
            // The committed marker lets a restart finish the rename without importing twice.
            var migrated = false
            try rows("SELECT legacy_imported FROM metadata WHERE id = 1") {
                migrated = sqlite3_column_int($0, 0) == 1
            }
            let backupURL = directory.appendingPathComponent("library.json.migrated")
            if migrated && FileManager.default.fileExists(atPath: legacyURL.path)
                && !FileManager.default.fileExists(atPath: backupURL.path) {
                _ = try load()
                try FileManager.default.moveItem(at: legacyURL, to: backupURL)
            }
        } catch {
            sqlite3_close_v2(handle)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close_v2(handle) }

    func load() throws -> (state: LibraryState, revision: String) {
        try transaction(immediate: false) {
            (try readState(), try readRevision())
        }
    }

    func save(_ state: LibraryState, previous: LibraryState, replacing revision: String) throws -> String {
        try validate(state)
        return try transaction {
            guard try readRevision() == revision else { throw LibraryStore.StoreError.conflict }
            try updateRows(state, previous: previous)
            let next = UUID().uuidString
            try execute("UPDATE metadata SET revision = ? WHERE id = 1", [.text(next)])
            return next
        }
    }

    private func validate(_ state: LibraryState) throws {
        guard state.schemaVersion == 1 else {
            throw LibraryStore.StoreError.unsupportedSchema(state.schemaVersion)
        }
    }

    private func createSchema() throws {
        try execute("""
            CREATE TABLE metadata (
                id INTEGER PRIMARY KEY CHECK (id = 1), revision TEXT NOT NULL,
                legacy_imported INTEGER NOT NULL CHECK (legacy_imported IN (0, 1))
            )
            """)
        try execute("""
            CREATE TABLE documents (
                id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL,
                title TEXT NOT NULL, url TEXT, app_name TEXT NOT NULL, updated_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE highlights (
                id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, document_id TEXT NOT NULL,
                quote TEXT NOT NULL, context_text TEXT NOT NULL, created_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE threads (
                id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, document_id TEXT NOT NULL,
                title TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
                provider_session_id TEXT, agent_json TEXT
            )
            """)
        try execute("""
            CREATE TABLE messages (
                thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                id TEXT NOT NULL, position INTEGER NOT NULL,
                role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
                body TEXT NOT NULL,
                status TEXT NOT NULL CHECK (status IN ('complete', 'running', 'interrupted', 'failed')),
                created_at REAL NOT NULL, context_json TEXT,
                PRIMARY KEY (thread_id, id)
            )
            """)
    }

    private func updateRows(_ state: LibraryState, previous: LibraryState) throws {
        try reconcile(state.documents, previous: previous.documents, delete: { id in
            try execute("DELETE FROM documents WHERE id = ?", [.text(id)])
        }) { position, document, _ in
            try execute("""
                INSERT INTO documents VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET position = excluded.position, title = excluded.title,
                    url = excluded.url, app_name = excluded.app_name, updated_at = excluded.updated_at
                """, [
                    .text(document.id), .integer(position), .text(document.title), .optional(document.url),
                    .text(document.appName), .real(document.updatedAt.timeIntervalSinceReferenceDate),
                ])
        }
        try reconcile(state.highlights, previous: previous.highlights, delete: { id in
            try execute("DELETE FROM highlights WHERE id = ?", [.text(id.uuidString)])
        }) { position, highlight, _ in
            try execute("""
                INSERT INTO highlights VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET position = excluded.position, document_id = excluded.document_id,
                    quote = excluded.quote, context_text = excluded.context_text, created_at = excluded.created_at
                """, [
                    .text(highlight.id.uuidString), .integer(position), .text(highlight.documentID),
                    .text(highlight.quote), .text(highlight.contextText), .real(highlight.createdAt.timeIntervalSinceReferenceDate),
                ])
        }
        try reconcile(state.threads, previous: previous.threads, delete: { id in
            try execute("DELETE FROM threads WHERE id = ?", [.text(id.uuidString)])
        }) { position, thread, oldThread in
            try execute("""
                INSERT INTO threads VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET position = excluded.position, document_id = excluded.document_id,
                    title = excluded.title, created_at = excluded.created_at, updated_at = excluded.updated_at,
                    provider_session_id = excluded.provider_session_id, agent_json = excluded.agent_json
                """, [
                    .text(thread.id.uuidString), .integer(position), .text(thread.documentID), .text(thread.title),
                    .real(thread.createdAt.timeIntervalSinceReferenceDate), .real(thread.updatedAt.timeIntervalSinceReferenceDate),
                    .optional(thread.providerSessionID), .optional(try json(thread.agent)),
                ])
            try reconcile(thread.messages, previous: oldThread?.messages ?? [], delete: { id in
                try execute("DELETE FROM messages WHERE thread_id = ? AND id = ?", [.text(thread.id.uuidString), .text(id.uuidString)])
            }) { messagePosition, message, _ in
                try execute("""
                    INSERT INTO messages VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(thread_id, id) DO UPDATE SET position = excluded.position, role = excluded.role,
                        body = excluded.body, status = excluded.status, created_at = excluded.created_at,
                        context_json = excluded.context_json
                    """, [
                        .text(thread.id.uuidString), .text(message.id.uuidString), .integer(messagePosition),
                        .text(message.role.rawValue), .text(message.body), .text(message.status.rawValue),
                        .real(message.createdAt.timeIntervalSinceReferenceDate), .optional(try json(message.context)),
                    ])
            }
        }
    }

    private func reconcile<Record: Identifiable & Equatable>(
        _ records: [Record], previous: [Record], delete: (Record.ID) throws -> Void,
        write: (Int, Record, Record?) throws -> Void
    ) throws {
        guard records != previous else { return }
        var old: [Record.ID: (position: Int, record: Record)] = [:]
        for (position, record) in previous.enumerated() {
            guard old.updateValue((position, record), forKey: record.id) == nil else {
                throw LibraryStore.StoreError.invalidLibrary
            }
        }
        var ids = Set<Record.ID>()
        for record in records {
            guard ids.insert(record.id).inserted else { throw LibraryStore.StoreError.invalidLibrary }
        }
        for record in previous where !ids.contains(record.id) { try delete(record.id) }
        for (position, record) in records.enumerated() {
            let before = old[record.id]
            if before?.position != position || before?.record != record {
                try write(position, record, before?.record)
            }
        }
    }

    private func readState() throws -> LibraryState {
        var state = LibraryState()
        try rows("SELECT id, title, url, app_name, updated_at FROM documents ORDER BY position") { row in
            state.documents.append(try DocumentRecord(id: text(row, 0), title: text(row, 1),
                url: optionalText(row, 2), appName: text(row, 3), updatedAt: date(row, 4)))
        }
        try rows("SELECT id, document_id, quote, context_text, created_at FROM highlights ORDER BY position") { row in
            state.highlights.append(try Highlight(id: uuid(row, 0), documentID: text(row, 1),
                quote: text(row, 2), contextText: text(row, 3), createdAt: date(row, 4)))
        }
        try rows("SELECT id, document_id, title, created_at, updated_at, provider_session_id, agent_json FROM threads ORDER BY position") { row in
            state.threads.append(try ThreadRecord(id: uuid(row, 0), documentID: text(row, 1), title: text(row, 2),
                createdAt: date(row, 3), updatedAt: date(row, 4), providerSessionID: optionalText(row, 5),
                agent: decode(AgentConfiguration.self, from: optionalText(row, 6))))
        }
        var indices: [UUID: Int] = [:]
        for (index, thread) in state.threads.enumerated() {
            guard indices.updateValue(index, forKey: thread.id) == nil else {
                throw LibraryStore.StoreError.invalidLibrary
            }
        }
        try rows("SELECT thread_id, id, role, body, status, created_at, context_json FROM messages ORDER BY position") { row in
            guard let index = indices[try uuid(row, 0)],
                  let role = ChatMessage.Role(rawValue: try text(row, 2)),
                  let status = ChatMessage.Status(rawValue: try text(row, 4)) else {
                throw LibraryStore.StoreError.invalidLibrary
            }
            state.threads[index].messages.append(try ChatMessage(id: uuid(row, 1), role: role,
                body: text(row, 3), status: status, createdAt: date(row, 5),
                context: decode(SourceContext.self, from: optionalText(row, 6))))
        }
        return state
    }

    private func readRevision() throws -> String {
        var revision: String?
        try rows("SELECT revision FROM metadata WHERE id = 1") { revision = try text($0, 0) }
        guard let revision else { throw LibraryStore.StoreError.invalidLibrary }
        return revision
    }

    private func transaction<T>(immediate: Bool = true, _ body: () throws -> T) throws -> T {
        try execute(immediate ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, _ bindings: [Value] = []) throws {
        try rows(sql, bindings) { _ in }
    }

    private func rows(_ sql: String, _ bindings: [Value] = [], _ visit: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let string):
                result = string.withCString {
                    sqlite3_bind_text64(statement, index, $0, UInt64(string.utf8.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self), UInt8(SQLITE_UTF8))
                }
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .integer(let number): result = sqlite3_bind_int64(statement, index, Int64(number))
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw databaseError() }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try visit(statement)
            case SQLITE_DONE: return
            default: throw databaseError()
            }
        }
    }

    private func databaseError() -> LibraryStore.StoreError {
        .database(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open the database.")
    }

    private func text(_ row: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(row, column) == SQLITE_TEXT, let bytes = sqlite3_column_text(row, column) else {
            throw LibraryStore.StoreError.invalidLibrary
        }
        guard let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, column))), encoding: .utf8) else {
            throw LibraryStore.StoreError.invalidLibrary
        }
        return value
    }

    private func optionalText(_ row: OpaquePointer, _ column: Int32) throws -> String? {
        sqlite3_column_type(row, column) == SQLITE_NULL ? nil : try text(row, column)
    }

    private func uuid(_ row: OpaquePointer, _ column: Int32) throws -> UUID {
        guard let value = UUID(uuidString: try text(row, column)) else { throw LibraryStore.StoreError.invalidLibrary }
        return value
    }

    private func date(_ row: OpaquePointer, _ column: Int32) throws -> Date {
        let type = sqlite3_column_type(row, column)
        let value = sqlite3_column_double(row, column)
        guard (type == SQLITE_FLOAT || type == SQLITE_INTEGER), value.isFinite else {
            throw LibraryStore.StoreError.invalidLibrary
        }
        return Date(timeIntervalSinceReferenceDate: value)
    }

    private func json<T: Encodable>(_ value: T?) throws -> String? {
        try value.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String?) throws -> T? {
        try json.map { try JSONDecoder().decode(type, from: Data($0.utf8)) }
    }
}
