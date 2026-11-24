import ContainerCore
import Foundation
import Synchronization
import Testing

@MainActor
struct ContainerStoreTests {
    @Test func refreshGroupsContainersBySourceInOrder() async {
        let store = ContainerStore(runtimes: [InMemoryRuntime.sample()])

        await store.refresh()

        #expect(store.hasLoaded)
        #expect(store.sections.map(\.source.name) == ["colima", "vmpal"])
        #expect(store.sections[0].containers.map(\.name) == ["web", "db", "worker"])
        #expect(store.sections[1].containers.map(\.name) == ["cache"])
    }

    @Test func performUpdatesStateAfterRefresh() async throws {
        let store = ContainerStore(runtimes: [InMemoryRuntime.sample()])
        await store.refresh()
        let worker = try #require(store.sections[0].containers.first { $0.name == "worker" })

        await store.perform(.start, on: worker)

        let updated = try #require(store.sections[0].containers.first { $0.name == "worker" })
        #expect(updated.state == .running)
        #expect(store.pendingActions.isEmpty)
        #expect(store.lastActionError == nil)
    }

    @Test func changeStreamRefreshesSection() async throws {
        let runtime = InMemoryRuntime.sample()
        let store = ContainerStore(runtimes: [runtime])
        await store.start()
        defer { store.stop() }
        let worker = try #require(store.sections[0].containers.first { $0.name == "worker" })
        #expect(await eventually { await runtime.subscriberCount(for: worker.ref.source) == 1 })

        try await runtime.perform(.start, on: worker.ref)

        #expect(await eventually { store.sections[0].containers.first { $0.name == "worker" }?.state == .running })
    }

    @Test func endedChangeStreamIsWatchedAgainAfterRetryDelay() async {
        let runtime = CountingRuntime()
        let store = ContainerStore(runtimes: [runtime], retryDelay: .milliseconds(20))
        await store.start()
        defer { store.stop() }

        #expect(await eventually { runtime.watchCount >= 3 })
    }

    @Test func logsComeFromTheContainersRuntime() async throws {
        let store = ContainerStore(runtimes: [InMemoryRuntime.sample()])
        await store.refresh()
        let web = try #require(store.sections[0].containers.first { $0.name == "web" })

        var lines: [String] = []
        for try await line in await store.logs(for: web.ref) {
            lines.append(line)
        }

        #expect(lines == ["web log line 1", "web log line 2", "web log line 3"])
        #expect(store.container(for: web.ref) == web)
    }

    @Test func logsAfterALineYieldOnlyLaterLines() async throws {
        let store = ContainerStore(runtimes: [InMemoryRuntime.sample()])
        await store.refresh()
        let web = try #require(store.sections[0].containers.first { $0.name == "web" })

        var lines: [String] = []
        for try await line in await store.logs(for: web.ref, after: "web log line 2") {
            lines.append(line)
        }

        #expect(lines == ["web log line 3"])
    }

    @Test func failingSourceDoesNotAffectOtherSources() async {
        let store = ContainerStore(runtimes: [FailingRuntime(failingSource: "broken")])

        await store.refresh()

        #expect(store.sections.map(\.source.name) == ["ok", "broken"])
        #expect(store.sections[0].errorMessage == nil)
        #expect(store.sections[1].errorMessage == "Engine not reachable.")
    }

    @Test func failingRuntimeBecomesErrorSection() async {
        let store = ContainerStore(runtimes: [FailingRuntime(failingSource: nil)])

        await store.refresh()

        #expect(store.sections.count == 1)
        #expect(store.sections[0].source.name == "Failing")
        #expect(store.sections[0].errorMessage == "Engine not reachable.")
    }
}

struct EngineError: LocalizedError {
    var errorDescription: String? { "Engine not reachable." }
}

/// Fails `sources()` when `failingSource` is nil. Otherwise it returns two
/// sources and fails `containers(in:)` only for the named source.
struct FailingRuntime: ContainerRuntime {
    let failingSource: String?
    let id = "failing"
    let displayName = "Failing"

    func sources() async throws -> [ContainerSource] {
        guard let failingSource else { throw EngineError() }
        return [ContainerSource(runtimeID: id, name: "ok"), ContainerSource(runtimeID: id, name: failingSource)]
    }

    func containers(in source: ContainerSource) async throws -> [ContainerInfo] {
        if source.name == failingSource { throw EngineError() }
        return []
    }

    func perform(_ action: ContainerAction, on ref: ContainerRef) async throws {}

    func perform(_ action: ContainerAction, on group: ContainerGroupRef) async throws {}

    func changes(in source: ContainerSource) async -> AsyncThrowingStream<Void, any Error> {
        AsyncThrowingStream { $0.finish(throwing: EngineError()) }
    }

    func logs(for ref: ContainerRef, after lastLine: String?) async -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish(throwing: EngineError()) }
    }
}

/// Polls `condition` until it is true or `timeout` passes.
func eventually(timeout: Duration = .seconds(2), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Has one source whose change stream ends at once, and counts how often it is watched.
final class CountingRuntime: ContainerRuntime {
    let id = "counting"
    let displayName = "Counting"
    private let count = Mutex(0)

    var watchCount: Int { count.withLock { $0 } }

    func sources() async throws -> [ContainerSource] {
        [ContainerSource(runtimeID: id, name: "only")]
    }

    func containers(in source: ContainerSource) async throws -> [ContainerInfo] { [] }

    func perform(_ action: ContainerAction, on ref: ContainerRef) async throws {}

    func perform(_ action: ContainerAction, on group: ContainerGroupRef) async throws {}

    func changes(in source: ContainerSource) async -> AsyncThrowingStream<Void, any Error> {
        count.withLock { $0 += 1 }
        return AsyncThrowingStream { $0.finish() }
    }

    func logs(for ref: ContainerRef, after lastLine: String?) async -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
