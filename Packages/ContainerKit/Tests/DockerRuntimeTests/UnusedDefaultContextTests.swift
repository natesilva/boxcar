@testable import DockerRuntime
import Foundation
import Testing

struct UnusedDefaultContextTests {
    private func context(_ name: String, _ endpoint: String?) -> DockerOutput.Context {
        DockerOutput.Context(name: name, endpoint: endpoint)
    }

    @Test func defaultContextIsRemovedWhenNothingExistsAtItsSocketPath() {
        let contexts = [
            context("default", "unix:///var/run/docker.sock"),
            context("vmpal", "unix:///Users/test/.vmpal/docker.sock"),
        ]

        let names = DockerOutput.removingUnusedDefaultContext(contexts, entryExists: { _ in false }).map(\.name)

        #expect(names == ["vmpal"])
    }

    @Test func defaultContextIsKeptWhenSomethingExistsAtItsSocketPath() {
        let contexts = [context("default", "unix:///var/run/docker.sock")]

        let names = DockerOutput.removingUnusedDefaultContext(contexts, entryExists: { $0 == "/var/run/docker.sock" }).map(\.name)

        #expect(names == ["default"])
    }

    @Test func otherContextsAreKeptWhenTheirSocketIsMissing() {
        let contexts = [
            context("orbstack", "unix:///Users/test/.orbstack/run/docker.sock"),
            context("vmpal", "unix:///Users/test/.vmpal/docker.sock"),
        ]

        let names = DockerOutput.removingUnusedDefaultContext(contexts, entryExists: { _ in false }).map(\.name)

        #expect(names == ["orbstack", "vmpal"])
    }

    @Test func defaultContextWithoutUnixEndpointIsKept() {
        let contexts = [
            context("default", "tcp://127.0.0.1:2375"),
            context("default", nil),
        ]

        let names = DockerOutput.removingUnusedDefaultContext(contexts, entryExists: { _ in false }).map(\.name)

        #expect(names == ["default", "default"])
    }
}
