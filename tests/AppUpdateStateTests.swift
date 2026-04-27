import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct AppUpdateStateTests {
    static func main() {
        let legacyJSON = """
        {"latestVersion":"1.5.0","downloadURL":"https://example.com/app.pkg","releaseNotes":"notes","minimumVersion":"1.4.0","lastSuccessfulCheckAt":1234,"lastHeartbeatAt":1234,"lastError":null,"source":"helper"}
        """
        let legacyData = Data(legacyJSON.utf8)
        let legacy = try! JSONDecoder().decode(AppUpdateState.self, from: legacyData)
        expect(legacy.latestVersion == "1.5.0", "should decode legacy latest version")
        expect(legacy.downloadURL == "https://example.com/app.pkg", "should decode legacy download URL")
        expect(legacy.minimumVersion == "1.4.0", "should decode legacy minimum version")
        expect(legacy.source == "helper", "should decode legacy source")

        let manifestJSON = """
        {
          "version": "1.7.0",
          "build": "620",
          "min_version": "1.5.0",
          "channel": "stable",
          "release_date": "2026-04-25T10:00:00Z",
          "release_notes": "中文更新说明",
          "release_notes_en": "English release notes",
          "download_url": "https://example.com/download/EZRWorker-1.7.0-arm64.pkg",
          "download_url_x64": "https://example.com/download/EZRWorker-1.7.0-x64.pkg",
          "packages": {
            "arm64": {
              "url": "https://example.com/download/EZRWorker-1.7.0-arm64.pkg",
              "sha256": "arm64sum"
            },
            "x86_64": {
              "url": "https://example.com/download/EZRWorker-1.7.0-x64.pkg",
              "sha256": "x64sum"
            }
          }
        }
        """
        let manifest = try! JSONDecoder().decode(AppUpdateState.self, from: Data(manifestJSON.utf8))
        expect(manifest.latestVersion == "1.7.0", "should decode manifest version")
        expect(manifest.latestBuild == "620", "should decode manifest build")
        expect(manifest.downloadURLX64?.contains("x64.pkg") == true, "should decode x64 URL")
        expect(manifest.releaseNotesEn == "English release notes", "should decode English release notes")
        expect(manifest.packages?["arm64"]?.sha256 == "arm64sum", "should decode arm64 checksum")
        expect(manifest.packages?["x86_64"]?.url?.contains("x64.pkg") == true, "should decode x86_64 package URL")

        expect(AppVersionComparator.compare("1.6", "1.6.0") == .orderedSame, "1.6 should equal 1.6.0")
        expect(AppVersionComparator.compare("v1.6.0", "1.6.0") == .orderedSame, "v prefix should be ignored")
        expect(AppVersionComparator.compare("1.6.1", "1.6.0") == .orderedDescending, "patch should compare numerically")
        expect(AppVersionComparator.compare("1.6.0-beta", "1.6.0") == .orderedAscending, "prerelease should sort below release")
        expect(AppVersionComparator.compare("1.6.0+620", "1.6.0+619") == .orderedSame, "build metadata should be ignored")

        print("App update state tests passed.")
    }
}
