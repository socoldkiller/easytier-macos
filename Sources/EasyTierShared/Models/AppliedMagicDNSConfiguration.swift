import Foundation

package struct AppliedMagicDNSConfiguration: Equatable, Sendable {
    package var instanceID: String
    package var instanceName: String
    package var enabled: Bool
    package var suffix: String?

    package init(
        instanceID: String,
        instanceName: String,
        enabled: Bool,
        suffix: String?
    ) {
        self.instanceID = instanceID
        self.instanceName = instanceName
        self.enabled = enabled
        self.suffix = suffix
    }

    package init(runtimeTOML: String) throws {
        let config = try NetworkConfigTOMLCodec.decode(runtimeTOML)
        let enabled = config.enable_magic_dns == true
        let rawSuffix = try NetworkConfigTOMLCodec.metadata(from: runtimeTOML).magicDNSSuffix

        instanceID = config.instance_id
        instanceName = config.network_name.isEmpty ? config.instance_id : config.network_name
        self.enabled = enabled
        suffix = enabled
            ? try MagicDNSSettings.normalizedDNSSuffix(rawSuffix ?? MagicDNSSettings.defaultDNSSuffix)
            : nil
    }
}
