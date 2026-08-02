import AppKit
import EasyTierShared
import Foundation
import Observation

protocol BrowserSSOAuthenticating: Sendable {
    func signIn(serverAddress: String) async throws -> BrowserSSOSignIn
}

extension BrowserSSOClient: BrowserSSOAuthenticating {}

protocol RemoteAccountRuntimeClient: Sendable {
    func configureRemoteAccount(
        accountID: RemoteAccountID,
        credential: RemoteAccountCredential
    ) async throws
    func activateRemoteAccount(accountID: RemoteAccountID) async throws
    func removeRemoteAccount(accountID: RemoteAccountID) async throws
    func remoteAccountStatus() async throws -> RemoteRuntimeStatus
}

extension PrivilegedEasyTierClient: RemoteAccountRuntimeClient {}

@MainActor
@Observable
final class AccountSettingsModel {
    enum Phase: Equatable {
        case signedOut
        case waitingForBrowser
        case connecting
        case connected
        case retrying
        case failed
    }

    enum Operation: Equatable {
        case signingIn
        case activating(RemoteAccountID)
        case loggingOut(RemoteAccountID)
        case forgetting(RemoteAccountID)
    }

    enum AccountStatus: Equatable {
        case connected
        case reconnecting
        case available
        case signedOut
        case failed

        var summary: String {
            switch self {
            case .connected: "Connected"
            case .reconnecting: "Reconnecting"
            case .available: "Available"
            case .signedOut: "Signed Out"
            case .failed: "Connection Failed"
            }
        }
    }

    private(set) var accounts: [StoredRemoteAccount] = []
    private(set) var activeAccountID: RemoteAccountID?
    private(set) var credentialAccountIDs: Set<RemoteAccountID> = []
    private(set) var phase: Phase = .signedOut
    private(set) var operation: Operation?
    private(set) var errorMessage: String?
    var serverAddress = ""

    var activeAccount: StoredRemoteAccount? {
        guard let activeAccountID else { return nil }
        return accounts.first { $0.id == activeAccountID }
    }

    var isOperationInFlight: Bool { operation != nil }

    var sortedAccounts: [StoredRemoteAccount] {
        accounts.sorted { lhs, rhs in
            if lhs.id == activeAccountID { return true }
            if rhs.id == activeAccountID { return false }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    @ObservationIgnored private let database: ApplicationDatabase
    @ObservationIgnored private let browserSSO: any BrowserSSOAuthenticating
    @ObservationIgnored private let runtime: any RemoteAccountRuntimeClient
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let configurationAuthorityDidChange: @MainActor (NetworkConfigurationAuthority) -> Void
    @ObservationIgnored private let remoteAccountWillChange: @MainActor () -> Void
    @ObservationIgnored private let remoteAccountDidChange: @MainActor () async -> Void
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var phaseBeforeSignIn: Phase = .signedOut

    init(
        database: ApplicationDatabase,
        browserSSO: any BrowserSSOAuthenticating = BrowserSSOClient(),
        runtime: any RemoteAccountRuntimeClient,
        userDefaults: UserDefaults = .standard,
        configurationAuthorityDidChange: @escaping @MainActor (NetworkConfigurationAuthority) -> Void = { _ in },
        remoteAccountWillChange: @escaping @MainActor () -> Void = {},
        remoteAccountDidChange: @escaping @MainActor () async -> Void = {}
    ) {
        self.database = database
        self.browserSSO = browserSSO
        self.runtime = runtime
        self.userDefaults = userDefaults
        self.configurationAuthorityDidChange = configurationAuthorityDidChange
        self.remoteAccountWillChange = remoteAccountWillChange
        self.remoteAccountDidChange = remoteAccountDidChange
    }

    deinit {
        signInTask?.cancel()
        statusTask?.cancel()
    }

    func load() async {
        do {
            accounts = try await database.loadRemoteAccounts()
            await refreshStatus(reconcileOrphan: true)
            if activeAccountID != nil { startStatusMonitoring() }
        } catch {
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    func status(for accountID: RemoteAccountID) -> AccountStatus {
        if activeAccountID == accountID {
            switch phase {
            case .connected: return .connected
            case .retrying, .connecting, .waitingForBrowser: return .reconnecting
            case .failed: return .failed
            case .signedOut: return credentialAccountIDs.contains(accountID) ? .available : .signedOut
            }
        }
        return credentialAccountIDs.contains(accountID) ? .available : .signedOut
    }

    func beginSignIn(serverAddress: String) {
        guard operation == nil, signInTask == nil else { return }
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        phaseBeforeSignIn = phase
        phase = .waitingForBrowser
        operation = .signingIn
        errorMessage = nil
        signInTask = Task { [weak self] in
            guard let self else { return }
            defer {
                signInTask = nil
                operation = nil
            }
            do {
                let result = try await browserSSO.signIn(serverAddress: address)
                try Task.checkCancellation()
                phase = .connecting
                let now = Date.now
                let profile = RemoteAccountProfile(
                    controlOrigin: result.controlOrigin,
                    consoleURL: result.consoleURL,
                    username: result.username
                )
                let previousAccount = accounts.first {
                    $0.profile.controlOrigin == profile.controlOrigin
                        && $0.profile.username == profile.username
                }
                let machineID = stableMachineID
                let proposedAccount = StoredRemoteAccount(
                    id: previousAccount?.id ?? RemoteAccountID(),
                    profile: profile,
                    deviceBinding: RemoteDeviceBinding(
                        configEndpoint: result.configEndpoint,
                        machineID: machineID
                    ),
                    createdAt: previousAccount?.createdAt ?? now,
                    updatedAt: now
                )
                let storedAccount = try await database.upsertRemoteAccount(proposedAccount)
                let credential = RemoteAccountCredential(
                    endpoint: result.configEndpoint,
                    token: result.configToken,
                    machineID: machineID,
                    deviceName: Host.current().localizedName ?? "Mac"
                )
                remoteAccountWillChange()
                do {
                    try await runtime.configureRemoteAccount(
                        accountID: storedAccount.id,
                        credential: credential
                    )
                } catch {
                    await restorePersistedAccount(previousAccount, replacing: storedAccount.id)
                    await remoteAccountDidChange()
                    throw error
                }
                accounts = try await database.loadRemoteAccounts()
                activeAccountID = storedAccount.id
                credentialAccountIDs.insert(storedAccount.id)
                configurationAuthorityDidChange(.configServer)
                self.serverAddress = ""
                await remoteAccountDidChange()
                await refreshStatus()
                startStatusMonitoring()
            } catch is CancellationError {
                phase = phaseBeforeSignIn
            } catch {
                errorMessage = error.localizedDescription
                await refreshStatus()
            }
        }
    }

    func beginSignIn() {
        beginSignIn(serverAddress: serverAddress)
    }

    func cancelSignIn() {
        guard phase == .waitingForBrowser else { return }
        signInTask?.cancel()
        phase = phaseBeforeSignIn
        operation = nil
        errorMessage = nil
    }

    func activate(accountID: RemoteAccountID) async {
        guard operation == nil, activeAccountID != accountID else { return }
        operation = .activating(accountID)
        errorMessage = nil
        remoteAccountWillChange()
        do {
            try await runtime.activateRemoteAccount(accountID: accountID)
            activeAccountID = accountID
            configurationAuthorityDidChange(.configServer)
            await remoteAccountDidChange()
            await refreshStatus()
            startStatusMonitoring()
        } catch {
            errorMessage = error.localizedDescription
            await remoteAccountDidChange()
            await refreshStatus()
        }
        operation = nil
    }

    func logOut(accountID: RemoteAccountID) async {
        guard operation == nil else { return }
        operation = .loggingOut(accountID)
        errorMessage = nil
        let wasActive = activeAccountID == accountID
        if wasActive { remoteAccountWillChange() }
        do {
            try await runtime.removeRemoteAccount(accountID: accountID)
            credentialAccountIDs.remove(accountID)
            if wasActive {
                activeAccountID = nil
                phase = .signedOut
                statusTask?.cancel()
                statusTask = nil
                configurationAuthorityDidChange(.local)
                await remoteAccountDidChange()
            }
        } catch {
            phase = wasActive ? .failed : phase
            errorMessage = error.localizedDescription
            if wasActive { await remoteAccountDidChange() }
        }
        operation = nil
    }

    func forgetAccount(accountID: RemoteAccountID) async {
        guard operation == nil else { return }
        operation = .forgetting(accountID)
        errorMessage = nil
        let wasActive = activeAccountID == accountID
        if wasActive { remoteAccountWillChange() }
        do {
            try await runtime.removeRemoteAccount(accountID: accountID)
            try await database.removeRemoteAccount(id: accountID)
            accounts.removeAll { $0.id == accountID }
            credentialAccountIDs.remove(accountID)
            if wasActive {
                activeAccountID = nil
                phase = .signedOut
                statusTask?.cancel()
                statusTask = nil
                configurationAuthorityDidChange(.local)
                await remoteAccountDidChange()
            }
        } catch {
            phase = wasActive ? .failed : phase
            errorMessage = error.localizedDescription
            if wasActive { await remoteAccountDidChange() }
        }
        operation = nil
    }

    func openConsole(accountID: RemoteAccountID) {
        guard let url = accounts.first(where: { $0.id == accountID })?.profile.consoleURL else { return }
        NSWorkspace.shared.open(url)
    }

    func signInAgain(accountID: RemoteAccountID) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        beginSignIn(serverAddress: account.profile.controlOrigin.absoluteString)
    }

    private var stableMachineID: UUID {
        if let value = userDefaults.string(forKey: Self.machineIDKey), let id = UUID(uuidString: value) {
            return id
        }
        let id = UUID()
        userDefaults.set(id.uuidString.lowercased(), forKey: Self.machineIDKey)
        return id
    }

    private func startStatusMonitoring() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.refreshStatus()
            }
        }
    }

    private func refreshStatus(reconcileOrphan: Bool = false) async {
        do {
            var status = try await runtime.remoteAccountStatus()
            if reconcileOrphan,
               let helperAccountID = status.activeAccountID,
               !accounts.contains(where: { $0.id == helperAccountID })
            {
                try await runtime.removeRemoteAccount(accountID: helperAccountID)
                status = try await runtime.remoteAccountStatus()
            }
            activeAccountID = status.activeAccountID.flatMap { id in
                accounts.contains(where: { $0.id == id }) ? id : nil
            }
            credentialAccountIDs = Set(status.credentialAccountIDs)
            errorMessage = status.lastError ?? errorMessage
            configurationAuthorityDidChange(activeAccountID == nil ? .local : .configServer)
            if status.connected, activeAccountID != nil {
                phase = .connected
            } else if activeAccountID != nil {
                phase = .retrying
            } else {
                phase = .signedOut
            }
        } catch {
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    private func restorePersistedAccount(
        _ previousAccount: StoredRemoteAccount?,
        replacing accountID: RemoteAccountID
    ) async {
        do {
            if let previousAccount {
                _ = try await database.upsertRemoteAccount(previousAccount)
            } else {
                try await database.removeRemoteAccount(id: accountID)
            }
            accounts = try await database.loadRemoteAccounts()
        } catch {
            // Keep the runtime error as the primary actionable failure.
        }
    }

    private static let machineIDKey = "EasyTierRemoteAccountMachineID"
}
