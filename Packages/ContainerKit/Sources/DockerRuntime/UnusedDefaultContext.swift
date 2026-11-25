extension DockerOutput {
    /// Docker always lists a built-in `default` context, even on a Mac where no engine
    /// has ever used its socket path. This function removes that context when nothing
    /// exists at its socket path. A symlink whose target is missing still counts as
    /// something, because an installed engine that is stopped leaves such a link.
    /// Contexts with other names are never removed, because someone or some installer
    /// created them on purpose.
    static func removingUnusedDefaultContext(_ contexts: [Context], entryExists: (String) -> Bool) -> [Context] {
        contexts.filter { context in
            guard context.name == "default", let path = context.socketPath else {
                return true
            }
            return entryExists(path)
        }
    }
}
