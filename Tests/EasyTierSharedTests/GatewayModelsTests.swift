import Foundation
import Testing
@testable import EasyTierShared

@Test func gatewayConfigurationUsesTheVersionedRustJSONShape() throws {
    let configuration = gatewayTestConfiguration()
    let data = try JSONEncoder().encode(configuration)
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let acme = try #require(object["acme"] as? [String: Any])
    let certificates = try #require(object["certificates"] as? [[String: Any]])
    let certificate = try #require(certificates.first)
    let challenge = try #require(certificate["challenge"] as? [String: Any])

    #expect((object["schema_version"] as? NSNumber)?.uint32Value == GatewaySchema.version)
    #expect(acme["directory"] == nil)
    #expect(acme["contact_email"] as? String == "ops@example.com")
    #expect(certificate["authority"] as? String == "letsencrypt")
    #expect(challenge["type"] as? String == "http01")
    #expect(object["storage_dir"] == nil)
    #expect(object["listeners"] == nil)
    #expect(try JSONDecoder().decode(GatewayConfiguration.self, from: data) == configuration)
}

@Test func gatewayFactoryCarriesExactExpectedTargetIPv4() throws {
    let state = GatewayPersistedState(
        gatewayEnabled: true,
        acmeAccount: GatewayACMEConfiguration(
            contactEmail: "ops@example.com",
            termsOfServiceAgreed: true
        ),
        publishingNetworkConfigID: "network-a",
        lastKnownNetworkIPv4CIDR: "10.0.0.0/24",
        services: [
            GatewayPublishedService(
                id: "service-a",
                networkConfigID: "network-a",
                targetPeerID: "peer-a",
                publicNodeLabel: "alpha",
                publicDNSSuffix: "et.net.",
                lastKnownTargetHostname: "alpha",
                lastKnownMagicDNSSuffix: "et.net.",
                serviceLabel: "web",
                publicHostname: "web.alpha.et.net",
                targetPort: 3_000,
                desiredEnabled: true
            ),
        ]
    )
    let configuration = try GatewayConfigurationFactory.makeRuntimeConfiguration(
        from: state,
        expectedIPv4ByServiceID: ["service-a": "10.0.0.42"]
    )
    #expect(configuration.routes.first?.upstream.availability == .ready)
    #expect(configuration.routes.first?.upstream.expectedIPv4 == "10.0.0.42")

    let unavailable = try GatewayConfigurationFactory.makeRuntimeConfiguration(from: state)
    #expect(unavailable.routes.first?.upstream.availability == .unavailable)
    #expect(unavailable.routes.first?.upstream.expectedIPv4 == nil)
}

@Test func gatewayValidationRejectsExpectedIPv4OutsideEasyTierCIDR() {
    let configuration = GatewayConfiguration(
        acme: GatewayACMEConfiguration(termsOfServiceAgreed: true),
        routes: [
            GatewayRouteConfiguration(
                domain: "web.example.com",
                certificateID: "service-a",
                upstream: GatewayUpstreamConfiguration(
                    url: "http://alpha.et.net:3000",
                    allowedIPv4CIDR: "10.0.0.0/24",
                    expectedIPv4: "10.0.1.42"
                )
            ),
        ]
    )
    #expect(throws: GatewayConfigurationValidationError.self) {
        try GatewayConfigurationValidator.validate(configuration)
    }
}

@Test func helperRuntimeConfigurationInjectsOnlyPrivilegedFields() throws {
    let runtime = GatewayFFIConfiguration(
        configuration: gatewayTestConfiguration(),
        storageDirectory: "/Library/Application Support/EasyTier/Gateway/501/runtime",
        httpListener: "0.0.0.0:80",
        httpsListener: "127.0.0.1:443",
        dnsListener: "127.0.0.1:53535"
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(runtime)) as? [String: Any]
    )
    let listeners = try #require(object["listeners"] as? [String: String])

    #expect(object["storage_dir"] as? String == "/Library/Application Support/EasyTier/Gateway/501/runtime")
    #expect(listeners == [
        "http": "0.0.0.0:80",
        "https": "127.0.0.1:443",
        "dns": "127.0.0.1:53535",
    ])
    let localDNS = try #require(object["local_dns"] as? [String: Any])
    #expect(localDNS["domains"] as? [String] == ["app.example.com"])
    #expect(localDNS["answer_ipv4"] as? String == "127.0.0.1")
}

@Test func gatewayValidationNormalizesDomainsAndOptionalHeaders() throws {
    var configuration = gatewayTestConfiguration()
    configuration.certificates[0].domains = ["App.Example.COM."]
    configuration.routes[0].domain = " app.example.com. "
    configuration.routes[0].upstream.hostHeader = "  backend.internal  "

    let normalized = try GatewayConfigurationValidator.validate(configuration)

    #expect(normalized.certificates[0].domains == ["app.example.com"])
    #expect(normalized.routes[0].domain == "app.example.com")
    #expect(normalized.routes[0].upstream.hostHeader == "backend.internal")
}

@Test(arguments: ["*.example.com", "127.0.0.1", "bad domain.example"])
func gatewayValidationRejectsNonExactCertificateDomains(_ domain: String) {
    var configuration = gatewayTestConfiguration()
    configuration.certificates[0].domains = [domain]

    #expect(throws: GatewayConfigurationValidationError.self) {
        try GatewayConfigurationValidator.validate(configuration)
    }
}

@Test func gatewayConfigurationDecodesDNS01() throws {
    let data = Data(
        """
        {
          "schema_version": 5,
          "acme": {
            "contact_email": "ops@example.com",
            "terms_of_service_agreed": true
          },
          "certificates": [{
            "id": "app-cert",
            "domains": ["app.example.com"],
            "authority": "zerossl",
            "challenge": {
              "type": "dns01",
              "provider": "cloudflare",
              "credential_id": "main"
            }
          }],
          "routes": [],
          "local_domains": []
        }
        """.utf8
    )

    let configuration = try JSONDecoder().decode(GatewayConfiguration.self, from: data)
    #expect(
        configuration.certificates.first?.challenge
            == .dns01(GatewayDNS01Configuration(provider: .cloudflare, credentialID: "main"))
    )
    #expect(configuration.certificates.first?.authority == .zeroSSL)
}

@Test func publishedServicePersistsAnExplicitCertificatePolicy() throws {
    let state = gatewayPersistedTestState()
    let data = try JSONEncoder().encode(state)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let services = try #require(object["services"] as? [[String: Any]])
    let policy = try #require(services.first?["certificate_policy"] as? [String: Any])
    let challenge = try #require(policy["challenge"] as? [String: Any])

    #expect(policy["authority"] as? String == "letsencrypt")
    #expect(challenge["type"] as? String == "http01")
}

@Test func allCertificatePoliciesRoundTrip() throws {
    for authority in GatewayCertificateAuthority.allCases {
        for challenge in [
            GatewayPublishedServiceChallenge.http01,
            .dns01(credentialID: "dns-main"),
        ] {
            var state = gatewayPersistedTestState()
            state.services[0].certificatePolicy = GatewayCertificatePolicy(
                authority: authority,
                challenge: challenge
            )

            let decoded = try JSONDecoder().decode(
                GatewayPersistedState.self,
                from: JSONEncoder().encode(state)
            )

            #expect(decoded == state)
        }
    }
}

@Test func newPublishedServicesDefaultToLetsEncryptHTTP01() throws {
    let draft = try GatewayPublishedServicesValidator.makeDraft(
        networkConfigID: "network-a",
        targetPeerID: "peer-a",
        targetHostname: "alpha",
        magicDNSSuffix: "et.net",
        serviceLabel: "web",
        targetPort: 443
    )

    #expect(draft.certificatePolicy == GatewayCertificatePolicy(
        authority: .letsEncrypt,
        challenge: .http01
    ))
}

@Test func runtimeCertificateRejectsMissingAuthorityAndAutomaticChallenge() throws {
    let missingAuthority = Data(
        """
        {
          "id": "app-cert",
          "domains": ["app.example.com"],
          "challenge": {"type": "http01"}
        }
        """.utf8
    )
    let automaticChallenge = Data(
        """
        {
          "id": "app-cert",
          "domains": ["app.example.com"],
          "authority": "letsencrypt",
          "challenge": {"type": "automatic"}
        }
        """.utf8
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(GatewayCertificateConfiguration.self, from: missingAuthority)
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(GatewayCertificateConfiguration.self, from: automaticChallenge)
    }
}

@Test func gatewayConfigurationStorePersistsAtomicallyWithPrivatePermissions() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GatewayConfigurationStoreTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("gateway/config.json")
    let store = GatewayConfigurationStore(fileURL: fileURL)
    let state = gatewayPersistedTestState()

    try await store.save(state)
    let loaded = try await store.load()
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(
        atPath: fileURL.deletingLastPathComponent().path
    )

    #expect(loaded == state)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test func publishedServiceDraftBuildsTheImmutablePublicHostname() throws {
    let draft = try GatewayPublishedServicesValidator.makeDraft(
        networkConfigID: "network-a",
        targetPeerID: "peer-a",
        targetHostname: "A",
        magicDNSSuffix: "ET.NET",
        serviceLabel: "ABC",
        targetPort: 3_000
    )

    #expect(draft.publicHostname == "abc.a.et.net")
    #expect(draft.targetDomain == "a.et.net")
    #expect(!draft.desiredEnabled)
}

@Test func publishedServicesRejectMultipleOwningNetworks() {
    var state = gatewayPersistedTestState()
    var second = state.services[0]
    second.id = "service-b"
    second.networkConfigID = "network-b"
    second.serviceLabel = "web"
    second.publicHostname = "web.a.et.net"
    state.services.append(second)

    #expect(throws: GatewayConfigurationValidationError.self) {
        try GatewayPublishedServicesValidator.validate(state)
    }
}

@Test func publishedServicesFactoryDerivesCertificatesRoutesAndLocalDNS() throws {
    let configuration = try GatewayConfigurationFactory.makeRuntimeConfiguration(
        from: gatewayPersistedTestState()
    )

    #expect(configuration.certificates.first?.authority == .letsEncrypt)
    #expect(configuration.certificates.map(\.domains) == [["abc.a.et.net"]])
    #expect(configuration.routes.first?.upstream.url == "http://a.et.net:3000")
    #expect(configuration.routes.first?.upstream.allowedIPv4CIDR == "10.0.0.0/24")
    #expect(configuration.localDomains == ["abc.a.et.net"])
}

@Test func gatewayFactoryBuildsAnEmptyRuntimeWithoutACMETerms() throws {
    let state = GatewayPersistedState(gatewayEnabled: true)

    let configuration = try GatewayConfigurationFactory.makeRuntimeConfiguration(from: state)

    #expect(configuration.certificates.isEmpty)
    #expect(configuration.routes.isEmpty)
    #expect(configuration.localDomains.isEmpty)
    #expect(!configuration.acme.termsOfServiceAgreed)
}

@Test func gatewayStateWithoutMasterSwitchMigratesExistingServiceIntent() throws {
    let encoded = try JSONEncoder().encode(gatewayPersistedTestState())
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "gateway_enabled")

    let migrated = try JSONDecoder().decode(
        GatewayPersistedState.self,
        from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(migrated.gatewayEnabled)
}

@Test func publishedServicePersistsStableInstanceIdentityAndDecodesLegacyRecords() throws {
    var state = gatewayPersistedTestState()
    state.services[0].targetInstanceID = "instance-a"

    let encoded = try JSONEncoder().encode(state)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var services = try #require(object["services"] as? [[String: Any]])
    #expect(services.first?["target_instance_id"] as? String == "instance-a")
    #expect(try JSONDecoder().decode(GatewayPersistedState.self, from: encoded) == state)

    services[0].removeValue(forKey: "target_instance_id")
    object["services"] = services
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let legacyState = try JSONDecoder().decode(GatewayPersistedState.self, from: legacyData)

    #expect(legacyState.services.first?.targetInstanceID == nil)
}

@Test func incompatibleGatewayConfigurationIsBackedUpAndNotOverwritten() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GatewayConfigurationStoreTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("gateway/config.json")
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(
        """
        {
          "enabled": true,
          "configuration": {
            "schema_version": 1,
            "acme": {
              "directory": {"kind": "letsencrypt_staging"},
              "contact_email": null,
              "terms_of_service_agreed": true
            },
            "certificates": [],
            "routes": []
          }
        }
        """.utf8
    ).write(to: fileURL)
    let store = GatewayConfigurationStore(fileURL: fileURL)

    await #expect(throws: GatewayConfigurationStoreError.self) {
        try await store.load()
    }
    let files = try FileManager.default.contentsOfDirectory(
        at: fileURL.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
    )
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(files.contains { $0.lastPathComponent.hasPrefix("config.incompatible-") })
}

@Test func semanticallyIncompatibleGatewayConfigurationIsBackedUp() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GatewayConfigurationStoreTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("gateway/config.json")
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let state = GatewayPersistedState(schemaVersion: GatewaySchema.version + 1)
    try JSONEncoder().encode(state).write(to: fileURL)
    let store = GatewayConfigurationStore(fileURL: fileURL)

    await #expect(throws: GatewayConfigurationStoreError.self) {
        try await store.load()
    }
    let files = try FileManager.default.contentsOfDirectory(
        at: fileURL.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
    )
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(files.contains { $0.lastPathComponent.hasPrefix("config.incompatible-") })
}

@Test func releaseHelperRequirementPinsBundleAndTeamWhileDebugRemainsExplicit() {
    #expect(PrivilegedHelperClientRequirement.release.contains("com.kkrainbow.easytier.mac"))
    #expect(PrivilegedHelperClientRequirement.release.contains("84K5NV46VA"))
    #expect(PrivilegedHelperClientRequirement.release.contains("anchor apple generic"))
    #expect(PrivilegedHelperClientRequirement.debug == "identifier \"com.kkrainbow.easytier.mac\"")
}

private func gatewayTestConfiguration() -> GatewayConfiguration {
    GatewayConfiguration(
        acme: GatewayACMEConfiguration(
            contactEmail: "ops@example.com",
            termsOfServiceAgreed: true
        ),
        certificates: [
            GatewayCertificateConfiguration(
                id: "app-cert",
                domains: ["app.example.com"]
            ),
        ],
        routes: [
            GatewayRouteConfiguration(
                domain: "app.example.com",
                certificateID: "app-cert",
                upstream: GatewayUpstreamConfiguration(
                    url: "http://127.0.0.1:8080",
                    allowedIPv4CIDR: "10.0.0.0/24"
                )
            ),
        ],
        localDomains: ["app.example.com"]
    )
}

private func gatewayPersistedTestState() -> GatewayPersistedState {
    GatewayPersistedState(
        gatewayEnabled: true,
        acmeAccount: GatewayACMEConfiguration(
            contactEmail: "ops@example.com",
            termsOfServiceAgreed: true
        ),
        publishingNetworkConfigID: "network-a",
        lastKnownNetworkIPv4CIDR: "10.0.0.0/24",
        services: [
            GatewayPublishedService(
                id: "service-a",
                networkConfigID: "network-a",
                targetPeerID: "peer-a",
                publicNodeLabel: "a",
                publicDNSSuffix: "et.net.",
                lastKnownTargetHostname: "a",
                lastKnownMagicDNSSuffix: "et.net.",
                serviceLabel: "abc",
                publicHostname: "abc.a.et.net",
                targetPort: 3_000,
                desiredEnabled: true
            ),
        ]
    )
}
