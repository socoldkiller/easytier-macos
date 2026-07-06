import Foundation
import Testing
@testable import EasyTierShared

@Test func updateManifestDecodesStableFeed() throws {
    let manifest = try decodeManifest()

    #expect(manifest.schemaVersion == 1)
    #expect(manifest.channel == "stable")
    #expect(manifest.version == "0.2.0")
    #expect(manifest.assets["arm64"]?.size == 123_456)
    #expect(manifest.releaseNotesURL.absoluteString == "https://github.com/socoldkiller/easytier-macos/releases/tag/v0.2.0")
}

@Test func updateManifestRejectsMissingRequiredFields() {
    let json = """
    {
      "schemaVersion": 1,
      "channel": "stable",
      "version": "0.2.0"
    }
    """

    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(EasyTierUpdateManifest.self, from: Data(json.utf8))
    }
}

@Test func updateSelectorRejectsUnsupportedSchema() throws {
    var manifest = try decodeManifest()
    manifest.schemaVersion = 2

    #expect(throws: EasyTierUpdateSelectionError.unsupportedSchema(2)) {
        _ = try EasyTierUpdateSelector.availableUpdate(
            in: manifest,
            currentVersion: "0.1.0",
            currentBuild: "20260101000000",
            currentSystemVersion: "14.0",
            architecture: "arm64"
        )
    }
}

@Test func updateSelectorRejectsUnsupportedSystemVersion() throws {
    var manifest = try decodeManifest()
    manifest.minimumSystemVersion = "15.0"

    #expect(throws: EasyTierUpdateSelectionError.unsupportedSystem(required: "15.0", current: "14.0")) {
        _ = try EasyTierUpdateSelector.availableUpdate(
            in: manifest,
            currentVersion: "0.1.0",
            currentBuild: "20260101000000",
            currentSystemVersion: "14.0",
            architecture: "arm64"
        )
    }
}

@Test func updateSelectorRejectsMissingArchitectureAsset() throws {
    let manifest = try decodeManifest()

    #expect(throws: EasyTierUpdateSelectionError.missingAsset(architecture: "x86_64")) {
        _ = try EasyTierUpdateSelector.availableUpdate(
            in: manifest,
            currentVersion: "0.1.0",
            currentBuild: "20260101000000",
            currentSystemVersion: "14.0",
            architecture: "x86_64"
        )
    }
}

@Test func updateSelectorUsesSemanticVersionOrdering() {
    #expect(EasyTierUpdateSelector.isRemoteNewer(
        remoteVersion: "0.2.0",
        remoteBuild: "20260101000000",
        currentVersion: "0.1.0",
        currentBuild: "20260101000000"
    ))
    #expect(!EasyTierUpdateSelector.isRemoteNewer(
        remoteVersion: "0.1.0",
        remoteBuild: "20260101000000",
        currentVersion: "0.2.0",
        currentBuild: "20260101000000"
    ))
    #expect(!EasyTierUpdateSelector.isRemoteNewer(
        remoteVersion: "1.0.0",
        remoteBuild: "20260101000000",
        currentVersion: "1.0.0",
        currentBuild: "20260101000000"
    ))
}

@Test func updateSelectorFallsBackToBuildWhenVersionsAreEqualOrMalformed() {
    #expect(EasyTierUpdateSelector.isRemoteNewer(
        remoteVersion: "1.0.0",
        remoteBuild: "20260102000000",
        currentVersion: "1.0.0",
        currentBuild: "20260101000000"
    ))
    #expect(EasyTierUpdateSelector.isRemoteNewer(
        remoteVersion: "Development",
        remoteBuild: "20260102000000",
        currentVersion: "Development",
        currentBuild: "20260101000000"
    ))
    #expect(!EasyTierUpdateSelector.isRemoteNewer(
        remoteVersion: "Development",
        remoteBuild: "local",
        currentVersion: "Development",
        currentBuild: "20260101000000"
    ))
}

@Test func sha256VerifierMatchesFixtureFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("fixture.txt")
    try Data("EasyTier updater\n".utf8).write(to: fileURL)

    let digest = try EasyTierSHA256.hexDigest(for: fileURL)

    #expect(digest == "f0f906d3d8454c2e978b333a283bd5851177e427b510b2e2eafcb3fc3e2731a6")
    #expect(try EasyTierSHA256.file(fileURL, matches: digest.uppercased()))
    #expect(try !EasyTierSHA256.file(fileURL, matches: String(repeating: "0", count: 64)))
}

@Test func updateFeedRequestBypassesCaches() throws {
    let url = try #require(URL(string: "https://socoldkiller.github.io/easytier-macos/update.json"))
    let request = EasyTierUpdateFeedRequest.request(for: url)

    #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
}

@Test func skipPolicyPresentsUpdateWhenNoVersionSkipped() throws {
    let update = try makeUpdate(version: "0.2.0")

    #expect(EasyTierUpdateSkipPolicy.shouldPresent(update: update, skippedVersion: nil))
    #expect(EasyTierUpdateSkipPolicy.shouldPresent(update: update, skippedVersion: "0.1.0"))
}

@Test func skipPolicySuppressesUpdateMatchingSkippedVersion() throws {
    let update = try makeUpdate(version: "0.2.0")

    #expect(!EasyTierUpdateSkipPolicy.shouldPresent(update: update, skippedVersion: "0.2.0"))
}

@Test func autoCheckPolicyAllowsFirstCheck() {
    #expect(EasyTierUpdateSkipPolicy.shouldAutoCheck(
        lastCheckDate: nil,
        now: Date(),
        minimumInterval: 60 * 60 * 24
    ))
}

@Test func autoCheckPolicyThrottlesWithinInterval() {
    let now = Date()
    let recent = now.addingTimeInterval(-60 * 60)

    #expect(!EasyTierUpdateSkipPolicy.shouldAutoCheck(
        lastCheckDate: recent,
        now: now,
        minimumInterval: 60 * 60 * 24
    ))
}

@Test func autoCheckPolicyAllowsAfterIntervalElapses() {
    let now = Date()
    let stale = now.addingTimeInterval(-(60 * 60 * 24 + 60))

    #expect(EasyTierUpdateSkipPolicy.shouldAutoCheck(
        lastCheckDate: stale,
        now: now,
        minimumInterval: 60 * 60 * 24
    ))
}

private func makeUpdate(version: String) throws -> EasyTierAvailableUpdate {
    EasyTierAvailableUpdate(
        version: version,
        build: "20260615123000",
        tag: "v\(version)",
        releaseNotesURL: try #require(URL(string: "https://github.com/socoldkiller/easytier-macos/releases/tag/v\(version)")),
        architecture: "arm64",
        asset: EasyTierUpdateAsset(
            url: try #require(URL(string: "https://example.com/EasyTier.dmg")),
            sha256: String(repeating: "a", count: 64),
            size: 123_456
        )
    )
}

private func decodeManifest() throws -> EasyTierUpdateManifest {
    let json = """
    {
      "schemaVersion": 1,
      "channel": "stable",
      "version": "0.2.0",
      "build": "20260615123000",
      "tag": "v0.2.0",
      "minimumSystemVersion": "14.0",
      "releaseNotesURL": "https://github.com/socoldkiller/easytier-macos/releases/tag/v0.2.0",
      "assets": {
        "arm64": {
          "url": "https://github.com/socoldkiller/easytier-macos/releases/download/v0.2.0/EasyTier-macOS-ARM64.dmg",
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "size": 123456
        }
      }
    }
    """
    return try JSONDecoder().decode(EasyTierUpdateManifest.self, from: Data(json.utf8))
}
