import ContainerCore
import Foundation

public enum DockerError: LocalizedError, Equatable {
    case cliNotFound

    public var errorDescription: String? {
        switch self {
        case .cliNotFound: String(localized: "The docker CLI was not found.", bundle: #bundle, comment: "Error shown when the app cannot find the docker executable.")
        }
    }
}

/// Lists and controls containers in every Docker context through the `docker` CLI.
public struct DockerCLIRuntime: ContainerRuntime {
    public let id = "docker"
    public let displayName = "Docker"

    private let locator: DockerCLILocator
    private let runner: any CommandRunner
    private let now: @Sendable () -> Date

    private static let listTimeout: Duration = .seconds(15)
    /// `docker stop` waits up to 10 seconds before it kills the container, so actions need a longer timeout.
    private static let actionTimeout: Duration = .seconds(60)

    public init(
        locator: DockerCLILocator = DockerCLILocator(),
        runner: any CommandRunner = SubprocessCommandRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locator = locator
        self.runner = runner
        self.now = now
    }

    public func sources() async throws -> [ContainerSource] {
        let output = try await docker(["context", "ls", "--format", "json"], timeout: Self.listTimeout)
        return try DockerOutput.contexts(from: output).map { ContainerSource(runtimeID: id, name: $0.name) }
    }

    public func containers(in source: ContainerSource) async throws -> [ContainerInfo] {
        let output = try await docker(
            ["--context", source.name, "ps", "--all", "--no-trunc", "--format", "json"],
            timeout: Self.listTimeout
        )
        return try DockerOutput.containers(from: output).map { $0.containerInfo(in: source) }
    }

    public func perform(_ action: ContainerAction, on ref: ContainerRef) async throws {
        _ = try await docker(
            ["--context", ref.source.name, action.dockerCommand, ref.containerID],
            timeout: Self.actionTimeout
        )
    }

    /// Health checks create frequent `exec_*` and `health_status` events.
    /// The runtime asks only for events that change the container list or a container's state.
    static let watchedEvents = ["create", "destroy", "start", "stop", "die", "restart", "pause", "unpause", "rename"]

    /// `docker events` runs in back-to-back windows of this length. Each process
    /// exits by itself at the end of its window, so no process stays behind
    /// for long after the app quits or crashes. Each window starts where the
    /// previous one ended, so no events are lost between windows.
    static let eventWindowSeconds = 60

    public func changes(in source: ContainerSource) async -> AsyncThrowingStream<Void, any Error> {
        guard let executable = locator.locate() else {
            return AsyncThrowingStream { $0.finish(throwing: DockerError.cliNotFound) }
        }
        let filters = ["type=container"] + Self.watchedEvents.map { "event=\($0)" }
        let baseArguments = ["--context", source.name, "events", "--format", "{{.Action}}"]
            + filters.flatMap { ["--filter", $0] }

        return AsyncThrowingStream { [runner, now] continuation in
            let task = Task {
                var since = Int(now().timeIntervalSince1970)
                do {
                    while !Task.isCancelled {
                        let until = since + Self.eventWindowSeconds
                        let arguments = baseArguments + ["--since", String(since), "--until", String(until)]
                        for try await _ in runner.lines(executable, arguments: arguments) {
                            continuation.yield()
                        }
                        since = until
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let logTailLines = 500

    public func logs(for ref: ContainerRef) async -> AsyncThrowingStream<String, any Error> {
        guard let executable = locator.locate() else {
            return AsyncThrowingStream { $0.finish(throwing: DockerError.cliNotFound) }
        }
        // `docker logs` writes the container's standard error to its own standard error.
        return runner.lines(
            executable,
            arguments: ["--context", ref.source.name, "logs", "--follow", "--timestamps", "--tail", String(Self.logTailLines), ref.containerID],
            includeStandardError: true
        )
    }

    public func shutdown() {
        runner.terminateRunningProcesses()
    }

    private func docker(_ arguments: [String], timeout: Duration) async throws -> String {
        guard let executable = locator.locate() else {
            throw DockerError.cliNotFound
        }
        return try await runner.run(executable, arguments: arguments, timeout: timeout)
    }
}

extension ContainerAction {
    var dockerCommand: String {
        switch self {
        case .start: "start"
        case .stop: "stop"
        case .restart: "restart"
        }
    }
}
