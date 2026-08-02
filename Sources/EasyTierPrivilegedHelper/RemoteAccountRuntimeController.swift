import EasyTierCoreRuntime
import EasyTierShared
import Foundation

private enum RemoteAccountRuntimeError: LocalizedError {
    case startFailed(String)
    case credentialMissing

    var errorDescription: String? {
        switch self {
        case let .startFailed(message): message
        case .credentialMissing: "No saved credential exists for this account."
        }
    }
}

actor RemoteAccountRuntimeController {
    private let client: StaticEasyTierFFIClient
    private let store: RemoteAccountCredentialStore
    private var lastError: String?

    init(
        client: StaticEasyTierFFIClient,
        store: RemoteAccountCredentialStore = RemoteAccountCredentialStore()
    ) {
        self.client = client
        self.store = store
    }

    func restoreAfterLaunch() {
        guard !client.configServerIsActive else { return }
        do {
            let library = try store.load()
            guard let accountID = library.activeAccountID,
                  let credential = library.credential(for: accountID)
            else { return }
            try start(credential)
        } catch {
            lastError = "The saved Config Server connection could not be restored."
        }
    }

    func configure(accountID: RemoteAccountID, credential: RemoteAccountCredential) throws {
        let previousLibrary = try store.load()
        var candidate = previousLibrary
        candidate.records.removeAll { $0.accountID == accountID }
        candidate.records.append(RemoteAccountCredentialRecord(accountID: accountID, credential: credential))
        candidate.activeAccountID = accountID
        try switchRuntime(from: previousLibrary, to: candidate, credential: credential)
    }

    func activate(accountID: RemoteAccountID) throws {
        let previousLibrary = try store.load()
        guard let credential = previousLibrary.credential(for: accountID) else {
            throw RemoteAccountRuntimeError.credentialMissing
        }
        var candidate = previousLibrary
        candidate.activeAccountID = accountID
        try switchRuntime(from: previousLibrary, to: candidate, credential: credential)
    }

    func remove(accountID: RemoteAccountID) throws {
        var library = try store.load()
        let removesActiveAccount = library.activeAccountID == accountID
        if removesActiveAccount, client.configServerIsActive {
            try client.stopConfigServerSync()
        }
        library.records.removeAll { $0.accountID == accountID }
        if removesActiveAccount {
            library.activeAccountID = nil
        }
        try store.save(library)
        lastError = nil
    }

    func status() throws -> RemoteRuntimeStatus {
        let library = try store.load()
        return RemoteRuntimeStatus(
            activeAccountID: library.activeAccountID,
            credentialAccountIDs: library.records.map(\.accountID),
            active: client.configServerIsActive,
            connected: client.configServerIsConnected,
            lastError: lastError
        )
    }

    private func switchRuntime(
        from previousLibrary: RemoteAccountCredentialLibrary,
        to candidate: RemoteAccountCredentialLibrary,
        credential: RemoteAccountCredential
    ) throws {
        do {
            if client.configServerIsActive {
                try client.stopConfigServerSync()
            } else {
                try client.retainSync(instanceNames: [])
            }
            try store.save(candidate)
            try start(credential)
            lastError = nil
        } catch {
            let message = "The Config Server connection could not be started."
            let restoredPreviousSession = restore(previousLibrary)
            lastError = restoredPreviousSession
                ? "\(message) The previous account connection was restored."
                : message
            throw RemoteAccountRuntimeError.startFailed(message)
        }
    }

    private func start(_ credential: RemoteAccountCredential) throws {
        try client.startConfigServerSync(credential: credential) { _ in }
    }

    private func restore(_ library: RemoteAccountCredentialLibrary) -> Bool {
        if client.configServerIsActive {
            try? client.stopConfigServerSync()
        }
        do {
            try store.save(library)
            guard let accountID = library.activeAccountID,
                  let credential = library.credential(for: accountID)
            else { return true }
            try start(credential)
            return true
        } catch {
            return false
        }
    }
}
