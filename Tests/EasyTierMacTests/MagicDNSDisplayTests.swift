import EasyTierShared
import Testing
@testable import EasyTierMac

@Test func memberDomainRequiresMagicDNSToBeEnabled() throws {
    var config = NetworkConfig()
    let settings = try MagicDNSSettings(dnsSuffix: "lab.internal")

    #expect(MagicDNSDisplay.memberDomain(hostname: "macbook", config: config, settings: settings) == nil)

    config.enable_magic_dns = true
    #expect(
        MagicDNSDisplay.memberDomain(hostname: "macbook", config: config, settings: settings)
            == "macbook.lab.internal"
    )
}

@Test func memberDomainRejectsMissingHostnames() {
    var config = NetworkConfig()
    config.enable_magic_dns = true

    #expect(MagicDNSDisplay.memberDomain(hostname: "", config: config, settings: .default) == nil)
    #expect(MagicDNSDisplay.memberDomain(hostname: "   ", config: config, settings: .default) == nil)
    #expect(MagicDNSDisplay.memberDomain(hostname: "-", config: config, settings: .default) == nil)
}
