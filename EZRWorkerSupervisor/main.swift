import Darwin
import Dispatch
import Foundation

if CommandLine.arguments.contains("--prepare-upgrade") {
    let timeout = prepareUpgradeTimeout(from: CommandLine.arguments)
    let controller = EZRWorkerSupervisorController()
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task {
        let result = await controller.prepareForUpgrade(timeoutSeconds: timeout)
        if let message = result.1, !message.isEmpty {
            print(message)
        }
        exitCode = result.0 ? 0 : 1
        semaphore.signal()
    }

    semaphore.wait()
    exit(exitCode)
}

final class EZRWorkerSupervisorDelegate: NSObject, NSXPCListenerDelegate {
    let service = EZRWorkerSupervisorService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: EZRWorkerSupervisorProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: EZRWorkerBranding.supervisorMachServiceName)
let delegate = EZRWorkerSupervisorDelegate()
listener.delegate = delegate
listener.resume()

Task {
    await delegate.service.reconcileLaunchState()
}

dispatchMain()

private func prepareUpgradeTimeout(from arguments: [String]) -> TimeInterval {
    guard let index = arguments.firstIndex(of: "--timeout"),
          arguments.indices.contains(arguments.index(after: index)),
          let value = TimeInterval(arguments[arguments.index(after: index)])
    else {
        return 10
    }
    return max(1, value)
}
