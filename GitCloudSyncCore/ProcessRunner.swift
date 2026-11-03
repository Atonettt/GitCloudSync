import Foundation

/// Result of a finished (or timed-out) child process.
public struct ProcessResult: Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let exitCode: Int32
    public let stdoutData: Data
    public let stderrData: Data
    public let duration: TimeInterval
    public let timedOut: Bool

    public var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
    public var stderr: String { String(decoding: stderrData, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 && !timedOut }

    public var commandLine: String {
        ([URL(fileURLWithPath: executablePath).lastPathComponent] + arguments.map(Self.shellQuote))
            .joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@%+,^{}"))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct ProcessLaunchError: Error, LocalizedError, Sendable {
    public let executablePath: String
    public let reason: String
    public var errorDescription: String? { "无法启动 \(executablePath)：\(reason)" }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock(); storage.append(data); lock.unlock()
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// Tracks the race between normal termination and the timeout.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var didTimeOut = false

    var timedOut: Bool { lock.withLock { didTimeOut } }

    /// Returns false when the process already finished.
    func markTimedOut() -> Bool {
        lock.withLock {
            if finished { return false }
            didTimeOut = true
            return true
        }
    }

    func markFinished() { lock.withLock { finished = true } }
}

private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
}

/// Runs external programs without ever attaching a terminal.
///
/// * stdin is `/dev/null` unless data is supplied, so nothing can block on input.
/// * A timeout sends SIGTERM, then SIGKILL three seconds later.
/// * Task cancellation terminates the child.
public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        process.standardOutput = box.stdout
        process.standardError = box.stderr

        let stdinPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }

        let outBuffer = OutputBuffer()
        let errBuffer = OutputBuffer()
        let state = RunState()

        box.stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { outBuffer.append(data) }
        }
        box.stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errBuffer.append(data) }
        }

        let start = Date()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { finished in
                    state.markFinished()
                    box.stdout.fileHandleForReading.readabilityHandler = nil
                    box.stderr.fileHandleForReading.readabilityHandler = nil

                    // Drain what is left in the pipes, but never wait forever:
                    // a grandchild (ssh, credential helper) may still hold the write end.
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let restOut = (try? box.stdout.fileHandleForReading.readToEnd()) ?? nil
                        let restErr = (try? box.stderr.fileHandleForReading.readToEnd()) ?? nil
                        if let restOut { outBuffer.append(restOut) }
                        if let restErr { errBuffer.append(restErr) }
                        group.leave()
                    }
                    _ = group.wait(timeout: .now() + 2)

                    let result = ProcessResult(
                        executablePath: executable.path,
                        arguments: arguments,
                        exitCode: finished.terminationStatus,
                        stdoutData: outBuffer.data,
                        stderrData: errBuffer.data,
                        duration: Date().timeIntervalSince(start),
                        timedOut: state.timedOut
                    )
                    continuation.resume(returning: result)
                }

                do {
                    try process.run()
                } catch {
                    box.stdout.fileHandleForReading.readabilityHandler = nil
                    box.stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: ProcessLaunchError(
                        executablePath: executable.path,
                        reason: error.localizedDescription
                    ))
                    return
                }

                if let stdin, let stdinPipe {
                    let writer = stdinPipe.fileHandleForWriting
                    DispatchQueue.global(qos: .utility).async {
                        try? writer.write(contentsOf: stdin)
                        try? writer.close()
                    }
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard state.markTimedOut(), box.process.isRunning else { return }
                    box.process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                        if box.process.isRunning {
                            kill(box.process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }
}
