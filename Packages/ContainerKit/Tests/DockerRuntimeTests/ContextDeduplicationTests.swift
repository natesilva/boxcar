@testable import DockerRuntime
import Foundation
import Testing

struct ContextDeduplicationTests {
    private let symlinks = [
        "/var/run/docker.sock": "/Users/test/.vmpal/docker.sock",
        "/Users/test/.docker/run/docker.sock": "/Users/test/.vmpal/docker.sock",
    ]

    private func resolve(_ path: String) -> String {
        symlinks[path] ?? path
    }

    private func context(_ name: String, _ endpoint: String?) -> DockerOutput.Context {
        DockerOutput.Context(name: name, endpoint: endpoint)
    }

    @Test func symlinkedContextIsRemovedInFavorOfRealSocket() {
        let contexts = [
            context("colima", "unix:///Users/test/.colima/default/docker.sock"),
            context("default", "unix:///var/run/docker.sock"),
            context("vmpal", "unix:///Users/test/.vmpal/docker.sock"),
        ]

        let names = DockerOutput.uniqueContexts(contexts, resolveSymlinks: resolve).map(\.name)

        #expect(names == ["colima", "vmpal"])
    }

    @Test func realSocketWinsWhenItIsListedFirst() {
        let contexts = [
            context("vmpal", "unix:///Users/test/.vmpal/docker.sock"),
            context("default", "unix:///var/run/docker.sock"),
        ]

        #expect(DockerOutput.uniqueContexts(contexts, resolveSymlinks: resolve).map(\.name) == ["vmpal"])
    }

    @Test func symlinkWithoutOtherContextIsKept() {
        let contexts = [context("default", "unix:///var/run/docker.sock")]

        #expect(DockerOutput.uniqueContexts(contexts, resolveSymlinks: resolve).map(\.name) == ["default"])
    }

    @Test func twoSymlinksToTheSameSocketKeepTheFirst() {
        let contexts = [
            context("default", "unix:///var/run/docker.sock"),
            context("desktop", "unix:///Users/test/.docker/run/docker.sock"),
        ]

        #expect(DockerOutput.uniqueContexts(contexts, resolveSymlinks: resolve).map(\.name) == ["default"])
    }

    @Test func identicalNetworkEndpointsAreDeduplicated() {
        let contexts = [
            context("remote", "ssh://user@host"),
            context("remote-copy", "ssh://user@host"),
            context("other", "tcp://10.0.0.2:2376"),
        ]

        #expect(DockerOutput.uniqueContexts(contexts, resolveSymlinks: resolve).map(\.name) == ["remote", "other"])
    }

    @Test func contextsWithoutEndpointAreKept() {
        let contexts = [context("a", nil), context("b", nil)]

        #expect(DockerOutput.uniqueContexts(contexts, resolveSymlinks: resolve).map(\.name) == ["a", "b"])
    }

    @Test func defaultResolverFollowsRealSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "engine.sock")
        let link = directory.appending(path: "docker.sock")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let contexts = [
            context("link", "unix://\(link.path)"),
            context("real", "unix://\(DockerOutput.resolveSymlinks(target.path))"),
        ]

        #expect(DockerOutput.uniqueContexts(contexts, resolveSymlinks: DockerOutput.resolveSymlinks).map(\.name) == ["real"])
    }

    @Test func defaultResolverFollowsSymlinkToMissingSocket() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appending(path: "docker.sock")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "engine.sock")

        let resolved = DockerOutput.resolveSymlinks(link.path)

        #expect(resolved == directory.appending(path: "engine.sock").standardizedFileURL.path)
    }
}
