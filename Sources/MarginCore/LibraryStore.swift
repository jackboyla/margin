import Foundation

@MainActor
public final class LibraryStore {
    public enum StoreError: LocalizedError {
        case unsupportedSchema(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                return "This library uses unsupported schema version \(version)."
            }
        }
    }

    public private(set) var state: LibraryState
    private let fileURL: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("library.json")
        self.fileURL = fileURL

        var loaded: LibraryState
        if FileManager.default.fileExists(atPath: fileURL.path) {
            loaded = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: fileURL))
        } else {
            loaded = LibraryState()
        }
        try Self.validate(loaded)

        var recovered = false
        for threadIndex in loaded.threads.indices {
            for messageIndex in loaded.threads[threadIndex].messages.indices {
                if loaded.threads[threadIndex].messages[messageIndex].status == .running {
                    loaded.threads[threadIndex].messages[messageIndex].status = .interrupted
                    recovered = true
                }
            }
        }
        if recovered {
            try Self.write(loaded, to: fileURL)
        }
        state = loaded
    }

    public func update(_ mutation: (inout LibraryState) throws -> Void) throws {
        var candidate = state
        try mutation(&candidate)
        try Self.validate(candidate)
        try Self.write(candidate, to: fileURL)
        state = candidate
    }

    private static func validate(_ state: LibraryState) throws {
        guard state.schemaVersion == 1 else {
            throw StoreError.unsupportedSchema(state.schemaVersion)
        }
    }

    private static func write(_ state: LibraryState, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
