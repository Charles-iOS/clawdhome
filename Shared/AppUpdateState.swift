import Foundation

struct AppUpdatePackage: Codable, Equatable {
    var url: String? = nil
    var sha256: String? = nil
    var size: Int64? = nil
}

struct AppUpdateState: Codable, Equatable {
    var latestVersion: String? = nil
    var latestBuild: String? = nil
    var downloadURL: String? = nil
    var downloadURLX64: String? = nil
    var selectedPackageURL: String? = nil
    var selectedPackageSHA256: String? = nil
    var releaseNotes: String? = nil
    var releaseNotesEn: String? = nil
    var minimumVersion: String? = nil
    var channel: String = "stable"
    var releaseDate: String? = nil
    var lastSuccessfulCheckAt: TimeInterval? = nil
    var lastHeartbeatAt: TimeInterval? = nil
    var lastError: String? = nil
    var source: String = "unknown"
    var packages: [String: AppUpdatePackage]? = nil

    enum CodingKeys: String, CodingKey {
        case latestVersion
        case latestBuild
        case downloadURL
        case downloadURLX64
        case selectedPackageURL
        case selectedPackageSHA256
        case releaseNotes
        case releaseNotesEn
        case minimumVersion
        case channel
        case releaseDate
        case lastSuccessfulCheckAt
        case lastHeartbeatAt
        case lastError
        case source
        case packages

        case version
        case build
        case downloadURLSnake = "download_url"
        case downloadURLX64Snake = "download_url_x64"
        case selectedPackageURLSnake = "selected_package_url"
        case selectedPackageSHA256Snake = "selected_package_sha256"
        case releaseNotesSnake = "release_notes"
        case releaseNotesEnSnake = "release_notes_en"
        case minimumVersionSnake = "min_version"
        case releaseDateSnake = "release_date"
        case lastSuccessfulCheckAtSnake = "last_successful_check_at"
        case lastHeartbeatAtSnake = "last_heartbeat_at"
        case lastErrorSnake = "last_error"
    }

    init(
        latestVersion: String? = nil,
        latestBuild: String? = nil,
        downloadURL: String? = nil,
        downloadURLX64: String? = nil,
        selectedPackageURL: String? = nil,
        selectedPackageSHA256: String? = nil,
        releaseNotes: String? = nil,
        releaseNotesEn: String? = nil,
        minimumVersion: String? = nil,
        channel: String = "stable",
        releaseDate: String? = nil,
        lastSuccessfulCheckAt: TimeInterval? = nil,
        lastHeartbeatAt: TimeInterval? = nil,
        lastError: String? = nil,
        source: String = "unknown",
        packages: [String: AppUpdatePackage]? = nil
    ) {
        self.latestVersion = latestVersion
        self.latestBuild = latestBuild
        self.downloadURL = downloadURL
        self.downloadURLX64 = downloadURLX64
        self.selectedPackageURL = selectedPackageURL
        self.selectedPackageSHA256 = selectedPackageSHA256
        self.releaseNotes = releaseNotes
        self.releaseNotesEn = releaseNotesEn
        self.minimumVersion = minimumVersion
        self.channel = channel
        self.releaseDate = releaseDate
        self.lastSuccessfulCheckAt = lastSuccessfulCheckAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastError = lastError
        self.source = source
        self.packages = packages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latestVersion = try container.decodeIfPresent(String.self, forKey: .latestVersion)
            ?? container.decodeIfPresent(String.self, forKey: .version)
        latestBuild = try container.decodeIfPresent(String.self, forKey: .latestBuild)
            ?? container.decodeIfPresent(String.self, forKey: .build)
        downloadURL = try container.decodeIfPresent(String.self, forKey: .downloadURL)
            ?? container.decodeIfPresent(String.self, forKey: .downloadURLSnake)
        downloadURLX64 = try container.decodeIfPresent(String.self, forKey: .downloadURLX64)
            ?? container.decodeIfPresent(String.self, forKey: .downloadURLX64Snake)
        selectedPackageURL = try container.decodeIfPresent(String.self, forKey: .selectedPackageURL)
            ?? container.decodeIfPresent(String.self, forKey: .selectedPackageURLSnake)
        selectedPackageSHA256 = try container.decodeIfPresent(String.self, forKey: .selectedPackageSHA256)
            ?? container.decodeIfPresent(String.self, forKey: .selectedPackageSHA256Snake)
        releaseNotes = try container.decodeIfPresent(String.self, forKey: .releaseNotes)
            ?? container.decodeIfPresent(String.self, forKey: .releaseNotesSnake)
        releaseNotesEn = try container.decodeIfPresent(String.self, forKey: .releaseNotesEn)
            ?? container.decodeIfPresent(String.self, forKey: .releaseNotesEnSnake)
        minimumVersion = try container.decodeIfPresent(String.self, forKey: .minimumVersion)
            ?? container.decodeIfPresent(String.self, forKey: .minimumVersionSnake)
        channel = try container.decodeIfPresent(String.self, forKey: .channel) ?? "stable"
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
            ?? container.decodeIfPresent(String.self, forKey: .releaseDateSnake)
        lastSuccessfulCheckAt = try container.decodeIfPresent(TimeInterval.self, forKey: .lastSuccessfulCheckAt)
            ?? container.decodeIfPresent(TimeInterval.self, forKey: .lastSuccessfulCheckAtSnake)
        lastHeartbeatAt = try container.decodeIfPresent(TimeInterval.self, forKey: .lastHeartbeatAt)
            ?? container.decodeIfPresent(TimeInterval.self, forKey: .lastHeartbeatAtSnake)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
            ?? container.decodeIfPresent(String.self, forKey: .lastErrorSnake)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "unknown"
        packages = try container.decodeIfPresent([String: AppUpdatePackage].self, forKey: .packages)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(latestVersion, forKey: .latestVersion)
        try container.encodeIfPresent(latestBuild, forKey: .latestBuild)
        try container.encodeIfPresent(downloadURL, forKey: .downloadURL)
        try container.encodeIfPresent(downloadURLX64, forKey: .downloadURLX64)
        try container.encodeIfPresent(selectedPackageURL, forKey: .selectedPackageURL)
        try container.encodeIfPresent(selectedPackageSHA256, forKey: .selectedPackageSHA256)
        try container.encodeIfPresent(releaseNotes, forKey: .releaseNotes)
        try container.encodeIfPresent(releaseNotesEn, forKey: .releaseNotesEn)
        try container.encodeIfPresent(minimumVersion, forKey: .minimumVersion)
        try container.encode(channel, forKey: .channel)
        try container.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try container.encodeIfPresent(lastSuccessfulCheckAt, forKey: .lastSuccessfulCheckAt)
        try container.encodeIfPresent(lastHeartbeatAt, forKey: .lastHeartbeatAt)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(packages, forKey: .packages)
    }
}

enum AppUpdateDownloadPhase: Equatable {
    case idle
    case checking
    case available
    case upToDate
    case downloading(progress: Double)
    case openingInstaller
    case awaitingRelaunch
    case failed(String)
}

enum AppVersionComparator {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = ParsedVersion(lhs)
        let right = ParsedVersion(rhs)

        for index in 0..<3 {
            let leftValue = left.components[index]
            let rightValue = right.components[index]
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }

        switch (left.isPrerelease, right.isPrerelease) {
        case (true, false):
            return .orderedAscending
        case (false, true):
            return .orderedDescending
        case (true, true):
            if left.prerelease < right.prerelease { return .orderedAscending }
            if left.prerelease > right.prerelease { return .orderedDescending }
            return .orderedSame
        case (false, false):
            return .orderedSame
        }
    }

    private struct ParsedVersion {
        let components: [Int]
        let prerelease: String

        var isPrerelease: Bool {
            !prerelease.isEmpty
        }

        init(_ rawValue: String) {
            var value = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            if value.hasPrefix("v") {
                value.removeFirst()
            }

            if let metadataRange = value.range(of: "+") {
                value = String(value[..<metadataRange.lowerBound])
            }

            var prereleaseValue = ""
            if let prereleaseRange = value.range(of: "-") {
                prereleaseValue = String(value[prereleaseRange.upperBound...])
                value = String(value[..<prereleaseRange.lowerBound])
            }

            var parsedComponents: [Int] = []
            for part in value.split(separator: ".").prefix(3) {
                let digits = part.prefix { $0.isNumber }
                if digits.count < part.count, prereleaseValue.isEmpty {
                    prereleaseValue = String(part.dropFirst(digits.count))
                }
                parsedComponents.append(Int(digits) ?? 0)
            }

            while parsedComponents.count < 3 {
                parsedComponents.append(0)
            }

            components = parsedComponents
            prerelease = prereleaseValue
        }
    }
}
