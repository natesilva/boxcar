import ContainerCore
import Foundation
import OSLog

/// Decodes the output of `docker … --format json`, which prints one JSON object per line.
enum DockerOutput {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Boxcar", category: "DockerOutput")

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

        private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

        /// The host of an `ssh://` or `tcp://` endpoint on another machine. An SSH host can
        /// be an alias from the SSH configuration, which only SSH can resolve.
        var remoteHost: String? {
            guard let endpoint, let url = URL(string: endpoint),
                  let scheme = url.scheme?.lowercased(), scheme == "ssh" || scheme == "tcp",
                  let host = url.host(percentEncoded: false), !Self.loopbackHosts.contains(host.lowercased())
            else {
                return nil
            }
            return host
        }
    }

    struct Container: Decodable, Equatable {
        let id: String
        let names: String
        let image: String
        let state: String
        let status: String
        let labels: String?
        let ports: String?

        enum CodingKeys: String, CodingKey {
            case id = "ID"
            case names = "Names"
            case image = "Image"
            case state = "State"
            case status = "Status"
            case labels = "Labels"
            case ports = "Ports"
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
            return GroupMembership(
                groupName: project,
                memberName: label("com.docker.compose.service") ?? primaryName,
                workingDirectory: label("com.docker.compose.project.working_dir")
            )
        }

        /// `Ports` is a comma-separated list of mappings, such as `0.0.0.0:5173->5173/tcp, [::]:5173->5173/tcp`.
        /// Engines list a port once for each host address, and a range as `8000-8002->8000-8002/tcp`.
        /// Ports that are exposed but not published have no `->`. The browser can open only TCP ports.
        /// A remote machine does not accept connections from the Mac on its loopback addresses.
        func publishedPorts(remoteHost: String? = nil) -> [PublishedPort] {
            let hostPorts = (ports ?? "").split(separator: ",").flatMap { entry -> [Int] in
                let mapping = entry.trimmingCharacters(in: .whitespaces)
                guard mapping.hasSuffix("/tcp"),
                      let arrow = mapping.range(of: "->"),
                      remoteHost == nil || !Self.isLoopbackMapping(mapping),
                      let portText = mapping[..<arrow.lowerBound].split(separator: ":").last
                else {
                    return []
                }
                let bounds = portText.split(separator: "-").compactMap { Int($0) }
                switch bounds.count {
                case 1: return bounds
                case 2 where bounds[0] <= bounds[1]: return Array(bounds[0]...bounds[1])
                default: return []
                }
            }
            return Set(hostPorts).sorted().map { PublishedPort(hostPort: $0, host: remoteHost ?? "localhost") }
        }

        private static func isLoopbackMapping(_ mapping: String) -> Bool {
            ["127.", "::1:", "[::1]:"].contains { mapping.hasPrefix($0) }
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

    /// Skips a line that does not decode, so that one unexpected line does not hide a whole
    /// context. Throws if no line decodes, because the output then has an unknown format.
    private static func decodeLines<T: Decodable>(_ output: String) throws -> [T] {
        let decoder = JSONDecoder()
        var values: [T] = []
        var failures: [any Error] = []
        for line in output.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            do {
                values.append(try decoder.decode(T.self, from: Data(line.utf8)))
            } catch {
                failures.append(error)
            }
        }
        if values.isEmpty, let failure = failures.first {
            throw failure
        }
        for failure in failures {
            logger.error("Skipped a line of docker output: \(String(describing: failure), privacy: .public)")
        }
        return values
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
            diagnostics: diagnostics,
            ports: publishedPorts(remoteHost: source.remoteHost)
        )
    }
}
