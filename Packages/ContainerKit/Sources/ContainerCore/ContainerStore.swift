import Observation

public struct ContainerSection: Identifiable, Sendable {
    public let source: ContainerSource
    public let containers: [ContainerInfo]
    public let errorMessage: String?

    public var id: ContainerSource.ID { source.id }
}

@MainActor
@Observable
public final class ContainerStore {
    public private(set) var sections: [ContainerSection] = []
    public private(set) var hasLoaded = false
    public private(set) var pendingActions: Set<ContainerRef> = []
    public private(set) var lastActionError: String?

    private let runtimes: [any ContainerRuntime]
    private let retryDelay: Duration

    @ObservationIgnored private var isWatching = false
    @ObservationIgnored private var watchers: [ContainerSource: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshing: Set<ContainerSource> = []
    @ObservationIgnored private var refreshAgain: Set<ContainerSource> = []

    /// - Parameter retryDelay: The time to wait before the store watches a source
    ///   again after its change stream ends, for example because the engine stopped.
    public init(runtimes: [any ContainerRuntime], retryDelay: Duration = .seconds(10)) {
        self.runtimes = runtimes
        self.retryDelay = retryDelay
    }

    /// Loads all sources and then keeps each source current from its change stream until `stop()`.
    public func start() async {
        isWatching = true
        await refresh()
    }

    public func stop() {
        isWatching = false
        watchers.values.forEach { $0.cancel() }
        watchers = [:]
    }

    /// Stops change streams and the runtimes' background processes synchronously.
    /// The app calls this when it terminates.
    public func shutdown() {
        stop()
        runtimes.forEach { $0.shutdown() }
    }

    public func container(for ref: ContainerRef) -> ContainerInfo? {
        sections.lazy.flatMap(\.containers).first { $0.ref == ref }
    }

    public func logs(for ref: ContainerRef) async -> AsyncThrowingStream<String, any Error> {
        guard let runtime = runtime(for: ref.source) else {
            return AsyncThrowingStream { $0.finish() }
        }
        return await runtime.logs(for: ref)
    }

    public func refresh() async {
        var loadedSections: [ContainerSection] = []
        var loadedSources: [ContainerSource] = []
        for runtime in runtimes {
            let snapshot = await Self.load(runtime)
            loadedSections += snapshot.sections
            loadedSources += snapshot.sources
        }
        sections = loadedSections
        hasLoaded = true
        if isWatching {
            updateWatchers(for: loadedSources)
        }
    }

    public func perform(_ action: ContainerAction, on container: ContainerInfo) async {
        guard let runtime = runtime(for: container.ref.source) else {
            return
        }
        pendingActions.insert(container.ref)
        do {
            try await runtime.perform(action, on: container.ref)
            lastActionError = nil
        } catch {
            lastActionError = "\(container.name): \(error.localizedDescription)"
        }
        pendingActions.remove(container.ref)
        await refreshSection(container.ref.source)
    }

    private func runtime(for source: ContainerSource) -> (any ContainerRuntime)? {
        runtimes.first { $0.id == source.runtimeID }
    }

    private func updateWatchers(for sources: [ContainerSource]) {
        let current = Set(sources)
        for (source, watcher) in watchers where !current.contains(source) {
            watcher.cancel()
            watchers[source] = nil
        }
        for source in sources where watchers[source] == nil {
            guard let runtime = runtime(for: source) else {
                continue
            }
            watchers[source] = Task { [weak self, retryDelay] in
                while !Task.isCancelled {
                    do {
                        for try await _ in await runtime.changes(in: source) {
                            self?.scheduleRefresh(source)
                        }
                    } catch {}
                    try? await Task.sleep(for: retryDelay)
                    self?.scheduleRefresh(source)
                }
            }
        }
    }

    /// Change streams can deliver many events at once, for example when a
    /// Compose project starts. Only one refresh per source runs at a time.
    /// Events that arrive during a refresh cause one more refresh after it.
    private func scheduleRefresh(_ source: ContainerSource) {
        guard refreshing.insert(source).inserted else {
            refreshAgain.insert(source)
            return
        }
        Task {
            repeat {
                refreshAgain.remove(source)
                await refreshSection(source)
            } while refreshAgain.contains(source)
            refreshing.remove(source)
        }
    }

    private func refreshSection(_ source: ContainerSource) async {
        guard let runtime = runtime(for: source) else {
            return
        }
        let section = await Self.section(for: source, in: runtime)
        if let index = sections.firstIndex(where: { $0.id == source.id }) {
            sections[index] = section
        }
    }

    /// Loads all sources of one runtime in parallel, so that a slow or
    /// unreachable source does not delay the others. A failure in one
    /// source becomes an error section and does not affect other sources.
    private nonisolated static func load(_ runtime: any ContainerRuntime) async -> (sources: [ContainerSource], sections: [ContainerSection]) {
        let sources: [ContainerSource]
        do {
            sources = try await runtime.sources()
        } catch {
            let source = ContainerSource(runtimeID: runtime.id, name: runtime.displayName)
            return ([], [ContainerSection(source: source, containers: [], errorMessage: error.localizedDescription)])
        }

        let sections = await withTaskGroup(of: (Int, ContainerSection).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    (index, await section(for: source, in: runtime))
                }
            }
            var results: [(Int, ContainerSection)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return (sources, sections)
    }

    private nonisolated static func section(for source: ContainerSource, in runtime: any ContainerRuntime) async -> ContainerSection {
        do {
            let containers = try await runtime.containers(in: source)
            return ContainerSection(source: source, containers: containers, errorMessage: nil)
        } catch {
            return ContainerSection(source: source, containers: [], errorMessage: error.localizedDescription)
        }
    }
}
