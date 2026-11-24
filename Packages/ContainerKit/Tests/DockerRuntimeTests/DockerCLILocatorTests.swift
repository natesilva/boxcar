import DockerRuntime
import Foundation
import Testing

struct DockerCLILocatorTests {
    @Test func returnsFirstExecutableInSearchOrder() {
        let locator = DockerCLILocator(
            searchDirectories: [URL(filePath: "/a"), URL(filePath: "/b"), URL(filePath: "/c")],
            isExecutable: { $0.path != "/a/docker" }
        )

        #expect(locator.locate()?.path == "/b/docker")
    }

    @Test func returnsNilWhenNoExecutableExists() {
        let locator = DockerCLILocator(searchDirectories: [URL(filePath: "/a")], isExecutable: { _ in false })

        #expect(locator.locate() == nil)
    }

    @Test func defaultDirectoriesListWellKnownBeforePathWithoutDuplicates() {
        let directories = DockerCLILocator.defaultSearchDirectories(
            environment: ["PATH": "/usr/bin:/opt/homebrew/bin:/custom/bin"],
            home: URL(filePath: "/Users/test")
        )

        #expect(directories.map(\.path) == [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Users/test/.orbstack/bin",
            "/Users/test/.docker/bin",
            "/Users/test/.rd/bin",
            "/usr/bin",
            "/custom/bin",
        ])
    }
}
