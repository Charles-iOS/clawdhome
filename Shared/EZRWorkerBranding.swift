import Foundation

enum EZRWorkerBuildFlavor {
    #if DEBUG
    static let isDev = true
    #else
    static let isDev = false
    #endif
}

enum EZRWorkerBranding {
    #if DEBUG
    static let appName = "EZRWorker Dev"
    static let appBundleIdentifier = "ai.ezrworker.mac.dev"
    static let supervisorMachServiceName = "ai.ezrworker.mac.dev.supervisor"
    static let supervisorLaunchAgentLabel = "ai.ezrworker.mac.dev.supervisor"
    static let helperMachServiceName = "ai.ezrworker.mac.dev.helper"
    static let osLogSubsystem = "ai.ezrworker.mac.dev"
    static let userAgentPrefix = "EZRWorkerDev"

    static let providerKeychainService = "ai.ezrworker.mac.dev"

    static let accountKeychainService = "ai.ezrworker.mac.dev.accounts"

    static let userPasswordKeychainService = "ai.ezrworker.mac.dev.user-pw"

    static let appLockKeychainService = "ai.ezrworker.mac.dev.applock"
    static let appLockEnabledDefaultsKey = "ai.ezrworker.mac.dev.applock.enabled"

    static let lastSelectedProfileDefaultsKey = "ai.ezrworker.mac.dev.lastSelectedProfileID"

    static let applicationSupportDirectoryName = "EZRWorker-Dev"
    #else
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
    #endif
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

    static var openClawPluginStageDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent("openclaw", isDirectory: true)
            .appendingPathComponent("plugin-runtime-deps", isDirectory: true)
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
        try? fm.createDirectory(
            at: openClawPluginStageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
