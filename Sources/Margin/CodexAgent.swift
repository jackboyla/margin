import Foundation
import Darwin

@MainActor
public final class CodexAgent {
    public private(set) var isRunning = false
    private var active: CodexExecution?

    public init() {}

    public static func defaultExecutable() -> URL? {
        let paths = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    public func run(
        prompt: String, imagePath: String?, sessionID: String?, workingDirectory: URL,
        executable: URL, model: String?, onSession: @escaping (String) async -> Void,
        onActivity: @escaping (String) -> Void
    ) async throws -> String {
        guard active == nil else { throw CodexFailure("Codex is already running.") }
        try Task.checkCancellation()
        let execution = CodexExecution(prompt: prompt, imagePath: imagePath, sessionID: sessionID,
                                       workingDirectory: workingDirectory, executable: executable, model: model)
        active = execution
        isRunning = true
        defer { active = nil; isRunning = false }
        onActivity("Starting Codex…")
        let updates = Task { @MainActor in
            for await event in execution.events {
                switch event {
                case .session(let id): await onSession(id)
                case .activity(let message): onActivity(message)
                }
            }
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await execution.run()
            } onCancel: {
                execution.cancel()
            }
            await updates.value
            return response
        } catch {
            await updates.value
            throw error
        }
    }

    public func cancel() { active?.cancel() }
}

private struct CodexFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private enum CodexEvent: Sendable {
    case session(String)
    case activity(String)
}

private final class CodexExecution: @unchecked Sendable {
    let events: AsyncStream<CodexEvent>
    private let eventSink: AsyncStream<CodexEvent>.Continuation
    private let prompt: String
    private let imagePath: String?
    private let sessionID: String?
    private let workingDirectory: URL
    private let executable: URL
    private let model: String?
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("margin-codex-\(UUID().uuidString)")
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    init(prompt: String, imagePath: String?, sessionID: String?, workingDirectory: URL,
         executable: URL, model: String?) {
        (events, eventSink) = AsyncStream.makeStream()
        self.prompt = prompt
        self.imagePath = imagePath
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.executable = executable
        self.model = model
    }

    func run() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).async { self.execute() }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        } else {
            finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
        eventSink.finish()
        continuation?.resume(with: result)
    }

    private func execute() {
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let inputURL = directory.appendingPathComponent("prompt.txt")
            let outputURL = directory.appendingPathComponent("response.txt")
            try Data(prompt.utf8).write(to: inputURL)
            let input = try FileHandle(forReadingFrom: inputURL)
            defer { try? input.close() }
            let output = Pipe()
            let errors = Pipe()
            let process = Process()
            process.executableURL = executable
            process.currentDirectoryURL = workingDirectory
            var arguments = ["exec", "-c", "sandbox_mode=\"read-only\"", "-c", "approval_policy=\"never\"",
                             "-C", workingDirectory.path]
            if sessionID != nil { arguments.append("resume") }
            arguments += ["--json", "--skip-git-repo-check", "-o", outputURL.path]
            if let model, !model.isEmpty { arguments += ["--model", model] }
            if let imagePath { arguments += ["--image", imagePath] }
            arguments.append("--")
            if let sessionID { arguments.append(sessionID) }
            arguments.append("-")
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors

            lock.lock()
            if cancelled { lock.unlock(); return }
            self.process = process
            do { try process.run() } catch { lock.unlock(); throw error }
            lock.unlock()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()

            let diagnostics = CodexDiagnostics()
            let readers = DispatchGroup()
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                self.readEvents(output.fileHandleForReading, process: process, diagnostics: diagnostics)
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                Self.read(errors.fileHandleForReading, process: process) { diagnostics.append($0) }
                readers.leave()
            }
            process.waitUntilExit()
            readers.wait()
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { throw CancellationError() }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw CodexFailure("Codex stopped (status \(process.terminationStatus)).\(diagnostics.details)")
            }
            if let failure = diagnostics.failure { throw CodexFailure(failure) }
            guard let response = try? String(contentsOf: outputURL, encoding: .utf8),
                  !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CodexFailure("Codex finished without a response.\(diagnostics.details)")
            }
            finish(.success(response))
        } catch {
            finish(.failure(error))
        }
    }

    private static func read(_ handle: FileHandle, process: Process, consume: (Data) -> Void) {
        defer { try? handle.close() }
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { consume(Data(bytes.prefix(count))); continue }
            if count == 0 { return }
            if errno == EINTR { continue }
            guard errno == EAGAIN, process.isRunning else { return }
            // A descendant can keep the pipe open after Codex exits; stop once buffered output drains.
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            _ = poll(&readiness, 1, 250)
        }
    }

    private func readEvents(_ handle: FileHandle, process: Process, diagnostics: CodexDiagnostics) {
        var buffer = Data()
        var discardingLine = false
        var previousActivity: String?
        func consumeLine() {
            guard !discardingLine, let event = (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any],
                  let type = event["type"] as? String else { return }
            if type == "thread.started", let id = event["thread_id"] as? String {
                eventSink.yield(.session(id))
            }
            if type == "turn.failed" {
                let error = event["error"] as? [String: Any]
                diagnostics.recordFailure(error?["message"] as? String ?? event["message"] as? String ?? "Codex could not complete the turn.")
            } else if type == "error", let message = event["message"] as? String {
                diagnostics.append(Data((message + "\n").utf8))
            }
            let item = event["item"] as? [String: Any]
            let activity: String?
            switch item?["type"] as? String {
            case "command_execution": activity = "Reading with a command…"
            case "web_search": activity = "Searching the web…"
            case "mcp_tool_call": activity = "Using a tool…"
            case "agent_message": activity = "Writing a response…"
            case "reasoning": activity = "Thinking…"
            default: activity = type == "turn.started" ? "Thinking…" : nil
            }
            if let activity, activity != previousActivity {
                previousActivity = activity
                eventSink.yield(.activity(activity))
            }
        }
        Self.read(handle, process: process) { chunk in
            for byte in chunk {
                if byte != 10 {
                    if !discardingLine {
                        if buffer.count < 1_048_576 { buffer.append(byte) }
                        else { buffer.removeAll(keepingCapacity: true); discardingLine = true }
                    }
                    continue
                }
                consumeLine()
                buffer.removeAll(keepingCapacity: true)
                discardingLine = false
            }
        }
        if !buffer.isEmpty { consumeLine() }
    }
}

private final class CodexDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = Data()
    private var recordedFailure: String?

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        tail.append(data)
        if tail.count > 16_384 { tail = Data(tail.suffix(16_384)) }
    }

    func recordFailure(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        recordedFailure = String(message.prefix(4096))
    }

    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return recordedFailure
    }

    var details: String {
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let messages = [recordedFailure, text.isEmpty ? nil : text].compactMap { $0 }
        return messages.isEmpty ? "" : "\n" + messages.joined(separator: "\n")
    }
}
