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
    let directory = try #require(acme["directory"] as? [String: Any])
    let certificates = try #require(object["certificates"] as? [[String: Any]])
    let challenge = try #require(certificates.first?["challenge"] as? [String: Any])

    #expect((object["schema_version"] as? NSNumber)?.uint32Value == 1)
    #expect(directory["kind"] as? String == "letsencrypt_staging")
    #expect(acme["contact_email"] as? String == "ops@example.com")
    #expect(challenge["type"] as? String == "http01")
    #expect(object["storage_dir"] == nil)
    #expect(object["listeners"] == nil)
    #expect(try JSONDecoder().decode(GatewayConfiguration.self, from: data) == configuration)
}

@Test func helperRuntimeConfigurationInjectsOnlyPrivilegedFields() throws {
    let runtime = GatewayFFIConfiguration(
        configuration: gatewayTestConfiguration(),
        storageDirectory: "/Library/Application Support/EasyTier/Gateway/501/runtime",
        httpListener: "0.0.0.0:80",
        httpsListener: "0.0.0.0:443"
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(runtime)) as? [String: Any]
    )
    let listeners = try #require(object["listeners"] as? [String: String])

    #expect(object["storage_dir"] as? String == "/Library/Application Support/EasyTier/Gateway/501/runtime")
    #expect(listeners == ["http": "0.0.0.0:80", "https": "0.0.0.0:443"])
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

@Test func gatewayConfigurationRejectsDNS01AtDecodeBoundary() {
    let data = Data(
        """
        {
          "schema_version": 1,
          "acme": {
            "directory": {"kind": "letsencrypt_staging"},
            "contact_email": "ops@example.com",
            "terms_of_service_agreed": true
          },
          "certificates": [{
            "id": "app-cert",
            "domains": ["app.example.com"],
            "challenge": {
              "type": "dns01",
              "provider": "cloudflare",
              "credential_id": "main"
            }
          }],
          "routes": []
        }
        """.utf8
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(GatewayConfiguration.self, from: data)
    }
}

@Test func gatewayConfigurationStorePersistsAtomicallyWithPrivatePermissions() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GatewayConfigurationStoreTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("gateway/config.json")
    let store = GatewayConfigurationStore(fileURL: fileURL)
    let state = GatewayPersistedState(
        enabled: true,
        configuration: gatewayTestConfiguration()
    )

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
    try Data("not-json".utf8).write(to: fileURL)
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
    var configuration = gatewayTestConfiguration()
    configuration.schemaVersion = GatewaySchema.version + 1
    let state = GatewayPersistedState(enabled: true, configuration: configuration)
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

private func gatewayTestConfiguration(
    directory: GatewayACMEDirectory = .letsencryptStaging
) -> GatewayConfiguration {
    GatewayConfiguration(
        acme: GatewayACMEConfiguration(
            directory: directory,
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
                    url: "http://127.0.0.1:8080"
                )
            ),
        ]
    )
}
