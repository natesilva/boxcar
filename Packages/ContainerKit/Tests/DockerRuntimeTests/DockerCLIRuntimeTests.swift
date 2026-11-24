import ContainerCore
import DockerRuntime
import Foundation
import Synchronization
import Testing

struct DockerCLIRuntimeTests {
    private let docker = URL(filePath: "/test/bin/docker")

    private func makeRuntime(runner: RecordingRunner, cliInstalled: Bool = true) -> DockerCLIRuntime {
        let locator = DockerCLILocator(searchDirectories: [URL(filePath: "/test/bin")], isExecutable: { _ in cliInstalled })
        return DockerCLIRuntime(locator: locator, runner: runner, now: { Date(timeIntervalSince1970: 1000) })
    }

    @Test func sourcesListsContexts() async throws {
        let runner = RecordingRunner(output: #"{"Name":"colima"}"# + "\n" + #"{"Name":"vmpal"}"#)

        let sources = try await makeRuntime(runner: runner).sources()

        #expect(sources == [ContainerSource(runtimeID: "docker", name: "colima"), ContainerSource(runtimeID: "docker", name: "vmpal")])
        #expect(runner.calls == [RecordingRunner.Call(executable: docker, arguments: ["context", "ls", "--format", "json"])])
    }

    @Test func containersUseContextFlag() async throws {
        let runner = RecordingRunner(output: "")
        let source = ContainerSource(runtimeID: "docker", name: "vmpal")

        _ = try await makeRuntime(runner: runner).containers(in: source)

        #expect(runner.calls.map(\.arguments) == [["--context", "vmpal", "ps", "--all", "--no-trunc", "--format", "json"]])
    }

    @Test(arguments: [(ContainerAction.start, "start"), (.stop, "stop"), (.restart, "restart")])
    func performRunsMatchingCommand(action: ContainerAction, command: String) async throws {
        let runner = RecordingRunner(output: "")
        let ref = ContainerRef(source: ContainerSource(runtimeID: "docker", name: "colima"), containerID: "abc")

        try await makeRuntime(runner: runner).perform(action, on: ref)

        #expect(runner.calls.map(\.arguments) == [["--context", "colima", command, "abc"]])
    }

    @Test func changesWatchStateEventsOnly() async throws {
        let runner = RecordingRunner(output: "start")
        let source = ContainerSource(runtimeID: "docker", name: "colima")

        for try await _ in await makeRuntime(runner: runner).changes(in: source) {
            break
        }

        let arguments = try #require(runner.calls.first?.arguments)
        #expect(Array(arguments.prefix(5)) == ["--context", "colima", "events", "--format", "{{.Action}}"])
        #expect(arguments.contains("type=container"))
        #expect(arguments.contains("event=die"))
        #expect(!arguments.contains("event=health_status"))
    }

    @Test func changesRunInContiguousWindows() async throws {
        let runner = RecordingRunner(output: "start")
        let source = ContainerSource(runtimeID: "docker", name: "colima")

        var count = 0
        for try await _ in await makeRuntime(runner: runner).changes(in: source) {
            count += 1
            if count == 2 { break }
        }

        let windows = runner.calls.prefix(2).map { Array($0.arguments.suffix(4)) }
        #expect(windows == [
            ["--since", "1000", "--until", "1060"],
            ["--since", "1060", "--until", "1120"],
        ])
    }

    @Test func logsFollowTailWithTimestamps() async throws {
        let runner = RecordingRunner(output: "line")
        let ref = ContainerRef(source: ContainerSource(runtimeID: "docker", name: "vmpal"), containerID: "abc")

        for try await _ in await makeRuntime(runner: runner).logs(for: ref) {}

        #expect(runner.calls.map(\.arguments) == [["--context", "vmpal", "logs", "--follow", "--timestamps", "--tail", "500", "abc"]])
    }

    @Test func missingCLIThrowsWithoutRunning() async {
        let runner = RecordingRunner(output: "")

        await #expect(throws: DockerError.cliNotFound) {
            try await makeRuntime(runner: runner, cliInstalled: false).sources()
        }
        #expect(runner.calls.isEmpty)
    }
}

final class RecordingRunner: CommandRunner {
    struct Call: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private let output: String
    private let recorded = Mutex<[Call]>([])

    init(output: String) {
        self.output = output
    }

    var calls: [Call] {
        recorded.withLock { $0 }
    }

    func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> String {
        recorded.withLock { $0.append(Call(executable: executable, arguments: arguments)) }
        return output
    }

    func terminateRunningProcesses() {}

    func lines(_ executable: URL, arguments: [String], includeStandardError: Bool) -> AsyncThrowingStream<String, any Error> {
        recorded.withLock { $0.append(Call(executable: executable, arguments: arguments)) }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        return AsyncThrowingStream { continuation in
            lines.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}
