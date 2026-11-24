/// A container engine family, such as Docker or Apple Container.
public protocol ContainerRuntime: Sendable {
    var id: String { get }
    var displayName: String { get }

    func sources() async throws -> [ContainerSource]
    func containers(in source: ContainerSource) async throws -> [ContainerInfo]
    func perform(_ action: ContainerAction, on ref: ContainerRef) async throws

    /// Yields a value each time a container in the source changes.
    /// The stream throws or finishes when the source becomes unreachable.
    func changes(in source: ContainerSource) async -> AsyncThrowingStream<Void, any Error>

    /// Yields recent log lines of the container, then new lines as the container writes them.
    func logs(for ref: ContainerRef) async -> AsyncThrowingStream<String, any Error>

    /// Stops background work synchronously. The app calls this when it terminates.
    func shutdown()
}

extension ContainerRuntime {
    public func shutdown() {}
}
