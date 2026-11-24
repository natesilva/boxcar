public enum ContainerState: String, Sendable, Codable {
    case created
    case running
    case paused
    case restarting
    case removing
    case exited
    case dead
    case unknown

    public var isActive: Bool {
        switch self {
        case .running, .paused, .restarting: true
        case .created, .removing, .exited, .dead, .unknown: false
        }
    }

    public func allows(_ action: ContainerAction) -> Bool {
        switch action {
        case .start: !isActive
        case .stop, .restart: isActive
        }
    }
}

public enum ContainerAction: Sendable, CaseIterable {
    case start
    case stop
    case restart
}

/// A place that containers come from, such as one Docker context.
public struct ContainerSource: Identifiable, Hashable, Sendable, Codable {
    public let runtimeID: String
    public let name: String

    public var id: String { "\(runtimeID)/\(name)" }

    public init(runtimeID: String, name: String) {
        self.runtimeID = runtimeID
        self.name = name
    }
}

public struct ContainerRef: Hashable, Sendable, Codable {
    public let source: ContainerSource
    public let containerID: String

    public init(source: ContainerSource, containerID: String) {
        self.source = source
        self.containerID = containerID
    }
}

public struct ContainerInfo: Identifiable, Hashable, Sendable {
    public let ref: ContainerRef
    public let name: String
    public let image: String
    public let state: ContainerState
    public let status: String

    public var id: ContainerRef { ref }

    public init(ref: ContainerRef, name: String, image: String, state: ContainerState, status: String) {
        self.ref = ref
        self.name = name
        self.image = image
        self.state = state
        self.status = status
    }

    func with(state: ContainerState, status: String) -> ContainerInfo {
        ContainerInfo(ref: ref, name: name, image: image, state: state, status: status)
    }
}
