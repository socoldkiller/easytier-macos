import AppKit
import EasyTierShared
import Foundation
import Observation

protocol BrowserSSOAuthenticating: Sendable {
    func signIn(serverAddress: String) async throws -> BrowserSSOSignIn
}

extension BrowserSSOClient: BrowserSSOAuthenticating {}

protocol RemoteAccountRuntimeClient: Sendable {
    func configureRemoteAccount(_ credential: RemoteAccountCredential) async throws
    func removeRemoteAccount() async throws
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

    private(set) var account: RemoteAccountProfile?
    private(set) var phase: Phase = .signedOut
    private(set) var errorMessage: String?
    var serverAddress = ""
    var showsAddAccount = false

    @ObservationIgnored private let database: ApplicationDatabase
    @ObservationIgnored private let browserSSO: any BrowserSSOAuthenticating
    @ObservationIgnored private let runtime: any RemoteAccountRuntimeClient
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    init(
        database: ApplicationDatabase,
        browserSSO: any BrowserSSOAuthenticating = BrowserSSOClient(),
        runtime: any RemoteAccountRuntimeClient,
        userDefaults: UserDefaults = .standard
    ) {
        self.database = database
        self.browserSSO = browserSSO
        self.runtime = runtime
        self.userDefaults = userDefaults
    }

    deinit {
        signInTask?.cancel()
        statusTask?.cancel()
    }

    func load() async {
        do {
            account = try await database.loadRemoteAccount()
            guard account != nil else {
                phase = .signedOut
                return
            }
            await refreshStatus()
            startStatusMonitoring()
        } catch {
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    func beginSignIn() {
        guard signInTask == nil else { return }
        let address = serverAddress
        phase = .waitingForBrowser
        errorMessage = nil
        signInTask = Task { [weak self] in
            guard let self else { return }
            defer { signInTask = nil }
            do {
                let result = try await browserSSO.signIn(serverAddress: address)
                try Task.checkCancellation()
                phase = .connecting
                let now = Date.now
                let machineID = stableMachineID
                let credential = RemoteAccountCredential(
                    endpoint: result.configEndpoint,
                    token: result.configToken,
                    machineID: machineID,
                    deviceName: Host.current().localizedName ?? "Mac"
                )
                try await runtime.configureRemoteAccount(credential)
                let profile = RemoteAccountProfile(
                    controlOrigin: result.controlOrigin,
                    configEndpoint: result.configEndpoint,
                    consoleURL: result.consoleURL,
                    username: result.username,
                    machineID: machineID,
                    createdAt: account?.createdAt ?? now,
                    updatedAt: now
                )
                try await database.saveRemoteAccount(profile)
                account = profile
                showsAddAccount = false
                serverAddress = ""
                await refreshStatus()
                startStatusMonitoring()
            } catch is CancellationError {
                phase = account == nil ? .signedOut : .retrying
            } catch {
                phase = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        phase = account == nil ? .signedOut : .retrying
    }

    func logOut() async {
        errorMessage = nil
        do {
            try await runtime.removeRemoteAccount()
            try await database.removeRemoteAccount()
            statusTask?.cancel()
            statusTask = nil
            account = nil
            phase = .signedOut
        } catch {
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    func openConsole() {
        guard let url = account?.consoleURL else { return }
        NSWorkspace.shared.open(url)
    }

    func signInAgain() {
        guard let account else { return }
        serverAddress = account.controlOrigin.absoluteString
        showsAddAccount = true
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

    private func refreshStatus() async {
        do {
            let status = try await runtime.remoteAccountStatus()
            errorMessage = status.lastError
            if status.connected {
                phase = .connected
            } else if status.active {
                phase = .retrying
            } else {
                phase = .failed
            }
        } catch {
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    private static let machineIDKey = "EasyTierRemoteAccountMachineID"
}
