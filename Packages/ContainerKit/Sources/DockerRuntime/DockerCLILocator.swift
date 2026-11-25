import Foundation

/// How the app chooses the `docker` executable.
public enum DockerCLISelection: Sendable, Equatable {
    /// Search the well-known installer directories and `PATH`.
    case automatic
    /// Use exactly this path. The locator does not fall back to a search if the path is not executable.
    case custom(path: String)
}

/// Finds the `docker` executable. Apps started from Finder do not inherit
/// the login shell's `PATH`, so the locator also checks the directories
/// where common Docker installers put the CLI.
public struct DockerCLILocator: Sendable {
    let searchDirectories: [URL]
    let isExecutable: @Sendable (URL) -> Bool
    let selection: @Sendable () -> DockerCLISelection

    /// - Parameter selection: Read on every `locate()` call, so a change of the setting applies without a restart.
    public init(
        searchDirectories: [URL] = DockerCLILocator.defaultSearchDirectories(),
        isExecutable: @escaping @Sendable (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) },
        selection: @escaping @Sendable () -> DockerCLISelection = { .automatic }
    ) {
        self.searchDirectories = searchDirectories
        self.isExecutable = isExecutable
        self.selection = selection
    }

    public func locate() -> URL? {
        switch selection() {
        case .automatic:
            searchDirectories
                .lazy
                .map { $0.appending(path: "docker") }
                .first(where: isExecutable)
        case .custom(let path):
            Self.customURL(for: path).flatMap { isExecutable($0) ? $0 : nil }
        }
    }

    /// Expands a leading `~` and rejects an empty path.
    public static func customURL(for path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }
        return URL(filePath: (trimmed as NSString).expandingTildeInPath)
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
