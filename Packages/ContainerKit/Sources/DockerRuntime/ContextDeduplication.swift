import Foundation

extension DockerOutput {
    /// Resolves symlinks in a socket path. `resolvingSymlinksInPath()` leaves a
    /// symlink unchanged when its target does not exist, which happens when an
    /// engine is stopped and has removed its socket. In that case the function
    /// reads the link's target directly, so a stopped engine is still recognized.
    static func resolveSymlinks(_ path: String) -> String {
        let resolved = URL(filePath: path).resolvingSymlinksInPath().path
        guard resolved == path, let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return resolved
        }
        let directory = URL(filePath: path).deletingLastPathComponent()
        return URL(filePath: destination, relativeTo: directory).standardizedFileURL.path
    }

    /// Several contexts can reach the same engine. For example, the `default`
    /// context uses `/var/run/docker.sock`, which is often a symlink to the
    /// socket of another context. This function keeps one context per socket
    /// and removes the others, so the menu does not list one engine twice.
    ///
    /// In each group, it keeps the context whose socket path is not a symlink.
    /// If no context or more than one context qualifies, it keeps the first
    /// context in the CLI's order. Contexts without a `unix://` endpoint are
    /// grouped by their endpoint string. Contexts without an endpoint are always kept.
    static func uniqueContexts(_ contexts: [Context], resolveSymlinks: (String) -> String) -> [Context] {
        var chosenIndexByKey: [String: Int] = [:]
        var isRealPathByIndex: [Int: Bool] = [:]

        for (index, context) in contexts.enumerated() {
            let key: String
            let isRealPath: Bool
            if let path = context.socketPath {
                let resolved = resolveSymlinks(path)
                key = "unix://\(resolved)"
                isRealPath = resolved == path
            } else if let endpoint = context.endpoint {
                key = endpoint
                isRealPath = false
            } else {
                continue
            }
            isRealPathByIndex[index] = isRealPath

            if let chosen = chosenIndexByKey[key] {
                if isRealPath, isRealPathByIndex[chosen] == false {
                    chosenIndexByKey[key] = index
                }
            } else {
                chosenIndexByKey[key] = index
            }
        }

        let removed = Set(isRealPathByIndex.keys).subtracting(chosenIndexByKey.values)
        return contexts.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    }
}
