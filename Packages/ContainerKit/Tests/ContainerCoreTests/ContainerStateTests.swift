import ContainerCore
import Testing

struct ContainerStateTests {
    @Test(arguments: [ContainerState.running, .paused, .restarting])
    func activeStatesAllowStopAndRestart(state: ContainerState) {
        #expect(!state.allows(.start))
        #expect(state.allows(.stop))
        #expect(state.allows(.restart))
    }

    @Test(arguments: [ContainerState.created, .exited, .dead, .unknown])
    func inactiveStatesAllowStartOnly(state: ContainerState) {
        #expect(state.allows(.start))
        #expect(!state.allows(.stop))
        #expect(!state.allows(.restart))
    }
}
