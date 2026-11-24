import Foundation

/// A runtime that keeps containers in memory. It is used for previews and tests.
public actor InMemoryRuntime: ContainerRuntime {
    public enum Failure: LocalizedError {
        case containerNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .containerNotFound(let id): "Container \(id) not found."
            }
        }
    }

    public nonisolated let id: String
    public nonisolated let displayName: String

    private let sourceList: [ContainerSource]
    private var containerList: [ContainerInfo]
    private var subscribers: [ContainerSource: [AsyncThrowingStream<Void, any Error>.Continuation]] = [:]

    public init(id: String, displayName: String, sources: [ContainerSource], containers: [ContainerInfo]) {
        self.id = id
        self.displayName = displayName
        self.sourceList = sources
        self.containerList = containers
    }

    public func sources() async throws -> [ContainerSource] {
        sourceList
    }

    public func containers(in source: ContainerSource) async throws -> [ContainerInfo] {
        containerList.filter { $0.ref.source == source }
    }

    public func perform(_ action: ContainerAction, on ref: ContainerRef) async throws {
        guard let index = containerList.firstIndex(where: { $0.ref == ref }) else {
            throw Failure.containerNotFound(ref.containerID)
        }
        let container = containerList[index]
        containerList[index] = switch action {
        case .start, .restart: container.with(state: .running, status: "Up 1 second")
        case .stop: container.with(state: .exited, status: "Exited (0) 1 second ago")
        }
        subscribers[ref.source, default: []].forEach { $0.yield() }
    }

    public func changes(in source: ContainerSource) async -> AsyncThrowingStream<Void, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Void, any Error>.makeStream()
        subscribers[source, default: []].append(continuation)
        return stream
    }

    public func logs(for ref: ContainerRef) async -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            (1...3).forEach { continuation.yield("\(ref.containerID) log line \($0)") }
            continuation.finish()
        }
    }

    public func subscriberCount(for source: ContainerSource) -> Int {
        subscribers[source, default: []].count
    }
}

extension InMemoryRuntime {
    public static func sample() -> InMemoryRuntime {
        let runtimeID = "sample"
        let colima = ContainerSource(runtimeID: runtimeID, name: "colima")
        let vmpal = ContainerSource(runtimeID: runtimeID, name: "vmpal")

        func container(_ source: ContainerSource, _ name: String, _ image: String, _ state: ContainerState, _ status: String) -> ContainerInfo {
            ContainerInfo(ref: ContainerRef(source: source, containerID: name), name: name, image: image, state: state, status: status)
        }

        return InMemoryRuntime(
            id: runtimeID,
            displayName: "Sample",
            sources: [colima, vmpal],
            containers: [
                container(colima, "web", "nginx:latest", .running, "Up 2 hours"),
                container(colima, "db", "postgres:17", .running, "Up 2 hours"),
                container(colima, "worker", "alpine:3", .exited, "Exited (0) 5 minutes ago"),
                container(vmpal, "cache", "redis:7", .paused, "Up 1 hour (Paused)"),
            ]
        )
    }
}
