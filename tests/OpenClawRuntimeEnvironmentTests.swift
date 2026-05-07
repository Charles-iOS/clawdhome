import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct OpenClawRuntimeEnvironmentTests {
    static func main() {
        setenv("OPENCLAW_NO_RESPAWN", "1", 1)
        setenv("XPC_SERVICE_NAME", "ai.ezrworker.mac.supervisor", 1)
        setenv("OPENCLAW_LAUNCHD_LABEL", "ai.openclaw.gateway", 1)
        defer {
            unsetenv("OPENCLAW_NO_RESPAWN")
            unsetenv("XPC_SERVICE_NAME")
            unsetenv("OPENCLAW_LAUNCHD_LABEL")
        }

        let gatewayEnvironment = OpenClawRuntime.buildEnvironment(purpose: .gateway)
        expect(
            gatewayEnvironment["OPENCLAW_NO_RESPAWN"] == nil,
            "gateway environment should allow full process restart handoff"
        )
        expect(
            gatewayEnvironment["XPC_SERVICE_NAME"] == nil,
            "gateway environment should remove inherited service markers"
        )
        expect(
            gatewayEnvironment["OPENCLAW_LAUNCHD_LABEL"] == EZRWorkerBranding.supervisorLaunchAgentLabel,
            "gateway environment should expose the EZRWorker supervisor handoff marker"
        )
        expect(
            gatewayEnvironment["EZRWORKER_SUPERVISOR_CHILD"] == "1",
            "gateway environment should keep EZRWorker supervisor marker"
        )

        let commandEnvironment = OpenClawRuntime.buildEnvironment(purpose: .command)
        expect(
            commandEnvironment["OPENCLAW_NO_RESPAWN"] == "1",
            "command environment should keep respawn disabled"
        )
        expect(
            commandEnvironment["XPC_SERVICE_NAME"] == nil,
            "command environment should remove inherited service markers"
        )
        expect(
            commandEnvironment["OPENCLAW_LAUNCHD_LABEL"] == nil,
            "command environment should not advertise supervisor handoff"
        )

        print("OpenClaw runtime environment tests passed.")
    }
}
