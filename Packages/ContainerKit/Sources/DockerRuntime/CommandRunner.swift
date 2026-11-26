import Foundation
import Subprocess
import Synchronization
import System

public protocol CommandRunner: Sendable {
    /// Runs the executable and returns its standard output.
    /// Throws `CommandError` if the command fails or does not finish within `timeout`.
    func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> String

    /// Runs the executable and yields each line of its output.
    /// Only a line feed ends a line. A carriage return before the line feed is removed.
    /// Cancelling the iteration terminates the process.
    /// - Parameter includeStandardError: Merges standard error into the yielded lines.
    func lines(_ executable: URL, arguments: [String], includeStandardError: Bool) -> AsyncThrowingStream<String, any Error>

    /// Sends `SIGTERM` to every process that `lines` started and that is still running.
    /// This call is synchronous, so the app can call it while it terminates.
    func terminateRunningProcesses()
}

extension CommandRunner {
    public func lines(_ executable: URL, arguments: [String]) -> AsyncThrowingStream<String, any Error> {
        lines(executable, arguments: arguments, includeStandardError: false)
    }
}

public enum CommandError: LocalizedError, Equatable {
    case failed(message: String)
    case timedOut
    case lineTooLong

    public var errorDescription: String? {
        switch self {
        case .failed(let message): message
        case .timedOut: String(localized: "The command did not respond in time.", bundle: #bundle, comment: "Error shown when a docker command takes too long.")
        case .lineTooLong: String(localized: "A line of output is too long to read.", bundle: #bundle, comment: "Error shown when the app stops reading the output of a docker command, such as a container log, because one line is too long.")
        }
    }
}

public struct SubprocessCommandRunner: CommandRunner {
    private static let maxOutputBytes = 16 * 1024 * 1024
    private static let maxErrorBytes = 1024 * 1024

    private let maxLineBytes: Int
    private let runningProcesses = RunningProcesses()

    /// - Parameter maxLineBytes: `lines` fails if one line of output reaches this length.
    ///   The limit keeps output without line feeds from using unlimited memory.
    public init(maxLineBytes: Int = 16 * 1024 * 1024) {
        self.maxLineBytes = maxLineBytes
    }

    public func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Self.execute(executable, arguments: arguments)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CommandError.timedOut
            }
            // Cancelling the group also terminates the subprocess if it is still running.
            defer { group.cancelAll() }
            guard let output = try await group.next() else {
                throw CancellationError()
            }
            return output
        }
    }

    public func lines(_ executable: URL, arguments: [String], includeStandardError: Bool) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { [runningProcesses, maxLineBytes] continuation in
            let task = Task {
                do {
                    let configuration = Configuration(executable: .path(FilePath(executable.path)), arguments: Arguments(arguments))
                    let forward: @Sendable (pid_t, SubprocessOutputSequence) async throws -> Void = { pid, output in
                        try await runningProcesses.track(pid) {
                            let lines = output.strings(separatedBy: .unicodeScalarSequence(["\n"]), bufferingPolicy: .maxLineLength(maxLineBytes))
                            for try await line in lines {
                                continuation.yield(line.hasSuffix("\r") ? String(line.dropLast()) : line)
                            }
                        }
                    }
                    let failure: CommandError?
                    if includeStandardError {
                        let result = try await Subprocess.run(configuration, input: .none, output: .sequence, error: .combinedWithOutput) { execution in
                            try await forward(execution.processIdentifier.value, execution.standardOutput)
                        }
                        failure = result.terminationStatus.isSuccess ? nil : Self.failure(result.terminationStatus, standardError: "")
                    } else {
                        let result = try await Subprocess.run(configuration, input: .none, output: .sequence, error: .string(limit: Self.maxErrorBytes)) { execution in
                            try await forward(execution.processIdentifier.value, execution.standardOutput)
                        }
                        failure = result.terminationStatus.isSuccess ? nil : Self.failure(result.terminationStatus, standardError: result.standardError)
                    }
                    continuation.finish(throwing: failure)
                } catch let error as SubprocessError where error.code == .outputLimitExceeded {
                    continuation.finish(throwing: CommandError.lineTooLong)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func terminateRunningProcesses() {
        runningProcesses.terminateAll()
    }

    private static func execute(_ executable: URL, arguments: [String]) async throws -> String {
        let result = try await Subprocess.run(
            .path(FilePath(executable.path)),
            arguments: Arguments(arguments),
            output: .string(limit: maxOutputBytes),
            error: .string(limit: maxErrorBytes)
        )
        guard result.terminationStatus.isSuccess else {
            throw failure(result.terminationStatus, standardError: result.standardError)
        }
        return result.standardOutput
    }

    private static func failure(_ status: TerminationStatus, standardError: String) -> CommandError {
        let firstLine = standardError.split(whereSeparator: \.isNewline).first.map(String.init)
        let statusDescription = String(describing: status)
        return .failed(message: firstLine ?? String(localized: "The command failed with status \(statusDescription).", bundle: #bundle, comment: "Error shown when a docker command fails without an error message. The value is the exit status."))
    }
}

/// Records the IDs of long-running child processes, so that they can be
/// terminated synchronously when the app quits. Cancellation cannot do this,
/// because the app exits before asynchronous cleanup runs.
final class RunningProcesses: Sendable {
    private let identifiers = Mutex<Set<pid_t>>([])

    func track<T>(_ pid: pid_t, while body: () async throws -> T) async rethrows -> T {
        identifiers.withLock { _ = $0.insert(pid) }
        defer { identifiers.withLock { _ = $0.remove(pid) } }
        return try await body()
    }

    func terminateAll() {
        identifiers.withLock { pids in
            pids.forEach { kill($0, SIGTERM) }
            pids.removeAll()
        }
    }
}
