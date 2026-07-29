import EasyTierShared
import Foundation
import Testing

@Test func remoteAccountCredentialStoreRoundTripsAndRemovesSecret() throws {
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

    try store.save(credential)
    #expect(try store.load() == credential)
    let attributes = try FileManager.default.attributesOfItem(
        atPath: directory.appending(path: "credential.json").path
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    try store.remove()
    #expect(try store.load() == nil)
}

@Test func remoteAccountCredentialStoreRejectsSymlinkDestination() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "RemoteAccountCredentialStoreSymlinkTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appending(path: "target")
    _ = FileManager.default.createFile(atPath: target.path, contents: Data())
    try FileManager.default.createSymbolicLink(
        at: directory.appending(path: "credential.json"),
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
