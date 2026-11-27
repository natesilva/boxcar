import Foundation

/// An error that a web page helps the user to resolve.
public protocol HelpLinkedError: Error {
    var helpURL: URL? { get }
}

/// A container engine family, such as Docker or Apple Container.
public protocol ContainerRuntime: Sendable {
    var id: String { get }
    var displayName: String { get }

    func sources() async throws -> [ContainerSource]
    func containers(in source: ContainerSource) async throws -> [ContainerInfo]
    func perform(_ action: ContainerAction, on ref: ContainerRef) async throws
    func perform(_ action: ContainerAction, on group: ContainerGroupRef) async throws

    /// Yields a value each time a container in the source changes.
    /// The stream throws or finishes when the source becomes unreachable.
    func changes(in source: ContainerSource) async -> AsyncThrowingStream<Void, any Error>

    /// Yields recent log lines of the container, then new lines as the container writes them.
    /// - Parameter lastLine: The last line that an earlier stream of this container yielded.
    ///   If it is not `nil`, the stream yields only the lines that the container wrote after that line.
    func logs(for ref: ContainerRef, after lastLine: String?) async -> AsyncThrowingStream<String, any Error>

    /// Stops background work synchronously. The app calls this when it terminates.
    func shutdown()
}

extension ContainerRuntime {
    public func shutdown() {}

    public func logs(for ref: ContainerRef) async -> AsyncThrowingStream<String, any Error> {
        await logs(for: ref, after: nil)
    }
}
