import Foundation

final class EZRWorkerSupervisorService: NSObject, EZRWorkerSupervisorProtocol {
    private let controller = EZRWorkerSupervisorController()

    func reconcileLaunchState() async {
        await controller.reconcileLaunchState()
    }

    func ping(withReply reply: @escaping (String) -> Void) {
        Task {
            reply(await controller.ping())
        }
    }

    func listProfilesRuntime(withReply reply: @escaping (String) -> Void) {
        Task {
            reply(await controller.listProfilesRuntimeJSON())
        }
    }

    func prepareProfile(profileID: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let uuid = UUID(uuidString: profileID) else {
            reply(false, "无效的 profileID")
            return
        }
        Task {
            let result = await controller.prepareProfile(profileID: uuid)
            reply(result.0, result.1)
        }
    }

    func startProfile(profileID: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let uuid = UUID(uuidString: profileID) else {
            reply(false, "无效的 profileID")
            return
        }
        Task {
            let result = await controller.startProfile(profileID: uuid)
            reply(result.0, result.1)
        }
    }

    func stopProfile(profileID: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let uuid = UUID(uuidString: profileID) else {
            reply(false, "无效的 profileID")
            return
        }
        Task {
            let result = await controller.stopProfile(profileID: uuid)
            reply(result.0, result.1)
        }
    }

    func restartProfile(profileID: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let uuid = UUID(uuidString: profileID) else {
            reply(false, "无效的 profileID")
            return
        }
        Task {
            let result = await controller.restartProfile(profileID: uuid)
            reply(result.0, result.1)
        }
    }

    func reloadProfiles(withReply reply: @escaping (Bool, String?) -> Void) {
        Task {
            let result = await controller.reloadProfiles()
            reply(result.0, result.1)
        }
    }
}
