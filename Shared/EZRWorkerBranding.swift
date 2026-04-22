import Foundation

enum EZRWorkerBranding {
    static let appName = "EZRWorker"
    static let appBundleIdentifier = "ai.ezrworker.mac"
    static let supervisorMachServiceName = "ai.ezrworker.mac.supervisor"
    static let supervisorLaunchAgentLabel = "ai.ezrworker.mac.supervisor"
    static let helperMachServiceName = "ai.ezrworker.mac.helper"
    static let osLogSubsystem = "ai.ezrworker.mac"
    static let userAgentPrefix = "EZRWorker"

    static let providerKeychainService = "ai.ezrworker.mac"

    static let accountKeychainService = "ai.ezrworker.mac.accounts"

    static let userPasswordKeychainService = "ai.ezrworker.mac.user-pw"

    static let appLockKeychainService = "ai.ezrworker.mac.applock"
    static let appLockEnabledDefaultsKey = "ai.ezrworker.mac.applock.enabled"

    static let lastSelectedProfileDefaultsKey = "ai.ezrworker.mac.lastSelectedProfileID"

    static let applicationSupportDirectoryName = "EZRWorker"
}

enum EZRWorkerPaths {
    static var userApplicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    static var applicationSupportDirectory: URL {
        userApplicationSupportDirectory
            .appendingPathComponent(EZRWorkerBranding.applicationSupportDirectoryName, isDirectory: true)
    }

    static var profilesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("profiles", isDirectory: true)
    }

    static var profilesDocumentURL: URL {
        applicationSupportDirectory.appendingPathComponent("profiles.json")
    }

    static func managedProfileRoot(slug: String) -> URL {
        profilesDirectory.appendingPathComponent(slug, isDirectory: true)
    }

    static var legacyOpenClawDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw", isDirectory: true)
    }

    static var legacyOpenClawConfigURL: URL {
        legacyOpenClawDirectory.appendingPathComponent("openclaw.json")
    }

    static var supervisorLaunchAgentInstallURL: URL {
        URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(EZRWorkerBranding.supervisorLaunchAgentLabel).plist")
    }

    static func ensureApplicationSupportDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fm.createDirectory(
            at: profilesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
