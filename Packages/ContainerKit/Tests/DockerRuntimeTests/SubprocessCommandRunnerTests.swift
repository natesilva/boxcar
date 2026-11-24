import DockerRuntime
import Foundation
import Testing

struct SubprocessCommandRunnerTests {
    private let runner = SubprocessCommandRunner()

    @Test func returnsStandardOutput() async throws {
        let output = try await runner.run(URL(filePath: "/bin/echo"), arguments: ["hello"], timeout: .seconds(5))

        #expect(output == "hello\n")
    }

    @Test func failureUsesFirstLineOfStandardError() async {
        await #expect(throws: CommandError.failed(message: "first")) {
            try await runner.run(URL(filePath: "/bin/sh"), arguments: ["-c", "echo first >&2; echo second >&2; exit 1"], timeout: .seconds(5))
        }
    }

    @Test func slowCommandTimesOut() async {
        await #expect(throws: CommandError.timedOut) {
            try await runner.run(URL(filePath: "/bin/sleep"), arguments: ["10"], timeout: .milliseconds(200))
        }
    }

    @Test func linesStreamsStandardOutput() async throws {
        var lines: [String] = []
        for try await line in runner.lines(URL(filePath: "/bin/sh"), arguments: ["-c", "echo one; echo two"]) {
            lines.append(line)
        }

        #expect(lines == ["one", "two"])
    }

    @Test func linesThrowsWhenCommandFails() async {
        await #expect(throws: CommandError.failed(message: "broken")) {
            for try await _ in runner.lines(URL(filePath: "/bin/sh"), arguments: ["-c", "echo broken >&2; exit 2"]) {}
        }
    }

    @Test func linesCanIncludeStandardError() async throws {
        var lines: [String] = []
        for try await line in runner.lines(URL(filePath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2"], includeStandardError: true) {
            lines.append(line)
        }

        #expect(Set(lines) == ["out", "err"])
    }

    @Test func terminateRunningProcessesEndsStreamingProcess() async throws {
        let stream = runner.lines(URL(filePath: "/bin/sh"), arguments: ["-c", "echo ready; sleep 30"])
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == "ready")

        let start = ContinuousClock.now
        runner.terminateRunningProcesses()
        await #expect(throws: CommandError.self) {
            _ = try await iterator.next()
        }

        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
