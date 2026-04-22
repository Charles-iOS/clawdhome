import Dispatch
import Foundation

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
