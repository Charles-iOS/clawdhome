import Foundation

extension EZRWorkerSupervisorController {
    func reloadProfiles() async -> (Bool, String?) {
        let removedRecords = loadProfilesFromDisk()
        for record in removedRecords {
            inFlightStartTasks[record.profile.id]?.cancel()
            inFlightStartTasks.removeValue(forKey: record.profile.id)
            _ = await stopRecord(record)
        }
        return (true, nil)
    }

    @discardableResult
    func loadProfilesFromDisk() -> [SupervisorRecord] {
        guard let document = Self.readProfilesDocumentFromDisk() else {
            let removedRecords = Array(records.values)
            profiles = [:]
            profileOrder = []
            records = [:]
            return removedRecords
        }

        let orderedProfiles = Self.sortedProfiles(from: document)
        profiles = Dictionary(uniqueKeysWithValues: orderedProfiles.map { ($0.id, $0) })
        profileOrder = orderedProfiles.map(\.id)

        for profile in orderedProfiles {
            let record = records[profile.id] ?? SupervisorRecord(profile: profile)
            record.apply(profile: profile)
            applyPersistentRuntimeState(to: record)
            records[profile.id] = record
        }

        let knownIDs = Set(orderedProfiles.map(\.id))
        var removedRecords: [SupervisorRecord] = []
        for recordID in Array(records.keys) where !knownIDs.contains(recordID) {
            if let record = records.removeValue(forKey: recordID) {
                restartHandoffTimestamps.removeValue(forKey: recordID)
                removePersistentRuntimeState(for: recordID)
                removedRecords.append(record)
            }
        }
        return removedRecords
    }

    static func readProfilesDocumentFromDisk() -> GatewayProfilesDocument? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: EZRWorkerPaths.profilesDocumentURL),
              let document = try? decoder.decode(GatewayProfilesDocument.self, from: data)
        else {
            return nil
        }
        return document
    }

    static func sortedProfiles(from document: GatewayProfilesDocument) -> [GatewayProfile] {
        document.profiles.sorted(by: { $0.createdAt < $1.createdAt })
    }

    func recordForProfile(_ profile: GatewayProfile) -> SupervisorRecord {
        if let existing = records[profile.id] {
            existing.apply(profile: profile)
            applyPersistentRuntimeState(to: existing)
            return existing
        }
        let created = SupervisorRecord(profile: profile)
        applyPersistentRuntimeState(to: created)
        records[profile.id] = created
        return created
    }
}
