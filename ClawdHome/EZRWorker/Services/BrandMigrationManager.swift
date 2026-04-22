import Foundation

@MainActor
final class BrandMigrationManager {
    private var didRun = false

    func migrateIfNeeded() {
        guard !didRun else { return }
        didRun = true

        let fm = FileManager.default
        let legacyDirectory = EZRWorkerPaths.legacyApplicationSupportDirectory
        let newDirectory = EZRWorkerPaths.applicationSupportDirectory

        guard fm.fileExists(atPath: legacyDirectory.path) else { return }
        EZRWorkerPaths.ensureApplicationSupportDirectories()

        for filename in EZRWorkerBranding.appStateFilesToMigrate {
            let legacyURL = legacyDirectory.appendingPathComponent(filename)
            let newURL = newDirectory.appendingPathComponent(filename)
            guard fm.fileExists(atPath: legacyURL.path) else { continue }
            guard !fm.fileExists(atPath: newURL.path) else { continue }
            try? fm.copyItem(at: legacyURL, to: newURL)
        }
    }
}
