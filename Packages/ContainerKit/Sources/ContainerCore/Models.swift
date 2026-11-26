import Foundation

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
    /// The host name of the engine, if the engine runs on another machine.
    public let remoteHost: String?

    public var id: String { "\(runtimeID)/\(name)" }

    public init(runtimeID: String, name: String, remoteHost: String? = nil) {
        self.runtimeID = runtimeID
        self.name = name
        self.remoteHost = remoteHost
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
    /// The path of the directory that holds the group's definition, such as a Compose file.
    public let workingDirectory: String?

    public init(groupName: String, memberName: String, workingDirectory: String? = nil) {
        self.groupName = groupName
        self.memberName = memberName
        self.workingDirectory = workingDirectory
    }
}

/// A TCP port of a container that the engine publishes on the host.
public struct PublishedPort: Identifiable, Hashable, Sendable {
    public let host: String
    public let hostPort: Int

    public var id: Int { hostPort }

    /// The address that reaches the port from the Mac, as a person types it.
    public var address: String {
        host.contains(":") ? "[\(host)]:\(hostPort)" : "\(host):\(hostPort)"
    }

    public var url: URL? { URL(string: "http://\(address)") }

    public init(hostPort: Int, host: String = "localhost") {
        self.hostPort = hostPort
        self.host = host
    }
}

public enum HealthStatus: String, Sendable, Codable {
    case starting
    case healthy
    case unhealthy
}

/// Details that explain a container's state. A runtime sets the details that it can find.
public struct ContainerDiagnostics: Hashable, Sendable {
    public let health: HealthStatus?
    /// The exit code of the container's last run.
    public let exitCode: Int?
    /// Whether the kernel stopped the container's last run because it used too much memory.
    public let outOfMemory: Bool

    public init(health: HealthStatus? = nil, exitCode: Int? = nil, outOfMemory: Bool = false) {
        self.health = health
        self.exitCode = exitCode
        self.outOfMemory = outOfMemory
    }
}

/// How well a container works, from normal operation to a failure.
public enum ContainerCondition: Sendable, CaseIterable {
    case normal
    case warning
    case critical
    case inactive
}

public struct ContainerInfo: Identifiable, Hashable, Sendable {
    public let ref: ContainerRef
    public let name: String
    public let image: String
    public let state: ContainerState
    public let status: String
    public let group: GroupMembership?
    public let diagnostics: ContainerDiagnostics
    public let ports: [PublishedPort]

    public var id: ContainerRef { ref }

    public var groupRef: ContainerGroupRef? {
        group.map { ContainerGroupRef(source: ref.source, name: $0.groupName) }
    }

    public init(
        ref: ContainerRef,
        name: String,
        image: String,
        state: ContainerState,
        status: String,
        group: GroupMembership? = nil,
        diagnostics: ContainerDiagnostics = ContainerDiagnostics(),
        ports: [PublishedPort] = []
    ) {
        self.ref = ref
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.group = group
        self.diagnostics = diagnostics
        self.ports = ports
    }

    /// The diagnostics and ports of the previous state do not apply to the new state, so they are not kept.
    func with(state: ContainerState, status: String) -> ContainerInfo {
        ContainerInfo(ref: ref, name: name, image: image, state: state, status: status, group: group)
    }

    /// A container in the `restarting` state is in a restart loop after repeated failures.
    public var condition: ContainerCondition {
        switch state {
        case .dead, .restarting: .critical
        case .running: diagnostics.health == .unhealthy ? .warning : .normal
        case .paused: .warning
        case .exited: exitCondition
        case .created, .removing, .unknown: .inactive
        }
    }

    /// A process that stops because of a signal exits with code 128 plus the signal number.
    /// `docker stop` sends SIGTERM (143), or SIGINT (130) if the image sets it as its stop signal.
    /// It sends SIGKILL (137) if the container does not stop within the timeout.
    private static let normalStopExitCodes: Set<Int> = [0, 130, 137, 143]

    private var exitCondition: ContainerCondition {
        if diagnostics.outOfMemory {
            return .critical
        }
        if let exitCode = diagnostics.exitCode, !Self.normalStopExitCodes.contains(exitCode) {
            return .warning
        }
        return .inactive
    }
}
