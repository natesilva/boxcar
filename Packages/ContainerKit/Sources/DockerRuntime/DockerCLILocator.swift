import Foundation

/// Finds the `docker` executable. Apps started from Finder do not inherit
/// the login shell's `PATH`, so the locator also checks the directories
/// where common Docker installers put the CLI.
public struct DockerCLILocator: Sendable {
    let searchDirectories: [URL]
    let isExecutable: @Sendable (URL) -> Bool

    public init(
        searchDirectories: [URL] = DockerCLILocator.defaultSearchDirectories(),
        isExecutable: @escaping @Sendable (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) {
        self.searchDirectories = searchDirectories
        self.isExecutable = isExecutable
    }

    public func locate() -> URL? {
        searchDirectories
            .lazy
            .map { $0.appending(path: "docker") }
            .first(where: isExecutable)
    }

    public static func defaultSearchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let wellKnown = ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(filePath: $0) }
            + [".orbstack/bin", ".docker/bin", ".rd/bin"].map { home.appending(path: $0) }
        let fromPath = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(filePath: String($0)) }

        var seen: Set<String> = []
        return (wellKnown + fromPath).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
