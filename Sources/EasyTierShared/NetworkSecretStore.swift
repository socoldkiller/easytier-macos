import Foundation
@preconcurrency import LocalAuthentication
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
    ) async throws

    func secret(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose,
        reason: String?
    ) async throws -> String?

    func deleteSecret(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws

    func presence(for config: NetworkConfig) async throws -> NetworkSecretPresence

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
    func save(_ secret: String, for config: NetworkConfig) async throws {
        try await save(secret, for: config, purpose: .update)
    }

    func secret(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws -> String? {
        try await secret(for: config, purpose: purpose, reason: nil)
    }

    func deleteSecret(for config: NetworkConfig) async throws {
        try await deleteSecret(for: config, purpose: .delete)
    }

    func containsSecret(for config: NetworkConfig) async throws -> Bool {
        try await presence(for: config) != .missing
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
            "The protected Keychain item could not be verified after it was saved."
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

    fileprivate func account(for config: NetworkConfig) -> String {
        accountPrefix + config.instance_id
    }
}

public final class SystemNetworkSecretStore: NetworkSecretStore, @unchecked Sendable {
    public static let service = "com.kkrainbow.easytier.mac.network-secret"

    private enum ItemPresence {
        case absent
        case present
        case interactionRequired
    }

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
    ) async throws {
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
    ) async throws -> String? {
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
                try self.deleteItem(for: config, context: context)
            }
        }
    }

    public func presence(for config: NetworkConfig) async throws -> NetworkSecretPresence {
        try await perform {
            switch try self.presence(account: self.namespace.account(for: config)) {
            case .present:
                return .present
            case .interactionRequired:
                return .interactionRequired
            case .absent:
                return .missing
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
    ) throws {
        let account = namespace.account(for: config)
        try upsertItem(secret, account: account, displayName: config.network_name, context: context)
        try verifyItem(account: account)
    }

    private func resolveSecretTransaction(
        for config: NetworkConfig,
        context: LAContext
    ) throws -> String? {
        let result = read(account: namespace.account(for: config), context: context)
        switch result.status {
        case errSecSuccess:
            return try decodeSecret(result.result)
        case errSecItemNotFound:
            return nil
        default:
            try requireSuccess(result.status)
            return nil
        }
    }

    private func upsertItem(
        _ secret: String,
        account: String,
        displayName: String,
        context: LAContext
    ) throws {
        let data = Data(secret.utf8)
        let updateAttributes = itemUpdateAttributes(data: data, displayName: displayName)
        var updateQuery = baseQuery(account: account)
        updateQuery[kSecUseAuthenticationContext as String] = context

        let updateStatus = keychain.update(updateQuery, attributes: updateAttributes)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            try requireSuccess(updateStatus)
            return
        }

        let addAttributes = try itemAddAttributes(data: data, displayName: displayName)
        var addQuery = baseQuery(account: account)
        addAttributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = keychain.add(addQuery)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            try requireSuccess(addStatus)
            return
        }

        try requireSuccess(keychain.update(updateQuery, attributes: updateAttributes))
    }

    private func verifyItem(account: String) throws {
        switch try presence(account: account) {
        case .present, .interactionRequired:
            return
        case .absent:
            throw NetworkSecretStoreError.verificationFailed
        }
    }

    private func deleteItem(for config: NetworkConfig, context: LAContext) throws {
        try requireSuccessOrNotFound(delete(account: namespace.account(for: config), context: context))
    }

    private func read(
        account: String,
        context: LAContext
    ) -> (status: OSStatus, result: CFTypeRef?) {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        return keychain.copyMatching(query)
    }

    private func presence(account: String) throws -> ItemPresence {
        var query = baseQuery(account: account)
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

        var query = baseQuery(account: account)
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

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
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

    private func delete(account: String, context: LAContext) -> OSStatus {
        var query = baseQuery(account: account)
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
