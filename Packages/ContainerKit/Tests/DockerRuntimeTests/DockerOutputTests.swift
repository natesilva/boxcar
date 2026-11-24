@testable import DockerRuntime
import ContainerCore
import Testing

struct DockerOutputTests {
    @Test func decodesContextList() throws {
        let output = """
            {"Current":true,"Description":"colima","DockerEndpoint":"unix:///Users/test/.colima/default/docker.sock","Error":"","Name":"colima"}
            {"Current":false,"Description":"VMPal's containers.","DockerEndpoint":"unix:///Users/test/.vmpal/docker.sock","Error":"","Name":"vmpal"}

            """

        let contexts = try DockerOutput.contexts(from: output)

        #expect(contexts.map(\.name) == ["colima", "vmpal"])
        #expect(contexts.map(\.socketPath) == ["/Users/test/.colima/default/docker.sock", "/Users/test/.vmpal/docker.sock"])
    }

    @Test func networkEndpointHasNoSocketPath() throws {
        let output = #"{"Name":"remote","DockerEndpoint":"ssh://user@host"}"#

        let context = try #require(try DockerOutput.contexts(from: output).first)

        #expect(context.endpoint == "ssh://user@host")
        #expect(context.socketPath == nil)
    }

    @Test func decodesContainerList() throws {
        let output = """
            {"Command":"\\"docker-entrypoint.sh postgres\\"","ID":"7180","Image":"postgres:16","Labels":"","Names":"litellm-db-1","Ports":"","State":"running","Status":"Up 2 hours (healthy)"}
            {"Command":"\\"sh\\"","ID":"5ef0","Image":"alpine:3","Labels":"","Names":"worker,alias","Ports":"","State":"exited","Status":"Exited (0) 5 minutes ago"}
            """
        let source = ContainerSource(runtimeID: "docker", name: "vmpal")

        let containers = try DockerOutput.containers(from: output).map { $0.containerInfo(in: source) }

        #expect(containers.map(\.name) == ["litellm-db-1", "worker"])
        #expect(containers.map(\.state) == [.running, .exited])
        #expect(containers[0].ref == ContainerRef(source: source, containerID: "7180"))
        #expect(containers[0].status == "Up 2 hours (healthy)")
    }

    @Test func emptyOutputHasNoContainers() throws {
        #expect(try DockerOutput.containers(from: "").isEmpty)
    }

    @Test func unknownStateMapsToUnknown() throws {
        let output = #"{"ID":"1","Image":"x","Names":"x","State":"hibernating","Status":""}"#
        let source = ContainerSource(runtimeID: "docker", name: "default")

        let container = try #require(try DockerOutput.containers(from: output).first)

        #expect(container.containerInfo(in: source).state == .unknown)
    }

    @Test func invalidOutputThrows() {
        #expect(throws: (any Error).self) {
            try DockerOutput.containers(from: "not json")
        }
    }
}
