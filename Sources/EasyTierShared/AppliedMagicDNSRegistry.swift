import Foundation

/// Helper-process state protected by `lock`; no mutable storage escapes the lock.
package final class AppliedMagicDNSRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var configurationsByInstanceName: [String: AppliedMagicDNSConfiguration] = [:]
    private var configurationsByInstanceID: [String: AppliedMagicDNSConfiguration] = [:]

    package init() {}

    package func record(_ configuration: AppliedMagicDNSConfiguration) {
        lock.withLock {
            configurationsByInstanceName[configuration.instanceName] = configuration
            configurationsByInstanceID[configuration.instanceID] = configuration
        }
    }

    package func remove(instanceNames: [String]) {
        lock.withLock {
            for instanceName in instanceNames {
                guard let configuration = configurationsByInstanceName.removeValue(
                    forKey: instanceName
                ) else { continue }
                configurationsByInstanceID.removeValue(forKey: configuration.instanceID)
            }
        }
    }

    package func retain(instanceNames: [String]) {
        let retainedNames = Set(instanceNames)
        lock.withLock {
            configurationsByInstanceName = configurationsByInstanceName.filter {
                retainedNames.contains($0.key)
            }
            let retainedIDs = Set(configurationsByInstanceName.values.map(\.instanceID))
            configurationsByInstanceID = configurationsByInstanceID.filter {
                retainedIDs.contains($0.key)
            }
        }
    }

    package func configuration(
        instanceName: String,
        instanceID: String? = nil
    ) -> AppliedMagicDNSConfiguration? {
        lock.withLock {
            if let configuration = configurationsByInstanceName[instanceName] {
                return configuration
            }
            return instanceID.flatMap { configurationsByInstanceID[$0] }
        }
    }
}
