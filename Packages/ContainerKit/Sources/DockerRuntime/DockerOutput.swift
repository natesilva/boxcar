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

        enum CodingKeys: String, CodingKey {
            case id = "ID"
            case names = "Names"
            case image = "Image"
            case state = "State"
            case status = "Status"
        }

        /// `Names` is a comma-separated list. The first name is the container's own name.
        var primaryName: String {
            names.split(separator: ",").first.map(String.init) ?? id
        }
    }

    static func contexts(from output: String) throws -> [Context] {
        try decodeLines(output)
    }

    static func containers(from output: String) throws -> [Container] {
        try decodeLines(output)
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
    func containerInfo(in source: ContainerSource) -> ContainerInfo {
        ContainerInfo(
            ref: ContainerRef(source: source, containerID: id),
            name: primaryName,
            image: image,
            state: ContainerState(rawValue: state) ?? .unknown,
            status: status
        )
    }
}
