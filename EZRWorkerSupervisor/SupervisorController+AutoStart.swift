import Foundation

extension EZRWorkerSupervisorController {
    func reconcileLaunchState() async {
        let removedRecords = loadProfilesFromDisk()
        for record in removedRecords {
            inFlightStartTasks[record.profile.id]?.cancel()
            inFlightStartTasks.removeValue(forKey: record.profile.id)
            _ = await stopRecord(record)
        }
        scheduleAutoStartReconcile()
    }

    func scheduleAutoStartReconcile() {
        needsAutoStartReconcile = true
        guard !isReconcilingAutoStart else { return }

        Task {
            await self.processPendingAutoStartReconcile()
        }
    }

    func processPendingAutoStartReconcile() async {
        guard !isReconcilingAutoStart else { return }
        isReconcilingAutoStart = true
        defer { isReconcilingAutoStart = false }

        while needsAutoStartReconcile {
            needsAutoStartReconcile = false
            await reconcileAutoStartProfiles()
        }
    }

    func reconcileAutoStartProfiles() async {
        for profileID in profileOrder {
            guard let profile = profiles[profileID], profile.autoStart else { continue }
            guard persistentDesiredState(for: profileID) != .stopped else { continue }
            _ = await startProfile(profileID: profileID)
        }
    }
}
