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

/// A named set of containers that a runtime controls together, such as a Docker Compose project.
public struct ContainerGroupRef: Hashable, Sendable {
    public let source: ContainerSource
    public let name: String

    public init(source: ContainerSource, name: String) {
        self.source = source
        self.name = name
    }
}

public struct GroupMembership: Hashable, Sendable {
    public let groupName: String
    /// The container's name inside the group, such as a Compose service name.
    public let memberName: String

    public init(groupName: String, memberName: String) {
        self.groupName = groupName
        self.memberName = memberName
    }
}

public struct ContainerInfo: Identifiable, Hashable, Sendable {
    public let ref: ContainerRef
    public let name: String
    public let image: String
    public let state: ContainerState
    public let status: String
    public let group: GroupMembership?

    public var id: ContainerRef { ref }

    public var groupRef: ContainerGroupRef? {
        group.map { ContainerGroupRef(source: ref.source, name: $0.groupName) }
    }

    public init(ref: ContainerRef, name: String, image: String, state: ContainerState, status: String, group: GroupMembership? = nil) {
        self.ref = ref
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.group = group
    }

    func with(state: ContainerState, status: String) -> ContainerInfo {
        ContainerInfo(ref: ref, name: name, image: image, state: state, status: status, group: group)
    }
}
