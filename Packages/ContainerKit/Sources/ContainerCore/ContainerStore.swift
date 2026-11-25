import Foundation
import Observation

public struct ContainerSection: Identifiable, Equatable, Sendable {
    public let source: ContainerSource
    public let containers: [ContainerInfo]
    public let errorMessage: String?

    public var id: ContainerSource.ID { source.id }

    /// The section's containers, with the members of each group collected into one item.
    /// Each group takes the position of its first member, so the runtime's order is kept.
    public var items: [ContainerSectionItem] {
        var items: [ContainerSectionItem] = []
        var groupIndex: [ContainerGroupRef: Int] = [:]
        for container in containers {
            guard let groupRef = container.groupRef else {
                items.append(.container(container))
                continue
            }
            if let index = groupIndex[groupRef], case .group(let group) = items[index] {
                items[index] = .group(ContainerGroup(ref: groupRef, containers: group.containers + [container]))
            } else {
                groupIndex[groupRef] = items.count
                items.append(.group(ContainerGroup(ref: groupRef, containers: [container])))
            }
        }
        return items
    }
}

public struct ContainerGroup: Identifiable, Equatable, Sendable {
    public let ref: ContainerGroupRef
    public let containers: [ContainerInfo]

    public var id: ContainerGroupRef { ref }

    /// The directory that holds the group's definition, if the runtime reports it.
    public var workingDirectory: URL? {
        containers.lazy.compactMap { $0.group?.workingDirectory }.first.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// The number of member containers in each condition. Conditions without members have no entry.
    public var conditionCounts: [ContainerCondition: Int] {
        containers.reduce(into: [:]) { counts, container in
            counts[container.condition, default: 0] += 1
        }
    }

    public func allows(_ action: ContainerAction) -> Bool {
        containers.contains { $0.state.allows(action) }
    }
}

public enum ContainerSectionItem: Identifiable, Equatable, Sendable {
    case container(ContainerInfo)
    case group(ContainerGroup)

    public enum ID: Hashable {
        case container(ContainerRef)
        case group(ContainerGroupRef)
    }

    public var id: ID {
        switch self {
        case .container(let container): .container(container.ref)
        case .group(let group): .group(group.ref)
        }
    }
}

@MainActor
@Observable
public final class ContainerStore {
    public private(set) var sections: [ContainerSection] = []
    public private(set) var hasLoaded = false
    public private(set) var pendingActions: Set<ContainerRef> = []
    public private(set) var pendingGroupActions: Set<ContainerGroupRef> = []
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

    public func logs(for ref: ContainerRef, after lastLine: String? = nil) async -> AsyncThrowingStream<String, any Error> {
        guard let runtime = runtime(for: ref.source) else {
            return AsyncThrowingStream { $0.finish() }
        }
        return await runtime.logs(for: ref, after: lastLine)
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

    public func perform(_ action: ContainerAction, on group: ContainerGroup) async {
        guard let runtime = runtime(for: group.ref.source) else {
            return
        }
        pendingGroupActions.insert(group.ref)
        do {
            try await runtime.perform(action, on: group.ref)
            lastActionError = nil
        } catch {
            lastActionError = "\(group.ref.name): \(error.localizedDescription)"
        }
        pendingGroupActions.remove(group.ref)
        await refreshSection(group.ref.source)
    }

    /// A container action is not available while its own action or an action on its group runs.
    public func isBusy(_ container: ContainerInfo) -> Bool {
        pendingActions.contains(container.ref) || container.groupRef.map(pendingGroupActions.contains) == true
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
        // Writing an element of `sections` always notifies observers, so an unchanged
        // section must not be written. A needless notification rebuilds the open menu
        // and closes its submenus.
        if let index = sections.firstIndex(where: { $0.id == source.id }), sections[index] != section {
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
