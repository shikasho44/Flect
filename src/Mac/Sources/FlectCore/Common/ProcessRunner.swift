import Foundation

public struct ProcessResult {
    public let exitCode: Int32
    public let crashed: Bool
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { exitCode == 0 && !crashed }
}

public struct ProcessFailure: LocalizedError {
    public let message: String
    public let exitCode: Int32
    public let crashed: Bool

    public var errorDescription: String? { message }
}

private final class OutputCollector {
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()
    private var pending = Data()
    private let onLine: ((String) -> Void)?

    init(onLine: ((String) -> Void)?) { self.onLine = onLine }

    func appendOutput(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        output.append(data)
        if onLine != nil {
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                lines.append(String(decoding: line, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        lock.unlock()
        for line in lines { onLine?(line) }
    }

    func appendError(_ data: Data) {
        lock.lock()
        errors.append(data)
        lock.unlock()
    }

    func finish() -> (String, String) {
        lock.lock()
        let rest = pending
        pending.removeAll()
        let result = (String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self))
        lock.unlock()
        if !rest.isEmpty { onLine?(String(decoding: rest, as: UTF8.self)) }
        return result
    }
}

private final class ProcessHandle: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var launched = false
    private var cancelled = false

    func markLaunched() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        launched = true
        return !cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = launched && process.isRunning
        lock.unlock()
        guard running else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String],
                           workingDirectory: String? = nil,
                           environment: [String: String]? = nil,
                           background: Bool = false,
                           onOutputLine: ((String) -> Void)? = nil) async throws -> ProcessResult {
        try Task.checkCancellation()

        let handle = ProcessHandle()
        let process = handle.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (name, value) in environment { merged[name] = value }
            process.environment = merged
        }
        if background { process.qualityOfService = .utility }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(onLine: onOutputLine)
        let pumps = DispatchGroup()
        pump(outputPipe.fileHandleForReading, group: pumps, into: collector.appendOutput)
        pump(errorPipe.fileHandleForReading, group: pumps, into: collector.appendError)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                    if !handle.markLaunched() { handle.cancel() }
                } catch {
                    process.terminationHandler = nil
                    try? outputPipe.fileHandleForWriting.close()
                    try? errorPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            handle.cancel()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pumps.notify(queue: .global()) { continuation.resume() }
        }

        let (output, errors) = collector.finish()
        try Task.checkCancellation()
        return ProcessResult(exitCode: process.terminationStatus,
                             crashed: process.terminationReason == .uncaughtSignal,
                             standardOutput: output,
                             standardError: errors)
    }

    @discardableResult
    public static func runOrThrow(_ executable: String, _ arguments: [String],
                                  workingDirectory: String? = nil,
                                  environment: [String: String]? = nil,
                                  background: Bool = false,
                                  onOutputLine: ((String) -> Void)? = nil) async throws -> ProcessResult {
        let result = try await run(executable, arguments, workingDirectory: workingDirectory,
                                   environment: environment, background: background, onOutputLine: onOutputLine)
        if result.succeeded { return result }

        var detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty { detail = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) }
        let tail = detail.split(separator: "\n").suffix(3).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let name = ((executable as NSString).lastPathComponent as NSString).deletingPathExtension
        let code = result.crashed ? "signal \(result.exitCode)" : "exit \(result.exitCode)"
        throw ProcessFailure(message: "\(name) failed (\(code)). \(tail)", exitCode: result.exitCode, crashed: result.crashed)
    }

    private static func pump(_ handle: FileHandle, group: DispatchGroup, into sink: @escaping (Data) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                sink(data)
            }
            group.leave()
        }
    }
}
