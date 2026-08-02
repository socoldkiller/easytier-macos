@testable import EasyTierMac
import EasyTierShared
import Foundation
import Testing

@MainActor
@Test func addingAccountPersistsAndImmediatelyActivatesIt() async throws {
    let fixture = try AccountModelFixture()
    defer { fixture.removeFiles() }
    let result = try fixture.signIn(username: "oidc-admin", host: "iw.example.com")
    let runtime = AccountRuntimeStub()
    var authority = NetworkConfigurationAuthority.local
    let model = fixture.makeModel(
        browserSSO: BrowserSSOStub(result: result),
        runtime: runtime,
        configurationAuthorityDidChange: { authority = $0 }
    )

    model.beginSignIn(serverAddress: result.controlOrigin.absoluteString)
    try await waitUntil { model.operation == nil && model.activeAccount != nil }

    let account = try #require(model.activeAccount)
    #expect(account.profile.username == result.username)
    #expect(await runtime.activeAccountID == account.id)
    #expect(await runtime.credential(for: account.id)?.token == result.configToken)
    #expect(try await fixture.database.loadRemoteAccounts() == [account])
    #expect(authority == .configServer)
}

@MainActor
@Test func duplicateIdentityUpdatesExistingAccountInsteadOfAddingAnother() async throws {
    let fixture = try AccountModelFixture()
    defer { fixture.removeFiles() }
    let original = try fixture.account(username: "operator", host: "control.example.com")
    _ = try await fixture.database.upsertRemoteAccount(original)
    let result = BrowserSSOSignIn(
        username: original.profile.username,
        configToken: "new-token",
        configEndpoint: "tcp://control.example.com:33030",
        controlOrigin: original.profile.controlOrigin,
        consoleURL: try #require(URL(string: "https://control.example.com/new-console"))
    )
    let runtime = AccountRuntimeStub()
    let model = fixture.makeModel(browserSSO: BrowserSSOStub(result: result), runtime: runtime)
    await model.load()

    model.beginSignIn(serverAddress: result.controlOrigin.absoluteString)
    try await waitUntil { model.operation == nil && model.activeAccountID != nil }

    let accounts = try await fixture.database.loadRemoteAccounts()
    #expect(accounts.count == 1)
    #expect(accounts[0].id == original.id)
    #expect(accounts[0].deviceBinding.configEndpoint == result.configEndpoint)
}

@MainActor
@Test func selectingDoesNotActivateAndExplicitActivationSwitchesAccount() async throws {
    let fixture = try AccountModelFixture()
    defer { fixture.removeFiles() }
    let first = try fixture.account(username: "first", host: "first.example.com")
    let second = try fixture.account(username: "second", host: "second.example.com")
    _ = try await fixture.database.upsertRemoteAccount(first)
    _ = try await fixture.database.upsertRemoteAccount(second)
    let runtime = AccountRuntimeStub(credentials: [
        first.id: fixture.credential(for: first, token: "first-token"),
        second.id: fixture.credential(for: second, token: "second-token"),
    ], activeAccountID: first.id)
    let model = fixture.makeModel(
        browserSSO: BrowserSSOStub(error: AccountModelTestError.expected),
        runtime: runtime
    )
    await model.load()

    #expect(model.activeAccountID == first.id)
    await model.activate(accountID: second.id)

    #expect(model.activeAccountID == second.id)
    #expect(await runtime.activeAccountID == second.id)
    #expect(model.accounts.count == 2)
}

@MainActor
@Test func failedActivationPreservesPreviousAccountAndSession() async throws {
    let fixture = try AccountModelFixture()
    defer { fixture.removeFiles() }
    let first = try fixture.account(username: "first", host: "first.example.com")
    let second = try fixture.account(username: "second", host: "second.example.com")
    _ = try await fixture.database.upsertRemoteAccount(first)
    _ = try await fixture.database.upsertRemoteAccount(second)
    let runtime = AccountRuntimeStub(
        credentials: [
            first.id: fixture.credential(for: first, token: "first-token"),
            second.id: fixture.credential(for: second, token: "second-token"),
        ],
        activeAccountID: first.id,
        activateError: AccountModelTestError.expected
    )
    let model = fixture.makeModel(
        browserSSO: BrowserSSOStub(error: AccountModelTestError.expected),
        runtime: runtime
    )
    await model.load()

    await model.activate(accountID: second.id)

    #expect(model.activeAccountID == first.id)
    #expect(await runtime.activeAccountID == first.id)
    #expect(model.errorMessage != nil)
}

@MainActor
@Test func logoutRemovesOnlyCredentialAndKeepsMetadata() async throws {
    let fixture = try AccountModelFixture()
    defer { fixture.removeFiles() }
    let first = try fixture.account(username: "first", host: "first.example.com")
    let second = try fixture.account(username: "second", host: "second.example.com")
    _ = try await fixture.database.upsertRemoteAccount(first)
    _ = try await fixture.database.upsertRemoteAccount(second)
    let runtime = AccountRuntimeStub(credentials: [
        first.id: fixture.credential(for: first, token: "first-token"),
        second.id: fixture.credential(for: second, token: "second-token"),
    ], activeAccountID: first.id)
    let model = fixture.makeModel(
        browserSSO: BrowserSSOStub(error: AccountModelTestError.expected),
        runtime: runtime
    )
    await model.load()

    await model.logOut(accountID: first.id)

    #expect(model.activeAccountID == nil)
    #expect(!model.credentialAccountIDs.contains(first.id))
    #expect(model.credentialAccountIDs.contains(second.id))
    #expect(try await fixture.database.loadRemoteAccounts().count == 2)
}

@MainActor
@Test func forgettingInactiveAccountLeavesActiveAccountUntouched() async throws {
    let fixture = try AccountModelFixture()
    defer { fixture.removeFiles() }
    let first = try fixture.account(username: "first", host: "first.example.com")
    let second = try fixture.account(username: "second", host: "second.example.com")
    _ = try await fixture.database.upsertRemoteAccount(first)
    _ = try await fixture.database.upsertRemoteAccount(second)
    let runtime = AccountRuntimeStub(credentials: [
        first.id: fixture.credential(for: first, token: "first-token"),
        second.id: fixture.credential(for: second, token: "second-token"),
    ], activeAccountID: first.id)
    let model = fixture.makeModel(
        browserSSO: BrowserSSOStub(error: AccountModelTestError.expected),
        runtime: runtime
    )
    await model.load()

    await model.forgetAccount(accountID: second.id)

    #expect(model.activeAccountID == first.id)
    #expect(await runtime.activeAccountID == first.id)
    #expect(try await fixture.database.loadRemoteAccounts().map(\.id) == [first.id])
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
    private var credentials: [RemoteAccountID: RemoteAccountCredential]
    private(set) var activeAccountID: RemoteAccountID?
    private let configureError: (any Error & Sendable)?
    private let activateError: (any Error & Sendable)?
    private let removeError: (any Error & Sendable)?

    init(
        credentials: [RemoteAccountID: RemoteAccountCredential] = [:],
        activeAccountID: RemoteAccountID? = nil,
        configureError: (any Error & Sendable)? = nil,
        activateError: (any Error & Sendable)? = nil,
        removeError: (any Error & Sendable)? = nil
    ) {
        self.credentials = credentials
        self.activeAccountID = activeAccountID
        self.configureError = configureError
        self.activateError = activateError
        self.removeError = removeError
    }

    func configureRemoteAccount(
        accountID: RemoteAccountID,
        credential: RemoteAccountCredential
    ) throws {
        if let configureError { throw configureError }
        credentials[accountID] = credential
        activeAccountID = accountID
    }

    func activateRemoteAccount(accountID: RemoteAccountID) throws {
        if let activateError { throw activateError }
        guard credentials[accountID] != nil else { throw AccountModelTestError.expected }
        activeAccountID = accountID
    }

    func removeRemoteAccount(accountID: RemoteAccountID) throws {
        if let removeError { throw removeError }
        credentials.removeValue(forKey: accountID)
        if activeAccountID == accountID { activeAccountID = nil }
    }

    func remoteAccountStatus() -> RemoteRuntimeStatus {
        RemoteRuntimeStatus(
            activeAccountID: activeAccountID,
            credentialAccountIDs: Array(credentials.keys),
            active: activeAccountID != nil,
            connected: activeAccountID != nil
        )
    }

    func credential(for accountID: RemoteAccountID) -> RemoteAccountCredential? {
        credentials[accountID]
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

    func signIn(username: String, host: String) throws -> BrowserSSOSignIn {
        BrowserSSOSignIn(
            username: username,
            configToken: "\(username)-token",
            configEndpoint: "tcp://\(host):22020",
            controlOrigin: try #require(URL(string: "https://\(host)")),
            consoleURL: try #require(URL(string: "https://\(host)/console"))
        )
    }

    func account(username: String, host: String) throws -> StoredRemoteAccount {
        let signIn = try signIn(username: username, host: host)
        return StoredRemoteAccount(
            profile: RemoteAccountProfile(
                controlOrigin: signIn.controlOrigin,
                consoleURL: signIn.consoleURL,
                username: username
            ),
            deviceBinding: RemoteDeviceBinding(configEndpoint: signIn.configEndpoint, machineID: UUID())
        )
    }

    func credential(for account: StoredRemoteAccount, token: String) -> RemoteAccountCredential {
        RemoteAccountCredential(
            endpoint: account.deviceBinding.configEndpoint,
            token: token,
            machineID: account.deviceBinding.machineID,
            deviceName: "Test Mac"
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}

private struct AccountModelNetworkSecretStore: NetworkSecretStore {
    func save(_: String, for _: NetworkConfig, purpose _: NetworkSecretAccessPurpose) throws {}
    func secret(for _: NetworkConfig, purpose _: NetworkSecretAccessPurpose, reason _: String?) throws -> String? { nil }
    func deleteSecret(for _: NetworkConfig, purpose _: NetworkSecretAccessPurpose) throws {}
    func presence(for _: NetworkConfig) throws -> NetworkSecretPresence { .missing }
    func authenticationCapability() -> NetworkSecretAuthenticationCapability { .unknown }
    func invalidateAuthenticationSession() {}
}
