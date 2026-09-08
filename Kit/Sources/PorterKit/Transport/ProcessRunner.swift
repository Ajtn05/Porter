import Foundation

/// Async wrapper around `Process` with three things Foundation does not give us:
/// streaming stdout without buffering the whole output, cooperative
/// cancellation, and a timeout that actually kills the child.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public var stdoutText: String { String(decoding: standardOutput, as: UTF8.self) }
    public var stderrText: String { String(decoding: standardError, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 }
}

public enum ProcessRunner {
    /// Runs to completion and buffers the output. For commands whose output is
    /// small and bounded: `adb devices`, `stat`, `df`.
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: URL? = nil,
        timeout: Duration? = .seconds(30)
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let standardInput {
            process.standardInput = try FileHandle(forReadingFrom: standardInput)
        }

        let collector = OutputCollector()

        // Read both pipes concurrently. Draining only one deadlocks as soon as
        // the child fills the other pipe's 64 KB buffer — which `adb pull` does.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.appendOut(data)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.appendErr(data)
            }
        }

        try process.run()

        let timeoutTask: Task<Void, Never>? = timeout.map { limit in
            Task {
                try? await Task.sleep(for: limit)
                if process.isRunning { process.terminate() }
            }
        }

        defer {
            timeoutTask?.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
            }
        } onCancel: {
            process.terminate()
        }

        // Drain whatever the handlers had not picked up before exit.
        collector.appendOut((try? outPipe.fileHandleForReading.readToEnd()) ?? Data())
        collector.appendErr((try? errPipe.fileHandleForReading.readToEnd()) ?? Data())

        try Task.checkCancellation()
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: collector.out,
            standardError: collector.err
        )
    }

    /// Streams stdout as it arrives. For `adb exec-out`, where the output is the
    /// file itself and may be gigabytes.
    ///
    /// The stream finishes when the child exits; a non-zero exit finishes it with
    /// `TransferError.commandFailed` so a half-read file can never look complete.
    public static func stream(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let collector = OutputCollector()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    continuation.yield(data)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    collector.appendErr(data)
                }
            }

            process.terminationHandler = { process in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if let tail = try? outPipe.fileHandleForReading.readToEnd(), !tail.isEmpty {
                    continuation.yield(tail)
                }
                if process.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: TransferError.commandFailed(
                        command: ([process.executableURL?.lastPathComponent ?? "?"] + (process.arguments ?? [])).joined(separator: " "),
                        exitCode: process.terminationStatus,
                        stderr: String(decoding: collector.err, as: UTF8.self)
                    ))
                }
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Pipe callbacks fire on a Foundation-owned queue, so the buffers need a lock.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outBuffer = Data()
    private var errBuffer = Data()

    func appendOut(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); outBuffer.append(data); lock.unlock()
    }

    func appendErr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); errBuffer.append(data); lock.unlock()
    }

    var out: Data { lock.lock(); defer { lock.unlock() }; return outBuffer }
    var err: Data { lock.lock(); defer { lock.unlock() }; return errBuffer }
}
