import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct GatewayRuntimeCodableTests {
    static func main() throws {
        let legacyRuntimeJSON = """
        {
          "profileID": "00000000-0000-0000-0000-000000000001",
          "slug": "default",
          "displayName": "Default",
          "sourceKind": "managed",
          "managementMode": "managedByEZRWorker",
          "resolvedConfigPath": "/tmp/default/openclaw.json",
          "resolvedStateDir": "/tmp/default/state",
          "resolvedWorkspaceRoot": "/tmp/default/workspace",
          "resolvedPort": 18809,
          "isPrepared": true,
          "isRunning": true,
          "pid": 12345,
          "readyState": "starting",
          "ownership": "adopted",
          "lastProbeAt": null,
          "lastError": null,
          "lastLifecycleMessage": "Gateway 进程运行中，等待健康检查"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyRuntime = try decoder.decode(
            SupervisorProfileRuntime.self,
            from: Data(legacyRuntimeJSON.utf8)
        )

        expect(legacyRuntime.healthState == .launching, "legacy runtime should infer launching health")
        expect(legacyRuntime.adoptionKind == .managedAdopted, "managed adopted runtime should infer managedAdopted")
        expect(legacyRuntime.portListeningPID == nil, "legacy runtime should allow missing port listening pid")
        expect(legacyRuntime.httpResponding == nil, "legacy runtime should allow missing HTTP response flag")

        let runtime = SupervisorProfileRuntime(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            slug: "sales",
            displayName: "Sales",
            sourceKind: .managed,
            managementMode: .managedByEZRWorker,
            resolvedConfigPath: "/tmp/sales/openclaw.json",
            resolvedStateDir: "/tmp/sales/state",
            resolvedWorkspaceRoot: "/tmp/sales/workspace",
            resolvedPort: 18810,
            isPrepared: true,
            isRunning: true,
            pid: 23456,
            readyState: .starting,
            ownership: .adopted,
            portListeningPID: 23456,
            httpResponding: false,
            adoptionKind: .managedAdopted,
            lastProbeAt: nil,
            healthState: .unresponsive,
            lastError: nil,
            lastLifecycleMessage: "Gateway 进程运行中，但健康检查已连续 90 秒无响应"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(runtime)
        let decoded = try decoder.decode(SupervisorProfileRuntime.self, from: encoded)

        expect(decoded.portListeningPID == 23456, "runtime should preserve port listening pid")
        expect(decoded.httpResponding == false, "runtime should preserve HTTP response flag")
        expect(decoded.adoptionKind == .managedAdopted, "runtime should preserve adoption kind")
        expect(decoded.healthState == .unresponsive, "runtime should preserve health state")

        print("Gateway runtime codable tests passed.")
    }
}
