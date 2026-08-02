import EasyTierShared
import Foundation
import Testing

@Test func remoteAccountCredentialStoreRoundTripsMultipleCredentialsAndRemovesFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "RemoteAccountCredentialStoreTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RemoteAccountCredentialStore(
        baseDirectory: directory,
        requiresRootOwnership: false
    )
    let credential = RemoteAccountCredential(
        endpoint: "tcp://iw.example.com:22020",
        token: "etu1.42.signature",
        machineID: UUID(),
        deviceName: "Test Mac"
    )
    let firstID = RemoteAccountID()
    let secondID = RemoteAccountID()
    let library = RemoteAccountCredentialLibrary(
        activeAccountID: secondID,
        records: [
            RemoteAccountCredentialRecord(accountID: firstID, credential: credential),
            RemoteAccountCredentialRecord(
                accountID: secondID,
                credential: RemoteAccountCredential(
                    endpoint: "tcp://second.example.com:22020",
                    token: "second-token",
                    machineID: credential.machineID,
                    deviceName: credential.deviceName
                )
            ),
        ]
    )

    try store.save(library)
    #expect(try store.load() == library)
    let attributes = try FileManager.default.attributesOfItem(
        atPath: directory.appending(path: "credential-library.json").path
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    try store.remove()
    #expect(try store.load() == RemoteAccountCredentialLibrary())
}

@Test func remoteAccountCredentialStoreDestructivelyRemovesDeprecatedCredential() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "RemoteAccountCredentialStoreLegacyTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credential = RemoteAccountCredential(
        endpoint: "tcp://legacy.example.com:22020",
        token: "legacy-token",
        machineID: UUID(),
        deviceName: "Legacy Mac"
    )
    let url = directory.appending(path: "credential.json")
    try JSONEncoder().encode(credential).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let store = RemoteAccountCredentialStore(baseDirectory: directory, requiresRootOwnership: false)

    #expect(try store.load() == RemoteAccountCredentialLibrary())
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func remoteAccountCredentialStoreRejectsSymlinkDestination() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "RemoteAccountCredentialStoreSymlinkTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appending(path: "target")
    _ = FileManager.default.createFile(atPath: target.path, contents: Data())
    try FileManager.default.createSymbolicLink(
        at: directory.appending(path: "credential-library.json"),
        withDestinationURL: target
    )
    let store = RemoteAccountCredentialStore(
        baseDirectory: directory,
        requiresRootOwnership: false
    )

    #expect(throws: RemoteAccountCredentialStoreError.self) {
        _ = try store.load()
    }
}
