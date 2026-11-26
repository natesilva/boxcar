import ContainerCore
import DockerRuntime
import Foundation
import Synchronization
import Testing

struct DockerCLIRuntimeTests {
    private let docker = URL(filePath: "/test/bin/docker")

    private func makeRuntime(runner: RecordingRunner, cliInstalled: Bool = true, now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1000) }, entryExists: @escaping @Sendable (String) -> Bool = { _ in true }) -> DockerCLIRuntime {
        let locator = DockerCLILocator(searchDirectories: [URL(filePath: "/test/bin")], isExecutable: { _ in cliInstalled })
        return DockerCLIRuntime(locator: locator, runner: runner, now: now, entryExists: entryExists)
    }

    @Test func sourcesListsContexts() async throws {
        let runner = RecordingRunner(output: #"{"Name":"colima"}"# + "\n" + #"{"Name":"vmpal"}"#)

        let sources = try await makeRuntime(runner: runner).sources()

        #expect(sources == [ContainerSource(runtimeID: "docker", name: "colima"), ContainerSource(runtimeID: "docker", name: "vmpal")])
        #expect(runner.calls == [RecordingRunner.Call(executable: docker, arguments: ["context", "ls", "--format", "json"])])
    }

    @Test func sourcesRejectsACLIWithAnotherOutputFormat() async {
        let podmanOutput = """
            [
                {
                    "Name": "podman-machine-default",
                    "URI": "ssh://core@127.0.0.1:49767/run/user/501/podman/podman.sock"
                }
            ]
            """

        await #expect(throws: DockerError.unsupportedCLI) {
            try await makeRuntime(runner: RecordingRunner(output: podmanOutput)).sources()
        }
    }

    @Test func sourcesOmitsDefaultContextWhenItsSocketPathIsEmpty() async throws {
        let runner = RecordingRunner(output: #"{"Name":"default","DockerEndpoint":"unix:///var/run/docker.sock"}"# + "\n" + #"{"Name":"vmpal","DockerEndpoint":"unix:///Users/test/.vmpal/docker.sock"}"#)

        let sources = try await makeRuntime(runner: runner, entryExists: { $0 != "/var/run/docker.sock" }).sources()

        #expect(sources == [ContainerSource(runtimeID: "docker", name: "vmpal")])
    }

    @Test func defaultEntryCheckKeepsDefaultContextWithDanglingSymlinkButNotWithMissingPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dangling = directory.appending(path: "docker.sock")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing.sock")
        let absent = directory.appending(path: "absent.sock")
        let output = #"{"Name":"default","DockerEndpoint":"unix://\#(dangling.path)"}"# + "\n" + #"{"Name":"other","DockerEndpoint":"unix://\#(absent.path)"}"#
        let locator = DockerCLILocator(searchDirectories: [URL(filePath: "/test/bin")], isExecutable: { _ in true })

        let sources = try await DockerCLIRuntime(locator: locator, runner: RecordingRunner(output: output)).sources()

        #expect(sources.map(\.name) == ["default", "other"])

        let absentOutput = #"{"Name":"default","DockerEndpoint":"unix://\#(absent.path)"}"#
        let withoutDefault = try await DockerCLIRuntime(locator: locator, runner: RecordingRunner(output: absentOutput)).sources()

        #expect(withoutDefault.isEmpty)
    }

    @Test func containersUseContextFlag() async throws {
        let runner = RecordingRunner(output: "")
        let source = ContainerSource(runtimeID: "docker", name: "vmpal")

        _ = try await makeRuntime(runner: runner).containers(in: source)

        #expect(runner.calls.map(\.arguments) == [["--context", "vmpal", "ps", "--all", "--no-trunc", "--format", "json"]])
    }

    @Test func containersIncludeInspectDiagnostics() async throws {
        let runner = RecordingRunner { arguments in
            if arguments.contains("ps") {
                return #"{"ID":"abc","Image":"alpine","Names":"app","State":"exited","Status":"Exited (137)"}"#
            }
            return #"[{"Id":"abc","State":{"ExitCode":137,"OOMKilled":true}}]"#
        }
        let source = ContainerSource(runtimeID: "docker", name: "vmpal")

        let containers = try await makeRuntime(runner: runner).containers(in: source)

        #expect(runner.calls.last?.arguments == ["--context", "vmpal", "inspect", "--type", "container", "abc"])
        #expect(containers.map(\.diagnostics) == [ContainerDiagnostics(exitCode: 137, outOfMemory: true)])
    }

    @Test func containersWithoutInspectDiagnosticsWhenInspectFails() async throws {
        let runner = RecordingRunner { arguments in
            arguments.contains("ps") ? #"{"ID":"abc","Image":"alpine","Names":"app","State":"running","Status":"Up"}"# : "not json"
        }
        let source = ContainerSource(runtimeID: "docker", name: "vmpal")

        let containers = try await makeRuntime(runner: runner).containers(in: source)

        #expect(containers.map(\.diagnostics) == [ContainerDiagnostics()])
    }

    @Test(arguments: [(ContainerAction.start, "start"), (.stop, "stop"), (.restart, "restart")])
    func performRunsMatchingCommand(action: ContainerAction, command: String) async throws {
        let runner = RecordingRunner(output: "")
        let ref = ContainerRef(source: ContainerSource(runtimeID: "docker", name: "colima"), containerID: "abc")

        try await makeRuntime(runner: runner).perform(action, on: ref)

        #expect(runner.calls.map(\.arguments) == [["--context", "colima", command, "abc"]])
    }

    @Test(arguments: [(ContainerAction.start, "start"), (.stop, "stop"), (.restart, "restart")])
    func groupActionRunsComposeByProjectName(action: ContainerAction, command: String) async throws {
        let runner = RecordingRunner(output: "")
        let group = ContainerGroupRef(source: ContainerSource(runtimeID: "docker", name: "vmpal"), name: "litellm")

        try await makeRuntime(runner: runner).perform(action, on: group)

        #expect(runner.calls.map(\.arguments) == [["--context", "vmpal", "compose", "--progress", "quiet", "--project-name", "litellm", command]])
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
        #expect(arguments.contains("event=health_status"))
        #expect(!arguments.contains { $0.hasPrefix("event=exec") })
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

    @Test func changesSkipWindowsThatArePast() async throws {
        let runner = RecordingRunner(output: "start")
        let source = ContainerSource(runtimeID: "docker", name: "colima")
        let times = Mutex([1000, 1000])
        let runtime = makeRuntime(runner: runner, now: {
            let time = times.withLock { $0.isEmpty ? 5000 : $0.removeFirst() }
            return Date(timeIntervalSince1970: TimeInterval(time))
        })
        let start = ContinuousClock.now

        var count = 0
        for try await _ in await runtime.changes(in: source) {
            count += 1
            if count == 3 { break }
        }

        let windows = runner.calls.prefix(2).map { Array($0.arguments.suffix(4)) }
        #expect(windows == [
            ["--since", "1000", "--until", "1060"],
            ["--since", "5000", "--until", "5060"],
        ])
        #expect(ContinuousClock.now - start >= .seconds(1))
    }

    @Test func logsReportTheCLIMessageInsteadOfYieldingIt() async {
        let logLine = "2026-11-24T12:00:00.000000000+01:00 started"
        let runner = RecordingRunner(output: "\(logLine)\nError response from daemon: gone", linesFailure: .failed(message: "status 1"))
        let ref = ContainerRef(source: ContainerSource(runtimeID: "docker", name: "vmpal"), containerID: "abc")

        var lines: [String] = []
        await #expect(throws: CommandError.failed(message: "Error response from daemon: gone")) {
            for try await line in await makeRuntime(runner: runner).logs(for: ref) {
                lines.append(line)
            }
        }

        #expect(lines == [logLine])
    }

    @Test(arguments: [
        ("Error response from daemon: gone\n  ", "Error response from daemon: gone"),
        ("WARNING: old\n2026-11-24T12:00:00.000000000Z later line", "status 1"),
    ])
    func logsErrorSkipsBlankAndEarlierCLIMessages(output: String, message: String) async {
        let runner = RecordingRunner(output: output, linesFailure: .failed(message: "status 1"))
        let ref = ContainerRef(source: ContainerSource(runtimeID: "docker", name: "vmpal"), containerID: "abc")

        await #expect(throws: CommandError.failed(message: message)) {
            for try await _ in await makeRuntime(runner: runner).logs(for: ref) {}
        }
    }

    @Test func logsFollowTailWithTimestamps() async throws {
        let runner = RecordingRunner(output: "line")
        let ref = ContainerRef(source: ContainerSource(runtimeID: "docker", name: "vmpal"), containerID: "abc")

        for try await _ in await makeRuntime(runner: runner).logs(for: ref) {}

        #expect(runner.calls.map(\.arguments) == [["--context", "vmpal", "logs", "--follow", "--timestamps", "--tail", "500", "abc"]])
    }

    @Test func logsAfterALineStartAtItsTimestampAndDropItsRepeat() async throws {
        let last = "2026-11-24T12:00:00.123456789Z last line"
        let runner = RecordingRunner(output: "\(last)\n2026-11-24T12:00:05.000000000Z new line")
        let ref = ContainerRef(source: ContainerSource(runtimeID: "docker", name: "vmpal"), containerID: "abc")

        var lines: [String] = []
        for try await line in await makeRuntime(runner: runner).logs(for: ref, after: last) {
            lines.append(line)
        }

        #expect(runner.calls.map(\.arguments) == [["--context", "vmpal", "logs", "--follow", "--timestamps", "--since", "2026-11-24T12:00:00.123456789Z", "--tail", "500", "abc"]])
        #expect(lines == ["2026-11-24T12:00:05.000000000Z new line"])
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

    private let respond: @Sendable ([String]) -> String
    private let linesFailure: CommandError?
    private let recorded = Mutex<[Call]>([])

    init(output: String, linesFailure: CommandError? = nil) {
        self.respond = { _ in output }
        self.linesFailure = linesFailure
    }

    init(respond: @escaping @Sendable ([String]) -> String) {
        self.respond = respond
        self.linesFailure = nil
    }

    var calls: [Call] {
        recorded.withLock { $0 }
    }

    func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> String {
        recorded.withLock { $0.append(Call(executable: executable, arguments: arguments)) }
        return respond(arguments)
    }

    func terminateRunningProcesses() {}

    func lines(_ executable: URL, arguments: [String], includeStandardError: Bool) -> AsyncThrowingStream<String, any Error> {
        recorded.withLock { $0.append(Call(executable: executable, arguments: arguments)) }
        let lines = respond(arguments).split(whereSeparator: \.isNewline).map(String.init)
        return AsyncThrowingStream { continuation in
            lines.forEach { continuation.yield($0) }
            continuation.finish(throwing: linesFailure)
        }
    }
}
