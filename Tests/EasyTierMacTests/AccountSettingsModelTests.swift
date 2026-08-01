@testable import EasyTierMac
import EasyTierShared
import Foundation
import Testing

@MainActor
@Test func accountSignInConfiguresHelperBeforeSavingMetadata() async throws {
    let fixture = try AccountModelFixture()
    defer { fixture.removeFiles() }
    let result = BrowserSSOSignIn(
        username: "oidc-admin",
        configToken: "oidc-admin",
        configEndpoint: "tcp://iw.example.com:22020",
        controlOrigin: try #require(URL(string: "https://iw.example.com")),
        consoleURL: try #require(URL(string: "https://iw.example.com/native/console"))
    )
    let runtime = AccountRuntimeStub()
    var authority = NetworkConfigurationAuthority.local
    let model = fixture.makeModel(
        browserSSO: BrowserSSOStub(result: result),
        runtime: runtime,
        configurationAuthorityDidChange: { authority = $0 }
    )

    model.serverAddress = "https://iw.example.com"
    model.beginSignIn()
    try await waitUntil { model.account != nil }

    let credential = await runtime.configuredCredential
    #expect(credential?.token == result.configToken)
    #expect(credential?.endpoint == result.configEndpoint)
    #expect(model.account?.username == "oidc-admin")
    #expect(try await fixture.database.loadRemoteAccount() == model.account)
    #expect(authority == .configServer)
}

@MainActor
@Test func failedHelperConfigurationDoesNotCreateAccount() async throws {
    let fixture = try AccountModelFixture()
    defer { fixture.removeFiles() }
    let result = BrowserSSOSignIn(
        username: "oidc-admin",
        configToken: "oidc-admin",
        configEndpoint: "tcp://iw.example.com:22020",
        controlOrigin: try #require(URL(string: "https://iw.example.com")),
        consoleURL: try #require(URL(string: "https://iw.example.com/native/console"))
    )
    let runtime = AccountRuntimeStub(configureError: AccountModelTestError.expected)
    let model = fixture.makeModel(browserSSO: BrowserSSOStub(result: result), runtime: runtime)

    model.serverAddress = "https://iw.example.com"
    model.beginSignIn()
    try await waitUntil { model.phase == .failed }

    #expect(model.account == nil)
    #expect(try await fixture.database.loadRemoteAccount() == nil)
}

@MainActor
@Test func failedHelperRemovalPreservesAccountMetadata() async throws {
    let fixture = try AccountModelFixture()
    defer { fixture.removeFiles() }
    let profile = try fixture.profile()
    try await fixture.database.saveRemoteAccount(profile)
    let runtime = AccountRuntimeStub(removeError: AccountModelTestError.expected)
    let model = fixture.makeModel(browserSSO: BrowserSSOStub(error: AccountModelTestError.expected), runtime: runtime)
    await model.load()

    await model.logOut()

    #expect(model.account == profile)
    #expect(try await fixture.database.loadRemoteAccount() == profile)
    #expect(model.phase == .failed)
}

@MainActor
@Test func successfulLogOutDisconnectsRuntimeWithoutDeletingAccount() async throws {
    let fixture = try AccountModelFixture()
    defer { fixture.removeFiles() }
    let profile = try fixture.profile()
    try await fixture.database.saveRemoteAccount(profile)
    let runtime = AccountRuntimeStub()
    try await runtime.configureRemoteAccount(RemoteAccountCredential(
        endpoint: profile.configEndpoint,
        token: "saved-token",
        machineID: profile.machineID,
        deviceName: "Test Mac"
    ))
    var authority = NetworkConfigurationAuthority.local
    let model = fixture.makeModel(
        browserSSO: BrowserSSOStub(error: AccountModelTestError.expected),
        runtime: runtime,
        configurationAuthorityDidChange: { authority = $0 }
    )
    await model.load()
    #expect(authority == .configServer)

    await model.logOut()

    #expect(await runtime.removeCallCount == 1)
    #expect(model.account == profile)
    #expect(try await fixture.database.loadRemoteAccount() == profile)
    #expect(model.phase == .signedOut)
    #expect(authority == .local)
}

@MainActor
@Test func machineIDIsStableAcrossSignIns() async throws {
    let fixture = try AccountModelFixture()
    defer { fixture.removeFiles() }
    let result = BrowserSSOSignIn(
        username: "oidc-admin",
        configToken: "oidc-admin",
        configEndpoint: "tcp://iw.example.com:22020",
        controlOrigin: try #require(URL(string: "https://iw.example.com")),
        consoleURL: try #require(URL(string: "https://iw.example.com/native/console"))
    )
    let firstRuntime = AccountRuntimeStub()
    let first = fixture.makeModel(browserSSO: BrowserSSOStub(result: result), runtime: firstRuntime)
    first.serverAddress = "https://iw.example.com"
    first.beginSignIn()
    try await waitUntil { first.account != nil }
    let firstID = try #require(first.account?.machineID)

    let secondRuntime = AccountRuntimeStub()
    let second = fixture.makeModel(browserSSO: BrowserSSOStub(result: result), runtime: secondRuntime)
    second.serverAddress = "https://iw.example.com"
    second.beginSignIn()
    try await waitUntil { second.account != nil }

    #expect(second.account?.machineID == firstID)
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw AccountModelTestError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private enum AccountModelTestError: Error {
    case expected
    case timedOut
}

private struct BrowserSSOStub: BrowserSSOAuthenticating {
    let result: BrowserSSOSignIn?
    let error: (any Error & Sendable)?

    init(result: BrowserSSOSignIn) {
        self.result = result
        error = nil
    }

    init(error: any Error & Sendable) {
        result = nil
        self.error = error
    }

    func signIn(serverAddress _: String) throws -> BrowserSSOSignIn {
        if let error { throw error }
        return try #require(result)
    }
}

private actor AccountRuntimeStub: RemoteAccountRuntimeClient {
    private(set) var configuredCredential: RemoteAccountCredential?
    private(set) var removeCallCount = 0
    private let configureError: (any Error & Sendable)?
    private let removeError: (any Error & Sendable)?

    init(
        configureError: (any Error & Sendable)? = nil,
        removeError: (any Error & Sendable)? = nil
    ) {
        self.configureError = configureError
        self.removeError = removeError
    }

    func configureRemoteAccount(_ credential: RemoteAccountCredential) throws {
        if let configureError { throw configureError }
        configuredCredential = credential
    }

    func removeRemoteAccount() throws {
        if let removeError { throw removeError }
        removeCallCount += 1
        configuredCredential = nil
    }

    func remoteAccountStatus() throws -> RemoteRuntimeStatus {
        RemoteRuntimeStatus(active: configuredCredential != nil, connected: configuredCredential != nil)
    }
}

private final class AccountModelFixture: @unchecked Sendable {
    let directory: URL
    let database: ApplicationDatabase
    let userDefaults: UserDefaults
    private let suiteName: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "account-model-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "AccountSettingsModelTests.\(UUID().uuidString)"
        userDefaults = try #require(UserDefaults(suiteName: suiteName))
        database = ApplicationDatabase(
            baseDirectory: directory,
            gatewayFileURL: directory.appending(path: "gateway/config.json"),
            networkSecretStore: AccountModelNetworkSecretStore()
        )
    }

    @MainActor
    func makeModel(
        browserSSO: any BrowserSSOAuthenticating,
        runtime: any RemoteAccountRuntimeClient,
        configurationAuthorityDidChange: @escaping @MainActor (NetworkConfigurationAuthority) -> Void = { _ in }
    ) -> AccountSettingsModel {
        AccountSettingsModel(
            database: database,
            browserSSO: browserSSO,
            runtime: runtime,
            userDefaults: userDefaults,
            configurationAuthorityDidChange: configurationAuthorityDidChange
        )
    }

    func profile() throws -> RemoteAccountProfile {
        RemoteAccountProfile(
            controlOrigin: try #require(URL(string: "https://iw.example.com")),
            configEndpoint: "tcp://iw.example.com:22020",
            consoleURL: try #require(URL(string: "https://iw.example.com/native/console")),
            username: "oidc-admin",
            machineID: UUID()
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

}

private struct AccountModelNetworkSecretStore: NetworkSecretStore {
    func save(_: String, for _: NetworkConfig, purpose _: NetworkSecretAccessPurpose) throws {}
    func secret(
        for _: NetworkConfig,
        purpose _: NetworkSecretAccessPurpose,
        reason _: String?
    ) throws -> String? { nil }
    func deleteSecret(for _: NetworkConfig, purpose _: NetworkSecretAccessPurpose) throws {}
    func presence(for _: NetworkConfig) throws -> NetworkSecretPresence { .missing }
    func authenticationCapability() -> NetworkSecretAuthenticationCapability { .unknown }
    func invalidateAuthenticationSession() {}
}
