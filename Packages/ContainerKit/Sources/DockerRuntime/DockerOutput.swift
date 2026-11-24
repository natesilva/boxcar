import ContainerCore
import Foundation

/// Decodes the output of `docker … --format json`, which prints one JSON object per line.
enum DockerOutput {
    struct Context: Decodable, Equatable {
        let name: String
        let endpoint: String?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case endpoint = "DockerEndpoint"
        }

        /// The socket path of a `unix://` endpoint. Other endpoint types have no local path.
        var socketPath: String? {
            guard let endpoint, let url = URL(string: endpoint), url.scheme == "unix" else {
                return nil
            }
            return url.path
        }
    }

    struct Container: Decodable, Equatable {
        let id: String
        let names: String
        let image: String
        let state: String
        let status: String
        let labels: String?

        enum CodingKeys: String, CodingKey {
            case id = "ID"
            case names = "Names"
            case image = "Image"
            case state = "State"
            case status = "Status"
            case labels = "Labels"
        }

        /// `Labels` is one comma-separated string of `key=value` pairs. Some values,
        /// such as Compose's `config_files`, can contain commas, so splitting on commas
        /// is reliable only for labels whose values cannot contain them. Compose project
        /// and service names cannot.
        func label(_ key: String) -> String? {
            let prefix = "\(key)="
            return labels?
                .split(separator: ",")
                .first { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) }
        }

        var composeMembership: GroupMembership? {
            guard let project = label("com.docker.compose.project") else {
                return nil
            }
            return GroupMembership(groupName: project, memberName: label("com.docker.compose.service") ?? primaryName)
        }

        /// `Names` is a comma-separated list. The first name is the container's own name.
        var primaryName: String {
            names.split(separator: ",").first.map(String.init) ?? id
        }
    }

    /// One element of the JSON array that `docker inspect --type container` prints.
    struct Inspection: Decodable, Equatable {
        let id: String
        let state: State

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case state = "State"
        }

        struct State: Decodable, Equatable {
            let exitCode: Int
            let oomKilled: Bool
            let health: Health?

            enum CodingKeys: String, CodingKey {
                case exitCode = "ExitCode"
                case oomKilled = "OOMKilled"
                case health = "Health"
            }
        }

        struct Health: Decodable, Equatable {
            let status: String

            enum CodingKeys: String, CodingKey {
                case status = "Status"
            }
        }

        var diagnostics: ContainerDiagnostics {
            ContainerDiagnostics(
                health: state.health.flatMap { HealthStatus(rawValue: $0.status) },
                exitCode: state.exitCode,
                outOfMemory: state.oomKilled
            )
        }
    }

    static func contexts(from output: String) throws -> [Context] {
        try decodeLines(output)
    }

    static func containers(from output: String) throws -> [Container] {
        try decodeLines(output)
    }

    /// Returns the diagnostics of each inspected container, keyed by container ID.
    static func diagnostics(from output: String) throws -> [String: ContainerDiagnostics] {
        let inspections = try JSONDecoder().decode([Inspection].self, from: Data(output.utf8))
        return Dictionary(inspections.map { ($0.id, $0.diagnostics) }) { first, _ in first }
    }

    private static func decodeLines<T: Decodable>(_ output: String) throws -> [T] {
        let decoder = JSONDecoder()
        return try output
            .split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .map { try decoder.decode(T.self, from: Data($0.utf8)) }
    }
}

extension DockerOutput.Container {
    func containerInfo(in source: ContainerSource, diagnostics: ContainerDiagnostics = ContainerDiagnostics()) -> ContainerInfo {
        ContainerInfo(
            ref: ContainerRef(source: source, containerID: id),
            name: primaryName,
            image: image,
            state: ContainerState(rawValue: state) ?? .unknown,
            status: status,
            group: composeMembership,
            diagnostics: diagnostics
        )
    }
}
