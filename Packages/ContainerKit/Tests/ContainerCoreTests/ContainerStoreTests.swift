import ContainerCore
import Foundation
import Observation
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

    @Test func sectionRefreshWithUnchangedContainersDoesNotNotifyObservers() async throws {
        let store = ContainerStore(runtimes: [InMemoryRuntime.sample()])
        await store.refresh()
        let worker = try #require(store.sections[0].containers.first { $0.name == "worker" })
        await store.perform(.start, on: worker)
        let notified = Mutex(false)
        withObservationTracking {
            _ = store.sections
        } onChange: {
            notified.withLock { $0 = true }
        }

        await store.perform(.start, on: worker)

        #expect(!notified.withLock { $0 })
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

    @Test func olderRefreshDoesNotReplaceNewerResults() async {
        let runtime = ControlledRuntime()
        let store = ContainerStore(runtimes: [runtime])
        let older = Task { await store.refresh() }
        #expect(await eventually { await runtime.pendingCount == 1 })
        let newer = Task { await store.refresh() }
        #expect(await eventually { await runtime.pendingCount == 2 })

        await runtime.answer(at: 1, containerName: "new")
        await newer.value
        await runtime.answer(at: 0, containerName: "old")
        await older.value

        #expect(store.sections.flatMap(\.containers).map(\.name) == ["new"])
    }

    @Test func olderRefreshDoesNotReplaceResultsOfLaterAction() async throws {
        let runtime = ControlledRuntime()
        let store = ContainerStore(runtimes: [runtime])
        let initial = Task { await store.refresh() }
        #expect(await eventually { await runtime.pendingCount == 1 })
        await runtime.answer(at: 0, containerName: "initial")
        await initial.value
        let container = try #require(store.sections.first?.containers.first)

        let refresh = Task { await store.refresh() }
        #expect(await eventually { await runtime.pendingCount == 1 })
        let action = Task { await store.perform(.stop, on: container) }
        #expect(await eventually { await runtime.pendingCount == 2 })
        await runtime.answer(at: 1, containerName: "after action")
        await action.value
        await runtime.answer(at: 0, containerName: "before action")
        await refresh.value

        #expect(store.sections.flatMap(\.containers).map(\.name) == ["after action"])
    }

    @Test func retryDelayGrowsWhileSourceIsUnreachable() async throws {
        let runtime = CountingRuntime(isReachable: false)
        let store = ContainerStore(runtimes: [runtime], retryDelay: .milliseconds(10))

        await store.start()
        try await Task.sleep(for: .milliseconds(400))
        store.stop()

        #expect(runtime.watchCount <= 7)
    }

    @Test(arguments: [(true, Duration.seconds(60)), (false, .milliseconds(10))])
    func retryDelayStaysShortForReachableSourceOrLowMaximum(isReachable: Bool, maxRetryDelay: Duration) async {
        let runtime = CountingRuntime(isReachable: isReachable)
        let store = ContainerStore(runtimes: [runtime], retryDelay: .milliseconds(10), maxRetryDelay: maxRetryDelay)

        await store.start()

        #expect(await eventually { runtime.watchCount >= 12 })
        store.stop()
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

/// Has one source. Each `containers(in:)` call waits until the test answers it.
actor ControlledRuntime: ContainerRuntime {
    nonisolated let id = "controlled"
    nonisolated let displayName = "Controlled"
    private var pending: [CheckedContinuation<[ContainerInfo], Never>] = []

    var pendingCount: Int { pending.count }

    private nonisolated var source: ContainerSource {
        ContainerSource(runtimeID: id, name: "only")
    }

    func answer(at index: Int, containerName: String) {
        let ref = ContainerRef(source: source, containerID: "1")
        let container = ContainerInfo(ref: ref, name: containerName, image: "alpine", state: .running, status: "Up")
        pending.remove(at: index).resume(returning: [container])
    }

    func sources() async throws -> [ContainerSource] { [source] }

    func containers(in source: ContainerSource) async throws -> [ContainerInfo] {
        await withCheckedContinuation { pending.append($0) }
    }

    func perform(_ action: ContainerAction, on ref: ContainerRef) async throws {}

    func perform(_ action: ContainerAction, on group: ContainerGroupRef) async throws {}

    func changes(in source: ContainerSource) async -> AsyncThrowingStream<Void, any Error> {
        AsyncThrowingStream { _ in }
    }

    func logs(for ref: ContainerRef, after lastLine: String?) async -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish() }
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
    private let isReachable: Bool

    init(isReachable: Bool = true) {
        self.isReachable = isReachable
    }


    var watchCount: Int { count.withLock { $0 } }

    func sources() async throws -> [ContainerSource] {
        [ContainerSource(runtimeID: id, name: "only")]
    }

    func containers(in source: ContainerSource) async throws -> [ContainerInfo] {
        guard isReachable else { throw EngineError() }
        return []
    }

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
