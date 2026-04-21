import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct BootstrapCoordinatorTests {
    @MainActor
    static func main() async {
        var startCount = 0
        var resetCount = 0
        var terminateCount = 0

        let coordinator = AppBootstrapCoordinator(
            startWork: {
                startCount += 1
            },
            resetWork: {
                resetCount += 1
            },
            terminationWork: {
                terminateCount += 1
            }
        )

        await coordinator.startIfNeeded()
        expect(startCount == 1, "coordinator should start bootstrap once")
        expect(coordinator.state == .started, "successful bootstrap should enter started state")

        await coordinator.startIfNeeded()
        expect(startCount == 1, "coordinator should not bootstrap twice once started")

        await coordinator.resetForUnauthenticated()
        expect(resetCount == 1, "reset should run when leaving authenticated state")
        expect(coordinator.state == .idle, "reset should bring coordinator back to idle")

        coordinator.prepareForAppTermination()
        expect(terminateCount == 1, "termination hook should run once")
        expect(coordinator.state == .idle, "termination should leave coordinator idle")

        print("Bootstrap coordinator tests passed.")
    }
}
