import Foundation
import Testing
@testable import EasyTierShared

@Test func appliedMagicDNSConfigurationTracksExactRuntimeTOML() throws {
    var config = NetworkConfig(instance_id: "instance-a", network_name: "mesh")
    config.enable_magic_dns = true
    let customTOML = try NetworkConfigTOMLCodec.encode(
        config,
        magicDNSSettings: try MagicDNSSettings(dnsSuffix: "lab.internal")
    )
    let custom = try AppliedMagicDNSConfiguration(runtimeTOML: customTOML)
    #expect(custom.instanceID == "instance-a")
    #expect(custom.instanceName == "mesh")
    #expect(custom.enabled)
    #expect(custom.suffix == "lab.internal.")

    let defaultSuffix = try AppliedMagicDNSConfiguration(
        runtimeTOML: NetworkConfigTOMLCodec.encode(config)
    )
    #expect(defaultSuffix.suffix == MagicDNSSettings.defaultDNSSuffix)

    config.enable_magic_dns = false
    let disabled = try AppliedMagicDNSConfiguration(
        runtimeTOML: NetworkConfigTOMLCodec.encode(config)
    )
    #expect(!disabled.enabled)
    #expect(disabled.suffix == nil)
}

@Test func appliedMagicDNSRegistryFollowsHelperLifecycle() {
    let registry = AppliedMagicDNSRegistry()
    let first = AppliedMagicDNSConfiguration(
        instanceID: "a",
        instanceName: "alpha",
        enabled: true,
        suffix: "et.net."
    )
    let second = AppliedMagicDNSConfiguration(
        instanceID: "b",
        instanceName: "beta",
        enabled: false,
        suffix: nil
    )
    registry.record(first)
    registry.record(second)
    #expect(registry.configuration(instanceName: "alpha") == first)
    registry.remove(instanceNames: ["alpha"])
    #expect(registry.configuration(instanceName: "alpha") == nil)
    registry.retain(instanceNames: ["beta"])
    #expect(registry.configuration(instanceName: "beta") == second)
    registry.retain(instanceNames: [])
    #expect(registry.configuration(instanceName: "beta") == nil)
}

@Test func runtimeInfoAugmentationRoundTripsAppliedMagicDNSFields() throws {
    let configuration = AppliedMagicDNSConfiguration(
        instanceID: "a",
        instanceName: "alpha",
        enabled: true,
        suffix: "et.net."
    )
    let payload = try NetworkInfoMagicDNSAugmenter.augment(
        payload: #"{"running":true,"instance_id":"a"}"#,
        with: configuration
    )
    let decoded = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(payload.utf8))
    #expect(decoded.applied_magic_dns_enabled == true)
    #expect(decoded.applied_magic_dns_suffix == "et.net.")
}

@Test func transientlyEmptyRuntimeCollectionDoesNotForgetAppliedMagicDNS() throws {
    let registry = AppliedMagicDNSRegistry()
    registry.record(
        AppliedMagicDNSConfiguration(
            instanceID: "instance-a",
            instanceName: "mesh",
            enabled: true,
            suffix: "et.net."
        )
    )

    let empty = try NetworkInfoMagicDNSAugmenter.augment(payloads: [], using: registry)
    #expect(empty.isEmpty)

    let resumed = try NetworkInfoMagicDNSAugmenter.augment(
        payloads: [(key: "mesh", value: #"{"running":true,"instance_id":"instance-a"}"#)],
        using: registry
    )
    let payload = try #require(resumed.first?.value)
    let decoded = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(payload.utf8))
    #expect(decoded.applied_magic_dns_enabled == true)
    #expect(decoded.applied_magic_dns_suffix == "et.net.")
}
