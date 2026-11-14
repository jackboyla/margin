import Foundation

@MainActor
public final class LibraryStore {
    public enum StoreError: LocalizedError, Equatable {
        case unsupportedSchema(Int)
        case invalidLibrary
        case database(String)
        case conflict

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                return "This library uses unsupported schema version \(version)."
            case .invalidLibrary:
                return "The saved library is invalid. Its contents have not been replaced."
            case .database(let message):
                return "The library could not be saved or read: \(message)"
            case .conflict:
                return "Another instance changed this library. Quit and reopen Margin before trying again."
            }
        }
    }

    public private(set) var state: LibraryState
    private let database: SQLiteLibrary
    private var revision: String

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try SQLiteLibrary(directory: directory)
        let snapshot = try database.load()
        state = snapshot.state
        revision = snapshot.revision
        var recovered = state
        for thread in recovered.threads.indices {
            for message in recovered.threads[thread].messages.indices {
                if recovered.threads[thread].messages[message].status == .running {
                    recovered.threads[thread].messages[message].status = .interrupted
                }
            }
        }
        if recovered != state {
            revision = try database.save(recovered, previous: state, replacing: revision)
            state = recovered
        }
    }

    public func update(_ mutation: (inout LibraryState) throws -> Void) async throws {
        try Task.checkCancellation()
        var candidate = state
        try mutation(&candidate)
        revision = try database.save(candidate, previous: state, replacing: revision)
        state = candidate
    }
}
