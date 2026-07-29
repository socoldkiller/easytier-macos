import EasyTierCoreRuntime
import EasyTierShared
import Foundation

private enum RemoteAccountRuntimeError: LocalizedError {
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case let .startFailed(message): message
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
            guard let credential = try store.load() else { return }
            try start(credential)
        } catch {
            lastError = "The saved Config Server connection could not be restored."
        }
    }

    func configure(_ credential: RemoteAccountCredential) throws {
        if client.configServerIsActive {
            try client.stopConfigServerSync()
        } else {
            try client.retainSync(instanceNames: [])
        }
        try store.save(credential)
        do {
            try start(credential)
            lastError = nil
        } catch {
            try? store.remove()
            let message = "The Config Server connection could not be started."
            lastError = message
            throw RemoteAccountRuntimeError.startFailed(message)
        }
    }

    func remove() throws {
        if client.configServerIsActive {
            try client.stopConfigServerSync()
        }
        try store.remove()
        lastError = nil
    }

    func status() -> RemoteRuntimeStatus {
        RemoteRuntimeStatus(
            active: client.configServerIsActive,
            connected: client.configServerIsConnected,
            lastError: lastError
        )
    }

    private func start(_ credential: RemoteAccountCredential) throws {
        try client.startConfigServerSync(credential: credential) { _ in }
    }
}
