import Foundation
@preconcurrency import LocalAuthentication
import OSLog
import Security

public enum NetworkSecretAccessPurpose: String, Sendable {
    case run
    case restart
    case wakeRecovery
    case reveal
    case export
    case update
    case delete

    fileprivate var reuseDuration: TimeInterval {
        switch self {
        case .run, .restart, .wakeRecovery:
            10
        case .reveal, .export, .update, .delete:
            0
        }
    }

    fileprivate func defaultReason(for networkName: String) -> String {
        switch self {
        case .run:
            "Use the saved secret to start network \"\(networkName)\"."
        case .restart:
            "Use the saved secret to restart network \"\(networkName)\"."
        case .wakeRecovery:
            "Use the saved secret to recover network \"\(networkName)\" after wake."
        case .reveal:
            "Unlock the saved secret for network \"\(networkName)\"."
        case .export:
            "Include the saved secret in the TOML export for network \"\(networkName)\"."
        case .update:
            "Update the saved secret for network \"\(networkName)\"."
        case .delete:
            "Delete the saved secret for network \"\(networkName)\"."
        }
    }
}

public enum NetworkSecretCleanupBackend: String, Equatable, Sendable {
    case dataProtection
    case legacy
}

public struct NetworkSecretCleanupIssue: Equatable, Sendable {
    public var backend: NetworkSecretCleanupBackend
    public var status: OSStatus

    public init(backend: NetworkSecretCleanupBackend, status: OSStatus) {
        self.backend = backend
        self.status = status
    }
}

public enum NetworkSecretCleanupState: Equatable, Sendable {
    case notNeeded
    case completed
    case pending([NetworkSecretCleanupIssue])

    public var issues: [NetworkSecretCleanupIssue] {
        guard case let .pending(issues) = self else { return [] }
        return issues
    }
}

public struct NetworkSecretWriteResult: Equatable, Sendable {
    public var cleanup: NetworkSecretCleanupState

    public init(cleanup: NetworkSecretCleanupState) {
        self.cleanup = cleanup
    }
}

public struct NetworkSecretReadResult: Equatable, Sendable {
    public var secret: String
    public var cleanup: NetworkSecretCleanupState

    public init(secret: String, cleanup: NetworkSecretCleanupState) {
        self.secret = secret
        self.cleanup = cleanup
    }
}

public enum NetworkSecretPresence: Equatable, Sendable {
    case missing
    case present
    case interactionRequired
}

public enum NetworkSecretBiometricStatus: Equatable, Sendable {
    case available
    case notPaired
    case notEnrolled
    case lockedOut
    case unavailable
    case unknown(Int)
}

public struct NetworkSecretAuthenticationCapability: Equatable, Sendable {
    public var biometrics: NetworkSecretBiometricStatus
    public var deviceOwnerAuthenticationAvailable: Bool

    public init(
        biometrics: NetworkSecretBiometricStatus,
        deviceOwnerAuthenticationAvailable: Bool
    ) {
        self.biometrics = biometrics
        self.deviceOwnerAuthenticationAvailable = deviceOwnerAuthenticationAvailable
    }

    public static let unknown = NetworkSecretAuthenticationCapability(
        biometrics: .unknown(0),
        deviceOwnerAuthenticationAvailable: true
    )

    public var guidance: String? {
        switch biometrics {
        case .available:
            nil
        case .notPaired:
            "Touch ID is not paired with this Mac. Pair a Touch ID keyboard, or use your Mac login password."
        case .notEnrolled:
            "Touch ID has no enrolled fingerprints. Add one in System Settings, or use your Mac login password."
        case .lockedOut:
            "Touch ID is temporarily locked. Unlock it with your Mac login password."
        case .unavailable:
            "Touch ID is unavailable. macOS can still authenticate with your Mac login password."
        case .unknown:
            deviceOwnerAuthenticationAvailable
                ? "Touch ID status is unavailable. macOS can still authenticate with your Mac login password."
                : "This Mac cannot currently authenticate access to saved network secrets."
        }
    }
}

public protocol NetworkSecretStore: Sendable {
    func save(
        _ secret: String,
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws -> NetworkSecretWriteResult

    func secret(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose,
        reason: String?
    ) async throws -> NetworkSecretReadResult?

    func deleteSecret(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws

    func presence(for config: NetworkConfig) async throws -> NetworkSecretPresence

    func migrateSecret(
        from oldConfig: NetworkConfig,
        to newConfig: NetworkConfig,
        removeSource: Bool
    ) async throws -> NetworkSecretWriteResult

    func authenticate(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws

    func authenticationCapability() -> NetworkSecretAuthenticationCapability
    func invalidateAuthenticationSession()
}

@MainActor
public protocol NetworkSecretAuthenticationActivityObserver: Sendable {
    func networkSecretAuthenticationDidBegin(id: UUID)
    func networkSecretAuthenticationDidEnd(id: UUID)
}

public extension NetworkSecretStore {
    func save(_ secret: String, for config: NetworkConfig) async throws -> NetworkSecretWriteResult {
        try await save(secret, for: config, purpose: .update)
    }

    func secret(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws -> NetworkSecretReadResult? {
        try await secret(for: config, purpose: purpose, reason: nil)
    }

    func deleteSecret(for config: NetworkConfig) async throws {
        try await deleteSecret(for: config, purpose: .delete)
    }

    func containsSecret(for config: NetworkConfig) async throws -> Bool {
        try await presence(for: config) != .missing
    }

    func migrateSecret(
        from oldConfig: NetworkConfig,
        to newConfig: NetworkConfig
    ) async throws -> NetworkSecretWriteResult {
        try await migrateSecret(from: oldConfig, to: newConfig, removeSource: true)
    }

    func authenticate(
        for _: NetworkConfig,
        purpose _: NetworkSecretAccessPurpose
    ) async throws {}

    func authenticationCapability() -> NetworkSecretAuthenticationCapability { .unknown }
    func invalidateAuthenticationSession() {}
}

public enum NetworkSecretStoreError: LocalizedError, Equatable {
    case accessControl(String)
    case authentication(Int)
    case invalidData
    case missingEntitlement
    case verificationFailed
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .accessControl(message):
            "Keychain access control failed: \(message)"
        case let .authentication(code):
            NSError(domain: LAError.errorDomain, code: code).localizedDescription
        case .invalidData:
            "Keychain secret is not valid UTF-8."
        case .missingEntitlement:
            "EasyTier is not signed with the Data Protection Keychain entitlements required to protect network secrets. Reinstall a correctly signed build."
        case .verificationFailed:
            "The protected Keychain item could not be verified after it was saved. The legacy item was left untouched."
        case let .keychain(status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        }
    }

    public var isUserCancellation: Bool {
        switch self {
        case let .keychain(status):
            return status == errSecUserCanceled
        case let .authentication(rawCode):
            guard let code = LAError.Code(rawValue: rawCode) else { return false }
            return code == .userCancel || code == .appCancel || code == .systemCancel
        default:
            return false
        }
    }
}

protocol NetworkSecretKeychainClient: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?)
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemNetworkSecretKeychainClient: NetworkSecretKeychainClient {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

protocol NetworkSecretAuthenticating: Sendable {
    func authenticate(context: LAContext, reason: String) async throws
}

private struct SystemNetworkSecretAuthenticator: NetworkSecretAuthenticating {
    func authenticate(context: LAContext, reason: String) async throws {
        do {
            guard try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            ) else {
                throw NetworkSecretStoreError.authentication(LAError.Code.authenticationFailed.rawValue)
            }
        } catch let error as LAError {
            throw NetworkSecretStoreError.authentication(error.code.rawValue)
        }
    }
}

package struct NetworkSecretKeychainNamespace: Sendable {
    package var service: String
    package var accessGroup: String?
    package var accountPrefix: String

    package init(service: String, accessGroup: String? = nil, accountPrefix: String = "") {
        self.service = service
        self.accessGroup = accessGroup
        self.accountPrefix = accountPrefix
    }

    fileprivate func accounts(for config: NetworkConfig) -> [String] {
        let rawName = config.network_name
        let normalizedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryName = normalizedName.isEmpty ? rawName : normalizedName
        return [primaryName, rawName]
            .reduce(into: [String]()) { accounts, name in
                let account = accountPrefix + name
                if !accounts.contains(account) { accounts.append(account) }
            }
    }
}

public final class SystemNetworkSecretStore: NetworkSecretStore, @unchecked Sendable {
    public static let service = "com.kkrainbow.easytier.mac.network-secret"

    private enum Backend {
        case dataProtection
        case legacy

        var publicValue: NetworkSecretCleanupBackend {
            switch self {
            case .dataProtection: .dataProtection
            case .legacy: .legacy
            }
        }
    }

    private struct LocatedSecret {
        var secret: String
        var account: String
        var backend: Backend
    }

    private enum ItemPresence {
        case absent
        case present
        case interactionRequired
    }

    private static let logger = Logger(
        subsystem: "com.kkrainbow.easytier.mac",
        category: "NetworkSecretStore"
    )

    private let keychain: any NetworkSecretKeychainClient
    private let authenticator: any NetworkSecretAuthenticating
    private let contextFactory: @Sendable () -> LAContext
    private let namespace: NetworkSecretKeychainNamespace
    private let authenticationActivityObserver: (any NetworkSecretAuthenticationActivityObserver)?
    private let operationQueue: DispatchQueue
    private let contextLock = NSLock()
    private var activeAuthenticationContexts: [UUID: LAContext] = [:]

    public convenience init(
        authenticationActivityObserver: (any NetworkSecretAuthenticationActivityObserver)? = nil
    ) {
        self.init(
            keychain: SystemNetworkSecretKeychainClient(),
            authenticator: SystemNetworkSecretAuthenticator(),
            namespace: NetworkSecretKeychainNamespace(
                service: Self.service,
                accessGroup: Self.currentAccessGroup()
            ),
            authenticationActivityObserver: authenticationActivityObserver
        )
    }

    package convenience init(namespace: NetworkSecretKeychainNamespace) {
        self.init(
            keychain: SystemNetworkSecretKeychainClient(),
            authenticator: SystemNetworkSecretAuthenticator(),
            namespace: namespace
        )
    }

    init(
        keychain: any NetworkSecretKeychainClient,
        authenticator: any NetworkSecretAuthenticating = SystemNetworkSecretAuthenticator(),
        contextFactory: @escaping @Sendable () -> LAContext = LAContext.init,
        namespace: NetworkSecretKeychainNamespace = NetworkSecretKeychainNamespace(service: SystemNetworkSecretStore.service),
        authenticationActivityObserver: (any NetworkSecretAuthenticationActivityObserver)? = nil,
        operationQueue: DispatchQueue? = nil
    ) {
        self.keychain = keychain
        self.authenticator = authenticator
        self.contextFactory = contextFactory
        self.namespace = namespace
        self.authenticationActivityObserver = authenticationActivityObserver
        self.operationQueue = operationQueue ?? DispatchQueue(
            label: "com.kkrainbow.easytier.mac.network-secret-store",
            qos: .userInitiated
        )
    }

    public func save(
        _ secret: String,
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws -> NetworkSecretWriteResult {
        try await withAuthenticationContext(for: config, purpose: purpose, reason: nil) { context in
            try await self.perform {
                try self.saveTransaction(secret, for: config, context: context)
            }
        }
    }

    public func secret(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose,
        reason: String?
    ) async throws -> NetworkSecretReadResult? {
        try await withAuthenticationContext(for: config, purpose: purpose, reason: reason) { context in
            try await self.perform {
                try self.resolveSecretTransaction(for: config, context: context)
            }
        }
    }

    public func deleteSecret(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws {
        guard try await presence(for: config) != .missing else { return }

        try await withAuthenticationContext(for: config, purpose: purpose, reason: nil) { context in
            do {
                try await self.authenticator.authenticate(
                    context: context,
                    reason: purpose.defaultReason(for: config.network_name)
                )
            } catch let error as NetworkSecretStoreError {
                throw error
            } catch {
                throw NetworkSecretStoreError.authentication((error as NSError).code)
            }

            try await self.perform {
                try self.deleteAllItems(for: config, context: context)
            }
        }
    }

    public func presence(for config: NetworkConfig) async throws -> NetworkSecretPresence {
        try await perform {
            var sawInteractionRequired = false
            for backend in [Backend.dataProtection, Backend.legacy] {
                for account in self.namespace.accounts(for: config) {
                    switch try self.presence(account: account, backend: backend) {
                    case .present:
                        return .present
                    case .interactionRequired:
                        sawInteractionRequired = true
                    case .absent:
                        continue
                    }
                }
            }
            return sawInteractionRequired ? .interactionRequired : .missing
        }
    }

    public func migrateSecret(
        from oldConfig: NetworkConfig,
        to newConfig: NetworkConfig,
        removeSource: Bool
    ) async throws -> NetworkSecretWriteResult {
        guard namespace.accounts(for: oldConfig).first != namespace.accounts(for: newConfig).first else {
            return NetworkSecretWriteResult(cleanup: .notNeeded)
        }
        let authenticatesSourceRemoval: Bool
        if removeSource {
            authenticatesSourceRemoval = try await presence(for: oldConfig) != .missing
        } else {
            authenticatesSourceRemoval = false
        }

        return try await withAuthenticationContext(for: oldConfig, purpose: .update, reason: nil) { context in
            if authenticatesSourceRemoval {
                do {
                    try await self.authenticator.authenticate(
                        context: context,
                        reason: NetworkSecretAccessPurpose.update.defaultReason(for: oldConfig.network_name)
                    )
                } catch let error as NetworkSecretStoreError {
                    throw error
                } catch {
                    throw NetworkSecretStoreError.authentication((error as NSError).code)
                }
            }
            return try await self.perform {
                var cleanupStates: [NetworkSecretCleanupState] = []

                if let destination = try self.resolveSecretTransaction(for: newConfig, context: context) {
                    cleanupStates.append(destination.cleanup)
                } else if let source = try self.resolveSecretTransaction(for: oldConfig, context: context) {
                    cleanupStates.append(source.cleanup)
                    let write = try self.saveTransaction(source.secret, for: newConfig, context: context)
                    cleanupStates.append(write.cleanup)
                } else {
                    return NetworkSecretWriteResult(cleanup: .notNeeded)
                }

                if removeSource {
                    cleanupStates.append(self.cleanupAllItems(for: oldConfig, context: context))
                }
                return NetworkSecretWriteResult(cleanup: self.mergeCleanupStates(cleanupStates))
            }
        }
    }

    public func authenticationCapability() -> NetworkSecretAuthenticationCapability {
        let biometricContext = contextFactory()
        var biometricError: NSError?
        let biometricsAvailable = biometricContext.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &biometricError
        )

        let ownerContext = contextFactory()
        var ownerError: NSError?
        let ownerAuthenticationAvailable = ownerContext.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &ownerError
        )

        let biometricStatus: NetworkSecretBiometricStatus
        if biometricsAvailable {
            biometricStatus = .available
        } else if let code = biometricError.flatMap({ LAError.Code(rawValue: $0.code) }) {
            biometricStatus = switch code {
            case .biometryNotPaired: .notPaired
            case .biometryNotEnrolled: .notEnrolled
            case .biometryLockout: .lockedOut
            case .biometryNotAvailable: .unavailable
            default: .unknown(code.rawValue)
            }
        } else {
            biometricStatus = .unknown(biometricError?.code ?? 0)
        }

        return NetworkSecretAuthenticationCapability(
            biometrics: biometricStatus,
            deviceOwnerAuthenticationAvailable: ownerAuthenticationAvailable
        )
    }

    public func authenticate(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws {
        try await withAuthenticationContext(for: config, purpose: purpose, reason: nil) { context in
            do {
                try await self.authenticator.authenticate(
                    context: context,
                    reason: purpose.defaultReason(for: config.network_name)
                )
            } catch let error as NetworkSecretStoreError {
                throw error
            } catch {
                throw NetworkSecretStoreError.authentication((error as NSError).code)
            }
        }
    }

    public func invalidateAuthenticationSession() {
        contextLock.lock()
        let contexts = Array(activeAuthenticationContexts.values)
        activeAuthenticationContexts.removeAll()
        contextLock.unlock()

        contexts.forEach { $0.invalidate() }
    }

    private func saveTransaction(
        _ secret: String,
        for config: NetworkConfig,
        context: LAContext
    ) throws -> NetworkSecretWriteResult {
        let primaryAccount = namespace.accounts(for: config)[0]
        try upsertModernItem(secret, account: primaryAccount, displayName: config.network_name, context: context)
        try verifyModernItem(account: primaryAccount)
        let cleanup = cleanupSupersededItems(for: config, keepingAccount: primaryAccount, context: context)
        return NetworkSecretWriteResult(cleanup: cleanup)
    }

    private func resolveSecretTransaction(
        for config: NetworkConfig,
        context: LAContext
    ) throws -> NetworkSecretReadResult? {
        let accounts = namespace.accounts(for: config)
        let primaryAccount = accounts[0]

        if let located = try locateSecret(accounts: accounts, backend: .dataProtection, context: context) {
            var cleanupStates: [NetworkSecretCleanupState] = []
            if located.account != primaryAccount {
                try upsertModernItem(
                    located.secret,
                    account: primaryAccount,
                    displayName: config.network_name,
                    context: context
                )
                try verifyModernItem(account: primaryAccount)
            }
            cleanupStates.append(cleanupSupersededItems(for: config, keepingAccount: primaryAccount, context: context))
            return NetworkSecretReadResult(
                secret: located.secret,
                cleanup: mergeCleanupStates(cleanupStates)
            )
        }

        guard let located = try locateSecret(accounts: accounts, backend: .legacy, context: context) else {
            return nil
        }

        try upsertModernItem(
            located.secret,
            account: primaryAccount,
            displayName: config.network_name,
            context: context
        )
        try verifyModernItem(account: primaryAccount)
        let cleanup = cleanupSupersededItems(for: config, keepingAccount: primaryAccount, context: context)
        return NetworkSecretReadResult(secret: located.secret, cleanup: cleanup)
    }

    private func locateSecret(
        accounts: [String],
        backend: Backend,
        context: LAContext
    ) throws -> LocatedSecret? {
        for account in accounts {
            let result = read(account: account, backend: backend, context: context)
            switch result.status {
            case errSecSuccess:
                return LocatedSecret(
                    secret: try decodeSecret(result.result),
                    account: account,
                    backend: backend
                )
            case errSecItemNotFound:
                continue
            default:
                try requireSuccess(result.status)
            }
        }
        return nil
    }

    private func upsertModernItem(
        _ secret: String,
        account: String,
        displayName: String,
        context: LAContext
    ) throws {
        let data = Data(secret.utf8)
        let updateAttributes = itemUpdateAttributes(data: data, displayName: displayName)
        var updateQuery = baseQuery(account: account, backend: .dataProtection)
        updateQuery[kSecUseAuthenticationContext as String] = context

        let updateStatus = keychain.update(updateQuery, attributes: updateAttributes)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            try requireSuccess(updateStatus)
            return
        }

        let addAttributes = try itemAddAttributes(data: data, displayName: displayName)
        var addQuery = baseQuery(account: account, backend: .dataProtection)
        addAttributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = keychain.add(addQuery)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            try requireSuccess(addStatus)
            return
        }

        try requireSuccess(keychain.update(updateQuery, attributes: updateAttributes))
    }

    private func verifyModernItem(account: String) throws {
        switch try presence(account: account, backend: .dataProtection) {
        case .present, .interactionRequired:
            return
        case .absent:
            throw NetworkSecretStoreError.verificationFailed
        }
    }

    private func cleanupSupersededItems(
        for config: NetworkConfig,
        keepingAccount: String,
        context: LAContext
    ) -> NetworkSecretCleanupState {
        var attempts: [(Backend, String)] = namespace.accounts(for: config).map { (.legacy, $0) }
        attempts.append(contentsOf: namespace.accounts(for: config)
            .filter { $0 != keepingAccount }
            .map { (.dataProtection, $0) })
        return cleanup(attempts: attempts, context: context)
    }

    private func cleanupAllItems(
        for config: NetworkConfig,
        context: LAContext
    ) -> NetworkSecretCleanupState {
        let accounts = namespace.accounts(for: config)
        let legacyCleanup = cleanup(
            attempts: accounts.map { (Backend.legacy, $0) },
            context: context
        )
        guard legacyCleanup.issues.isEmpty else { return legacyCleanup }

        let modernCleanup = cleanup(
            attempts: accounts.map { (Backend.dataProtection, $0) },
            context: context
        )
        return mergeCleanupStates([legacyCleanup, modernCleanup])
    }

    private func cleanup(
        attempts: [(Backend, String)],
        context: LAContext
    ) -> NetworkSecretCleanupState {
        var deletedAny = false
        var issues: [NetworkSecretCleanupIssue] = []

        for (backend, account) in attempts {
            let status = delete(account: account, backend: backend, context: context)
            switch status {
            case errSecSuccess:
                deletedAny = true
            case errSecItemNotFound:
                continue
            default:
                let issue = NetworkSecretCleanupIssue(
                    backend: backend.publicValue,
                    status: status
                )
                issues.append(issue)
                Self.logger.error(
                    "Keychain cleanup pending backend=\(backend.publicValue.rawValue, privacy: .public) status=\(status, privacy: .public)"
                )
            }
        }

        if !issues.isEmpty { return .pending(issues) }
        return deletedAny ? .completed : .notNeeded
    }

    private func deleteAllItems(for config: NetworkConfig, context: LAContext) throws {
        let accounts = namespace.accounts(for: config)
        for account in accounts {
            try requireSuccessOrNotFound(delete(account: account, backend: .legacy, context: context))
        }
        for account in accounts {
            try requireSuccessOrNotFound(delete(account: account, backend: .dataProtection, context: context))
        }
    }

    private func mergeCleanupStates(
        _ states: [NetworkSecretCleanupState]
    ) -> NetworkSecretCleanupState {
        let issues = states.flatMap(\.issues)
        if !issues.isEmpty { return .pending(issues) }
        if states.contains(.completed) { return .completed }
        return .notNeeded
    }

    private func read(
        account: String,
        backend: Backend,
        context: LAContext
    ) -> (status: OSStatus, result: CFTypeRef?) {
        var query = baseQuery(account: account, backend: backend)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        return keychain.copyMatching(query)
    }

    private func presence(account: String, backend: Backend) throws -> ItemPresence {
        var query = baseQuery(account: account, backend: backend)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        let status = keychain.copyMatching(query).status
        switch status {
        case errSecSuccess:
            return .present
        case errSecInteractionNotAllowed:
            return .interactionRequired
        case errSecItemNotFound:
            guard case .dataProtection = backend else { return .absent }
            // macOS can hide ACL-protected items from metadata-only queries when UI is disabled.
            return try protectedItemPresence(account: account)
        default:
            try requireSuccess(status)
            return .absent
        }
    }

    private func protectedItemPresence(account: String) throws -> ItemPresence {
        let context = contextFactory()
        context.interactionNotAllowed = true
        defer { context.invalidate() }

        var query = baseQuery(account: account, backend: .dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        let status = keychain.copyMatching(query).status
        switch status {
        case errSecSuccess:
            return .present
        case errSecInteractionNotAllowed:
            return .interactionRequired
        case errSecItemNotFound:
            return .absent
        default:
            try requireSuccess(status)
            return .absent
        }
    }

    private func baseQuery(account: String, backend: Backend) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: backend == .dataProtection,
        ]
        if let accessGroup = namespace.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func itemAddAttributes(data: Data, displayName: String) throws -> [String: Any] {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.userPresence],
            &error
        ) else {
            throw NetworkSecretStoreError.accessControl(
                error?.takeRetainedValue().localizedDescription ?? "unknown error"
            )
        }

        var attributes = itemUpdateAttributes(data: data, displayName: displayName)
        attributes[kSecAttrAccessControl as String] = access
        return attributes
    }

    private func itemUpdateAttributes(data: Data, displayName: String) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrLabel as String: displayName,
            kSecAttrComment as String: "EasyTier network secret for \(displayName)",
        ]
    }

    private func delete(account: String, backend: Backend, context: LAContext) -> OSStatus {
        var query = baseQuery(account: account, backend: backend)
        query[kSecUseAuthenticationContext as String] = context
        return keychain.delete(query)
    }

    private func decodeSecret(_ result: CFTypeRef?) throws -> String {
        guard let data = result as? Data,
              let secret = String(data: data, encoding: .utf8)
        else {
            throw NetworkSecretStoreError.invalidData
        }
        return secret
    }

    private func withAuthenticationContext<T: Sendable>(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose,
        reason: String?,
        operation: @escaping @Sendable (LAContext) async throws -> T
    ) async throws -> T {
        let id = UUID()
        let context = contextFactory()
        context.localizedReason = reason ?? purpose.defaultReason(for: config.network_name)
        context.touchIDAuthenticationAllowableReuseDuration = purpose.reuseDuration

        contextLock.withLock {
            activeAuthenticationContexts[id] = context
        }

        await authenticationActivityObserver?.networkSecretAuthenticationDidBegin(id: id)
        do {
            let result = try await withTaskCancellationHandler {
                try await operation(context)
            } onCancel: {
                context.invalidate()
            }
            discardAuthenticationContext(id: id, matching: context)
            await authenticationActivityObserver?.networkSecretAuthenticationDidEnd(id: id)
            return result
        } catch {
            discardAuthenticationContext(id: id, matching: context)
            await authenticationActivityObserver?.networkSecretAuthenticationDidEnd(id: id)
            throw error
        }
    }

    private func discardAuthenticationContext(id: UUID, matching expected: LAContext) {
        contextLock.lock()
        let stored = activeAuthenticationContexts[id]
        if stored === expected {
            activeAuthenticationContexts.removeValue(forKey: id)
        }
        contextLock.unlock()

        if stored === expected {
            stored?.invalidate()
        }
    }

    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            operationQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func requireSuccess(_ status: OSStatus) throws {
        guard status != errSecMissingEntitlement else {
            throw NetworkSecretStoreError.missingEntitlement
        }
        guard status == errSecSuccess else {
            throw NetworkSecretStoreError.keychain(status)
        }
    }

    private func requireSuccessOrNotFound(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecItemNotFound else {
            try requireSuccess(status)
            return
        }
    }

    private static func currentAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                  task,
                  "keychain-access-groups" as NSString,
                  nil
              ) as? [String]
        else { return nil }
        return groups.first
    }
}
