@testable import ContainerCore
import Testing

@MainActor
struct ContainerGroupTests {
    private let source = ContainerSource(runtimeID: "memory", name: "local")

    private func container(_ name: String, _ state: ContainerState, group: String? = nil) -> ContainerInfo {
        ContainerInfo(
            ref: ContainerRef(source: source, containerID: name),
            name: name,
            image: "alpine",
            state: state,
            status: "",
            group: group.map { GroupMembership(groupName: $0, memberName: "\(name)-service") }
        )
    }

    @Test func itemsCollectGroupMembersAtTheFirstMembersPosition() {
        let section = ContainerSection(
            source: source,
            containers: [
                container("solo", .running),
                container("app", .running, group: "shop"),
                container("other", .exited),
                container("db", .exited, group: "shop"),
            ],
            errorMessage: nil
        )

        let summary = section.items.map { item -> String in
            switch item {
            case .container(let container): container.name
            case .group(let group): "\(group.ref.name)[\(group.containers.map(\.name).joined(separator: ","))]"
            }
        }

        #expect(summary == ["solo", "shop[app,db]", "other"])
    }

    @Test func groupAllowsActionWhenAnyMemberAllowsIt() {
        let ref = ContainerGroupRef(source: source, name: "shop")
        let partial = ContainerGroup(ref: ref, containers: [container("app", .running, group: "shop"), container("db", .exited, group: "shop")])
        let stopped = ContainerGroup(ref: ref, containers: [container("app", .exited, group: "shop")])

        #expect(partial.runningCount == 1)
        #expect(partial.allows(.start) && partial.allows(.stop) && partial.allows(.restart))
        #expect(stopped.allows(.start) && !stopped.allows(.stop))
    }

    @Test func groupActionUpdatesAllMembers() async throws {
        let runtime = InMemoryRuntime(
            id: "memory",
            displayName: "Memory",
            sources: [source],
            containers: [container("app", .exited, group: "shop"), container("db", .exited, group: "shop"), container("solo", .exited)]
        )
        let store = ContainerStore(runtimes: [runtime])
        await store.refresh()
        guard case .group(let group) = try #require(store.sections.first?.items.first) else {
            Issue.record("Expected a group as the first item")
            return
        }

        await store.perform(.start, on: group)

        let states = store.sections[0].containers.map { "\($0.name)=\($0.state.rawValue)" }
        #expect(states == ["app=running", "db=running", "solo=exited"])
        #expect(store.pendingGroupActions.isEmpty)
    }
}
