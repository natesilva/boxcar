import ContainerCore
import Foundation

public enum DockerError: LocalizedError, Equatable {
    case cliNotFound
    case engineNotRunning

    public var errorDescription: String? {
        switch self {
        case .cliNotFound: String(localized: "The docker CLI was not found.", bundle: #bundle, comment: "Error shown when the app cannot find the docker executable.")
        case .engineNotRunning: String(localized: "Not running", bundle: #bundle, comment: "Error shown under a Docker context whose engine does not accept connections, for example because its app was quit.")
        }
    }

    private static let unreachableMarkers = ["failed to connect to the docker api", "cannot connect to the docker daemon"]

    /// The docker CLI reports an unreachable engine with a long message that contains the socket path.
    static func isEngineUnreachable(_ error: any Error) -> Bool {
        guard case CommandError.failed(let message) = error else {
            return false
        }
        let lowercased = message.lowercased()
        return unreachableMarkers.contains { lowercased.contains($0) }
    }
}

/// Lists and controls containers in every Docker context through the `docker` CLI.
public struct DockerCLIRuntime: ContainerRuntime {
    public let id = "docker"
    public let displayName = "Docker"

    private let locator: DockerCLILocator
    private let runner: any CommandRunner
    private let now: @Sendable () -> Date
    /// Reports whether anything exists at a path. The default reads the attributes of a symlink
    /// itself, so a symlink with a missing target counts as existing.
    private let entryExists: @Sendable (String) -> Bool

    private static let listTimeout: Duration = .seconds(15)
    /// `docker stop` waits up to 10 seconds before it kills the container, so actions need a longer timeout.
    private static let actionTimeout: Duration = .seconds(60)
    /// Compose stops a project's containers in dependency order, so a project takes longer than one container.
    private static let groupActionTimeout: Duration = .seconds(180)

    public init(
        locator: DockerCLILocator = DockerCLILocator(),
        runner: any CommandRunner = SubprocessCommandRunner(),
        now: @escaping @Sendable () -> Date = { Date() },
        entryExists: @escaping @Sendable (String) -> Bool = { (try? FileManager.default.attributesOfItem(atPath: $0)) != nil }
    ) {
        self.locator = locator
        self.runner = runner
        self.now = now
        self.entryExists = entryExists
    }

    public func sources() async throws -> [ContainerSource] {
        let output = try await docker(["context", "ls", "--format", "json"], timeout: Self.listTimeout)
        let contexts = try DockerOutput.contexts(from: output)
        let uniqueContexts = DockerOutput.uniqueContexts(contexts, resolveSymlinks: DockerOutput.resolveSymlinks)
        return DockerOutput.removingUnusedDefaultContext(uniqueContexts, entryExists: entryExists)
            .map { ContainerSource(runtimeID: id, name: $0.name) }
    }

    public func containers(in source: ContainerSource) async throws -> [ContainerInfo] {
        let output: String
        do {
            output = try await docker(
                ["--context", source.name, "ps", "--all", "--no-trunc", "--format", "json"],
                timeout: Self.listTimeout
            )
        } catch where DockerError.isEngineUnreachable(error) {
            throw DockerError.engineNotRunning
        }
        let containers = try DockerOutput.containers(from: output)
        let diagnostics = await diagnostics(of: containers.map(\.id), in: source)
        return containers.map { $0.containerInfo(in: source, diagnostics: diagnostics[$0.id] ?? ContainerDiagnostics()) }
    }

    /// `docker inspect` fails if a container was removed after `docker ps` listed it.
    /// The removal also causes a change event, and the next refresh gets the diagnostics.
    /// Until then, the containers are shown without diagnostics.
    private func diagnostics(of containerIDs: [String], in source: ContainerSource) async -> [String: ContainerDiagnostics] {
        guard !containerIDs.isEmpty else {
            return [:]
        }
        do {
            let output = try await docker(
                ["--context", source.name, "inspect", "--type", "container"] + containerIDs,
                timeout: Self.listTimeout
            )
            return try DockerOutput.diagnostics(from: output)
        } catch {
            return [:]
        }
    }

    public func perform(_ action: ContainerAction, on ref: ContainerRef) async throws {
        _ = try await docker(
            ["--context", ref.source.name, action.dockerCommand, ref.containerID],
            timeout: Self.actionTimeout
        )
    }

    /// Compose finds a project's containers by their labels, so the compose file is not needed.
    /// Compose also starts and stops the services in the order of their `depends_on` settings.
    public func perform(_ action: ContainerAction, on group: ContainerGroupRef) async throws {
        _ = try await docker(
            ["--context", group.source.name, "compose", "--project-name", group.name, action.dockerCommand],
            timeout: Self.groupActionTimeout
        )
    }

    /// Health checks create frequent `exec_*` events, so the runtime does not ask for them.
    /// Docker sends a `health_status` event only when the health status changes.
    static let watchedEvents = ["create", "destroy", "start", "stop", "die", "restart", "pause", "unpause", "rename", "health_status"]

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

    /// `docker logs --since` includes lines with exactly the given timestamp, so the
    /// stream drops its first line if that line is the last line of the earlier stream.
    /// The timestamp is the first word of the line, because the runtime asks for `--timestamps`.
    /// The runtime does not compare the timestamp with the clock of the Mac, because the
    /// clock of a container VM can differ from it.
    public func logs(for ref: ContainerRef, after lastLine: String?) async -> AsyncThrowingStream<String, any Error> {
        guard let executable = locator.locate() else {
            return AsyncThrowingStream { $0.finish(throwing: DockerError.cliNotFound) }
        }
        let since = lastLine?.split(separator: " ", maxSplits: 1).first.map(String.init)
        let sinceArguments = since.map { ["--since", $0] } ?? []
        // `docker logs` writes the container's standard error to its own standard error.
        let lines = runner.lines(
            executable,
            arguments: ["--context", ref.source.name, "logs", "--follow", "--timestamps"] + sinceArguments + ["--tail", String(Self.logTailLines), ref.containerID],
            includeStandardError: true
        )
        guard let lastLine else {
            return lines
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var isFirstLine = true
                    for try await line in lines {
                        defer { isFirstLine = false }
                        if isFirstLine && line == lastLine {
                            continue
                        }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
