import Foundation

@MainActor
public final class LibraryStore {
    public enum StoreError: LocalizedError, Equatable {
        case unsupportedSchema(Int)
        case invalidConfiguration
        case invalidRemoteLibrary
        case remoteLibraryMissing
        case remoteUnavailable
        case conflict
        case reloadRequired
        case libraryNotEmpty

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                return "This library uses unsupported schema version \(version)."
            case .invalidConfiguration:
                return "Enter a host, database, username, library name and a port between 1 and 65535."
            case .invalidRemoteLibrary:
                return "The PostgreSQL library could not be decoded. Its saved data has not been replaced."
            case .remoteLibraryMissing:
                return "This PostgreSQL library no longer exists. Reconnect to create or open a library."
            case .remoteUnavailable:
                return "PostgreSQL could not complete the request. Check the connection, credentials, TLS and database permissions. Reload before trying another change."
            case .conflict:
                return "Another client changed this library. Your change was not saved. Reload the library before trying again."
            case .reloadRequired:
                return "Reload the PostgreSQL library before making another change. The last write could not be confirmed."
            case .libraryNotEmpty:
                return "Import requires an empty destination library. Choose a new library name to keep both libraries."
            }
        }
    }

    public private(set) var state: LibraryState
    public private(set) var requiresReload = false

    private enum Backend {
        case local(URL)
        case postgres(PostgresLibraryStorage, UUID)
    }
    private var backend: Backend
    private var operationInProgress = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("library.json")
        backend = .local(fileURL)
        var loaded = try Self.read(from: fileURL)
        if Self.recover(&loaded) {
            try Self.write(loaded, to: fileURL)
        }
        state = loaded
    }

    private init(state: LibraryState, storage: PostgresLibraryStorage, revision: UUID) {
        self.state = state
        backend = .postgres(storage, revision)
    }

    public static func openPostgres(configuration: PostgresConfiguration, password: String) async throws -> LibraryStore {
        let storage = try PostgresLibraryStorage(configuration: configuration, password: password)
        let (state, revision) = try await storage.open()
        try validate(state)
        // A remote running reply may still belong to a live client. Recovery is explicit.
        return LibraryStore(state: state, storage: storage, revision: revision)
    }

    public func update(_ mutation: (inout LibraryState) throws -> Void) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        var candidate = state
        try mutation(&candidate)
        try await save(candidate)
    }

    public func reload() async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        switch backend {
        case .local(let fileURL):
            state = try Self.read(from: fileURL)
        case .postgres(let storage, _):
            let (loaded, revision) = try await storage.read()
            try Self.validate(loaded)
            backend = .postgres(storage, revision)
            state = loaded
        }
        requiresReload = false
    }

    public func importIfEmpty(_ source: LibraryState) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard state.documents.isEmpty, state.highlights.isEmpty, state.threads.isEmpty else {
            throw StoreError.libraryNotEmpty
        }
        try await save(source)
    }

    /// Call only when the user knows that no other client is still producing these replies.
    public func recoverInterruptedRuns() async throws {
        try await update { _ = Self.recover(&$0) }
    }

    private func save(_ candidate: LibraryState) async throws {
        guard !requiresReload else { throw StoreError.reloadRequired }
        try Self.validate(candidate)
        switch backend {
        case .local(let fileURL):
            try Self.write(candidate, to: fileURL)
        case .postgres(let storage, let revision):
            do {
                let nextRevision = try await storage.write(candidate, replacing: revision)
                backend = .postgres(storage, nextRevision)
            } catch {
                // A dropped response can hide a committed write. Reload before any retry.
                requiresReload = true
                throw error
            }
        }
        state = candidate
    }

    private func acquire() async {
        if operationInProgress {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            operationInProgress = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            operationInProgress = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private static func recover(_ state: inout LibraryState) -> Bool {
        var recovered = false
        for threadIndex in state.threads.indices {
            for messageIndex in state.threads[threadIndex].messages.indices {
                if state.threads[threadIndex].messages[messageIndex].status == .running {
                    state.threads[threadIndex].messages[messageIndex].status = .interrupted
                    recovered = true
                }
            }
        }
        return recovered
    }

    private static func validate(_ state: LibraryState) throws {
        guard state.schemaVersion == 1 else {
            throw StoreError.unsupportedSchema(state.schemaVersion)
        }
    }

    private static func read(from fileURL: URL) throws -> LibraryState {
        let loaded: LibraryState
        if FileManager.default.fileExists(atPath: fileURL.path) {
            loaded = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: fileURL))
        } else {
            loaded = LibraryState()
        }
        try validate(loaded)
        return loaded
    }

    private static func write(_ state: LibraryState, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
