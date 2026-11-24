import ContainerCore
import Testing

struct ContainerConditionTests {
    private func container(_ state: ContainerState, _ diagnostics: ContainerDiagnostics = ContainerDiagnostics()) -> ContainerInfo {
        ContainerInfo(
            ref: ContainerRef(source: ContainerSource(runtimeID: "test", name: "local"), containerID: "1"),
            name: "app",
            image: "alpine",
            state: state,
            status: "",
            diagnostics: diagnostics
        )
    }

    @Test(arguments: [nil, HealthStatus.starting, .healthy])
    func runningWithoutFailedHealthCheckIsNormal(health: HealthStatus?) {
        #expect(container(.running, ContainerDiagnostics(health: health)).condition == .normal)
    }

    @Test func unhealthyIsWarning() {
        #expect(container(.running, ContainerDiagnostics(health: .unhealthy)).condition == .warning)
    }

    @Test func runningIgnoresExitCodeOfPreviousRun() {
        #expect(container(.running, ContainerDiagnostics(exitCode: 1)).condition == .normal)
    }

    @Test func pausedIsWarning() {
        #expect(container(.paused).condition == .warning)
    }

    @Test(arguments: [ContainerState.dead, .restarting])
    func deadAndRestartingAreCritical(state: ContainerState) {
        #expect(container(state).condition == .critical)
    }

    @Test(arguments: [0, 130, 137, 143])
    func normalStopIsInactive(exitCode: Int) {
        #expect(container(.exited, ContainerDiagnostics(exitCode: exitCode)).condition == .inactive)
    }

    @Test(arguments: [1, 2, 139])
    func errorExitIsWarning(exitCode: Int) {
        #expect(container(.exited, ContainerDiagnostics(exitCode: exitCode)).condition == .warning)
    }

    @Test func outOfMemoryIsCritical() {
        #expect(container(.exited, ContainerDiagnostics(exitCode: 137, outOfMemory: true)).condition == .critical)
    }

    @Test(arguments: [ContainerState.created, .removing, .unknown])
    func otherStatesAreInactive(state: ContainerState) {
        #expect(container(state).condition == .inactive)
    }
}
