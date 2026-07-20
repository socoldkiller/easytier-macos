import Foundation

package enum GatewaySchema {
    package static let version: UInt32 = 4
    package static let persistedVersion: UInt32 = 3
    package static let runtimeVersion: UInt32 = version
}

package struct GatewayConfiguration: Codable, Equatable, Sendable {
    package var schemaVersion: UInt32
    package var acme: GatewayACMEConfiguration
    package var certificates: [GatewayCertificateConfiguration]
    package var routes: [GatewayRouteConfiguration]
    package var localDomains: [String]

    package init(
        schemaVersion: UInt32 = GatewaySchema.runtimeVersion,
        acme: GatewayACMEConfiguration,
        certificates: [GatewayCertificateConfiguration] = [],
        routes: [GatewayRouteConfiguration] = [],
        localDomains: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.acme = acme
        self.certificates = certificates
        self.routes = routes
        self.localDomains = localDomains
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case acme
        case certificates
        case routes
        case localDomains = "local_domains"
    }
}

package struct GatewayACMEConfiguration: Codable, Equatable, Sendable {
    package var directory: GatewayACMEDirectory
    package var contactEmail: String?
    package var termsOfServiceAgreed: Bool

    package init(
        directory: GatewayACMEDirectory = .letsencryptProduction,
        contactEmail: String? = nil,
        termsOfServiceAgreed: Bool
    ) {
        self.directory = directory
        self.contactEmail = contactEmail
        self.termsOfServiceAgreed = termsOfServiceAgreed
    }

    private enum CodingKeys: String, CodingKey {
        case directory
        case contactEmail = "contact_email"
        case termsOfServiceAgreed = "terms_of_service_agreed"
    }
}

package enum GatewayACMEDirectory: Equatable, Sendable {
    case letsencryptStaging
    case letsencryptProduction
}

extension GatewayACMEDirectory: Codable {
    private enum CodingKeys: String, CodingKey { case kind }
    private enum Kind: String, Codable {
        case letsencryptStaging = "letsencrypt_staging"
        case letsencryptProduction = "letsencrypt_production"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .letsencryptStaging:
            self = .letsencryptStaging
        case .letsencryptProduction:
            self = .letsencryptProduction
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let kind: Kind = switch self {
        case .letsencryptStaging: .letsencryptStaging
        case .letsencryptProduction: .letsencryptProduction
        }
        try container.encode(kind, forKey: .kind)
    }
}

package struct GatewayCertificateConfiguration: Codable, Equatable, Sendable {
    package var id: String
    package var domains: [String]
    package var challenge: GatewayChallengeConfiguration

    package init(
        id: String,
        domains: [String],
        challenge: GatewayChallengeConfiguration = .http01
    ) {
        self.id = id
        self.domains = domains
        self.challenge = challenge
    }
}

package struct GatewayDNS01Configuration: Codable, Equatable, Sendable {
    package var provider: GatewayDNSProvider
    package var credentialID: String

    package init(provider: GatewayDNSProvider, credentialID: String) {
        self.provider = provider
        self.credentialID = credentialID
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case credentialID = "credential_id"
    }
}

package enum GatewayDNSProvider: String, Codable, Equatable, Sendable {
    case cloudflare
    case aliyun
}

package enum GatewayChallengeConfiguration: Equatable, Sendable {
    case automatic(dns01: GatewayDNS01Configuration?)
    case http01
    case dns01(GatewayDNS01Configuration)
}

extension GatewayChallengeConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case dns01
        case provider
        case credentialID = "credential_id"
    }
    private enum Kind: String, Codable {
        case automatic
        case http01
        case dns01
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .automatic:
            self = .automatic(
                dns01: try container.decodeIfPresent(
                    GatewayDNS01Configuration.self,
                    forKey: .dns01
                )
            )
        case .http01:
            self = .http01
        case .dns01:
            self = .dns01(
                GatewayDNS01Configuration(
                    provider: try container.decode(GatewayDNSProvider.self, forKey: .provider),
                    credentialID: try container.decode(String.self, forKey: .credentialID)
                )
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .automatic(dns01):
            try container.encode(Kind.automatic, forKey: .type)
            try container.encodeIfPresent(dns01, forKey: .dns01)
        case .http01:
            try container.encode(Kind.http01, forKey: .type)
        case let .dns01(configuration):
            try container.encode(Kind.dns01, forKey: .type)
            try container.encode(configuration.provider, forKey: .provider)
            try container.encode(configuration.credentialID, forKey: .credentialID)
        }
    }
}

package struct GatewayRouteConfiguration: Codable, Equatable, Sendable {
    package var domain: String
    package var certificateID: String
    package var upstream: GatewayUpstreamConfiguration

    package init(
        domain: String,
        certificateID: String,
        upstream: GatewayUpstreamConfiguration
    ) {
        self.domain = domain
        self.certificateID = certificateID
        self.upstream = upstream
    }

    private enum CodingKeys: String, CodingKey {
        case domain
        case certificateID = "certificate_id"
        case upstream
    }
}

package struct GatewayUpstreamConfiguration: Codable, Equatable, Sendable {
    package var url: String
    package var hostHeader: String?
    package var tlsServerName: String?
    package var allowedIPv4CIDR: String?
    package var availability: GatewayUpstreamAvailability
    package var expectedIPv4: String?

    package init(
        url: String,
        hostHeader: String? = nil,
        tlsServerName: String? = nil,
        allowedIPv4CIDR: String? = nil,
        availability: GatewayUpstreamAvailability = .ready,
        expectedIPv4: String? = nil
    ) {
        self.url = url
        self.hostHeader = hostHeader
        self.tlsServerName = tlsServerName
        self.allowedIPv4CIDR = allowedIPv4CIDR
        self.availability = availability
        self.expectedIPv4 = expectedIPv4
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case hostHeader = "host_header"
        case tlsServerName = "tls_server_name"
        case allowedIPv4CIDR = "allowed_ipv4_cidr"
        case availability
        case expectedIPv4 = "expected_ipv4"
    }
}

package enum GatewayUpstreamAvailability: String, Codable, Equatable, Sendable {
    case waiting
    case unavailable
    case ready
}

package struct GatewayPersistedState: Codable, Equatable, Sendable {
    package var schemaVersion: UInt32
    package var gatewayEnabled: Bool
    package var acmeAccount: GatewayACMEConfiguration?
    package var publishingNetworkConfigID: String?
    package var lastKnownNetworkIPv4CIDR: String?
    package var dnsCredentials: [GatewayDNSCredentialDescriptor]
    package var services: [GatewayPublishedService]

    package init(
        schemaVersion: UInt32 = GatewaySchema.persistedVersion,
        gatewayEnabled: Bool = false,
        acmeAccount: GatewayACMEConfiguration? = nil,
        publishingNetworkConfigID: String? = nil,
        lastKnownNetworkIPv4CIDR: String? = nil,
        dnsCredentials: [GatewayDNSCredentialDescriptor] = [],
        services: [GatewayPublishedService] = []
    ) {
        self.schemaVersion = schemaVersion
        self.gatewayEnabled = gatewayEnabled
        self.acmeAccount = acmeAccount
        self.publishingNetworkConfigID = publishingNetworkConfigID
        self.lastKnownNetworkIPv4CIDR = lastKnownNetworkIPv4CIDR
        self.dnsCredentials = dnsCredentials
        self.services = services
    }

    package static let empty = GatewayPersistedState()

    package var desiredEnabled: Bool {
        gatewayEnabled
    }

    package var hasEnabledServices: Bool {
        services.contains(where: \.desiredEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case gatewayEnabled = "gateway_enabled"
        case acmeAccount = "acme_account"
        case publishingNetworkConfigID = "publishing_network_config_id"
        case lastKnownNetworkIPv4CIDR = "last_known_network_ipv4_cidr"
        case dnsCredentials = "dns_credentials"
        case services
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        schemaVersion = decodedVersion == 2 ? GatewaySchema.persistedVersion : decodedVersion
        acmeAccount = try container.decodeIfPresent(GatewayACMEConfiguration.self, forKey: .acmeAccount)
        publishingNetworkConfigID = try container.decodeIfPresent(
            String.self,
            forKey: .publishingNetworkConfigID
        )
        lastKnownNetworkIPv4CIDR = try container.decodeIfPresent(
            String.self,
            forKey: .lastKnownNetworkIPv4CIDR
        )
        dnsCredentials = try container.decodeIfPresent(
            [GatewayDNSCredentialDescriptor].self,
            forKey: .dnsCredentials
        ) ?? []
        services = try container.decodeIfPresent([GatewayPublishedService].self, forKey: .services) ?? []
        gatewayEnabled = try container.decodeIfPresent(Bool.self, forKey: .gatewayEnabled)
            ?? services.contains(where: \.desiredEnabled)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(gatewayEnabled, forKey: .gatewayEnabled)
        try container.encodeIfPresent(acmeAccount, forKey: .acmeAccount)
        try container.encodeIfPresent(publishingNetworkConfigID, forKey: .publishingNetworkConfigID)
        try container.encodeIfPresent(lastKnownNetworkIPv4CIDR, forKey: .lastKnownNetworkIPv4CIDR)
        try container.encode(dnsCredentials, forKey: .dnsCredentials)
        try container.encode(services, forKey: .services)
    }
}

package enum GatewayPublishedServiceUpstreamProtocol: String, Codable, Equatable, Sendable {
    case http
}

package struct GatewayDNSCredentialDescriptor: Codable, Equatable, Identifiable, Sendable {
    package var id: String
    package var provider: GatewayDNSProvider
    package var label: String
    package var revision: UInt64

    package init(
        id: String = UUID().uuidString.lowercased(),
        provider: GatewayDNSProvider,
        label: String,
        revision: UInt64 = 1
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.revision = revision
    }
}

package enum GatewayPublishedServiceChallenge: Equatable, Sendable {
    case automatic(dnsCredentialID: String?)
    case http01
    case dns01(credentialID: String)
}

extension GatewayPublishedServiceChallenge: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case dnsCredentialID = "dns_credential_id"
        case credentialID = "credential_id"
    }

    private enum Kind: String, Codable {
        case automatic
        case http01
        case dns01
    }

    package init(from decoder: any Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self), legacy == "http01" {
            self = .automatic(dnsCredentialID: nil)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .automatic:
            self = .automatic(
                dnsCredentialID: try container.decodeIfPresent(String.self, forKey: .dnsCredentialID)
            )
        case .http01:
            self = .http01
        case .dns01:
            self = .dns01(
                credentialID: try container.decode(String.self, forKey: .credentialID)
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .automatic(dnsCredentialID):
            try container.encode(Kind.automatic, forKey: .type)
            try container.encodeIfPresent(dnsCredentialID, forKey: .dnsCredentialID)
        case .http01:
            try container.encode(Kind.http01, forKey: .type)
        case let .dns01(credentialID):
            try container.encode(Kind.dns01, forKey: .type)
            try container.encode(credentialID, forKey: .credentialID)
        }
    }
}

package struct GatewayPublishedService: Codable, Equatable, Identifiable, Sendable {
    package var id: String
    package var networkConfigID: String
    package var targetPeerID: String
    package var targetInstanceID: String?
    package var publicNodeLabel: String
    package var publicDNSSuffix: String
    package var lastKnownTargetHostname: String
    package var lastKnownMagicDNSSuffix: String
    package var serviceLabel: String
    package var publicHostname: String
    package var targetPort: Int
    package var desiredEnabled: Bool
    package var upstreamProtocol: GatewayPublishedServiceUpstreamProtocol
    package var challenge: GatewayPublishedServiceChallenge

    package init(
        id: String = UUID().uuidString.lowercased(),
        networkConfigID: String,
        targetPeerID: String,
        targetInstanceID: String? = nil,
        publicNodeLabel: String,
        publicDNSSuffix: String,
        lastKnownTargetHostname: String,
        lastKnownMagicDNSSuffix: String,
        serviceLabel: String,
        publicHostname: String,
        targetPort: Int,
        desiredEnabled: Bool = false,
        upstreamProtocol: GatewayPublishedServiceUpstreamProtocol = .http,
        challenge: GatewayPublishedServiceChallenge = .automatic(dnsCredentialID: nil)
    ) {
        self.id = id
        self.networkConfigID = networkConfigID
        self.targetPeerID = targetPeerID
        self.targetInstanceID = targetInstanceID
        self.publicNodeLabel = publicNodeLabel
        self.publicDNSSuffix = publicDNSSuffix
        self.lastKnownTargetHostname = lastKnownTargetHostname
        self.lastKnownMagicDNSSuffix = lastKnownMagicDNSSuffix
        self.serviceLabel = serviceLabel
        self.publicHostname = publicHostname
        self.targetPort = targetPort
        self.desiredEnabled = desiredEnabled
        self.upstreamProtocol = upstreamProtocol
        self.challenge = challenge
    }

    package var targetDomain: String {
        let suffix = lastKnownMagicDNSSuffix.hasSuffix(".")
            ? String(lastKnownMagicDNSSuffix.dropLast())
            : lastKnownMagicDNSSuffix
        return "\(lastKnownTargetHostname).\(suffix)"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case networkConfigID = "network_config_id"
        case targetPeerID = "target_peer_id"
        case targetInstanceID = "target_instance_id"
        case publicNodeLabel = "public_node_label"
        case publicDNSSuffix = "public_dns_suffix"
        case lastKnownTargetHostname = "last_known_target_hostname"
        case lastKnownMagicDNSSuffix = "last_known_magic_dns_suffix"
        case serviceLabel = "service_label"
        case publicHostname = "public_hostname"
        case targetPort = "target_port"
        case desiredEnabled = "desired_enabled"
        case upstreamProtocol = "upstream_protocol"
        case challenge
    }
}

package struct GatewayFFIConfiguration: Codable, Equatable, Sendable {
    package var schemaVersion: UInt32
    package var storageDirectory: String
    package var listeners: GatewayListenerConfiguration
    package var localDNS: GatewayLocalDNSConfiguration
    package var acme: GatewayACMEConfiguration
    package var certificates: [GatewayCertificateConfiguration]
    package var routes: [GatewayRouteConfiguration]

    package init(
        configuration: GatewayConfiguration,
        storageDirectory: String,
        httpListener: String,
        httpsListener: String,
        dnsListener: String
    ) {
        schemaVersion = configuration.schemaVersion
        self.storageDirectory = storageDirectory
        listeners = GatewayListenerConfiguration(
            http: httpListener,
            https: httpsListener,
            dns: dnsListener
        )
        localDNS = GatewayLocalDNSConfiguration(
            domains: configuration.localDomains,
            answerIPv4: "127.0.0.1",
            ttl: 30
        )
        acme = configuration.acme
        certificates = configuration.certificates
        routes = configuration.routes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case storageDirectory = "storage_dir"
        case listeners
        case localDNS = "local_dns"
        case acme
        case certificates
        case routes
    }
}

package struct GatewayListenerConfiguration: Codable, Equatable, Sendable {
    package var http: String
    package var https: String
    package var dns: String
}

package struct GatewayLocalDNSConfiguration: Codable, Equatable, Sendable {
    package var domains: [String]
    package var answerIPv4: String
    package var ttl: UInt32

    private enum CodingKeys: String, CodingKey {
        case domains
        case answerIPv4 = "answer_ipv4"
        case ttl
    }
}

package struct GatewaySecrets: Codable, Equatable, Sendable {
    package var schemaVersion: UInt32
    package var cloudflare: [String: GatewayCloudflareSecret]
    package var aliyun: [String: GatewayAliyunSecret]

    package init(
        schemaVersion: UInt32 = GatewaySchema.runtimeVersion,
        cloudflare: [String: GatewayCloudflareSecret] = [:],
        aliyun: [String: GatewayAliyunSecret] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.cloudflare = cloudflare
        self.aliyun = aliyun
    }

    package static let empty = GatewaySecrets(
        schemaVersion: GatewaySchema.version,
        cloudflare: [:],
        aliyun: [:]
    )

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cloudflare
        case aliyun
    }
}

package struct GatewayCloudflareSecret: Codable, Equatable, Sendable {
    package var apiToken: String

    package init(apiToken: String) {
        self.apiToken = apiToken
    }

    private enum CodingKeys: String, CodingKey {
        case apiToken = "api_token"
    }
}

package struct GatewayAliyunSecret: Codable, Equatable, Sendable {
    package var accessKeyID: String
    package var accessKeySecret: String

    package init(accessKeyID: String, accessKeySecret: String) {
        self.accessKeyID = accessKeyID
        self.accessKeySecret = accessKeySecret
    }

    private enum CodingKeys: String, CodingKey {
        case accessKeyID = "access_key_id"
        case accessKeySecret = "access_key_secret"
    }
}

package struct GatewayStatus: Codable, Equatable, Sendable {
    package var schemaVersion: UInt32
    package var state: GatewayState
    package var configGeneration: UInt64
    package var listeners: GatewayListenerStatus
    package var routes: [GatewayRouteStatus]
    package var certificates: [GatewayCertificateStatus]
    package var pendingDNSCleanups: Int
    package var lastError: String?

    package static let stopped = GatewayStatus(
        schemaVersion: GatewaySchema.runtimeVersion,
        state: .stopped,
        configGeneration: 0,
        listeners: GatewayListenerStatus(http: nil, https: nil),
        routes: [],
        certificates: [],
        pendingDNSCleanups: 0,
        lastError: nil
    )

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case state
        case configGeneration = "config_generation"
        case listeners
        case routes
        case certificates
        case pendingDNSCleanups = "pending_dns_cleanups"
        case lastError = "last_error"
    }
}

package enum GatewayState: String, Codable, Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case failed
}

package struct GatewayListenerStatus: Codable, Equatable, Sendable {
    package var http: String?
    package var https: String?
    package var dns: String?

    package init(http: String?, https: String?, dns: String? = nil) {
        self.http = http
        self.https = https
        self.dns = dns
    }
}

package enum GatewayRouteResolutionState: String, Codable, Equatable, Sendable {
    case waiting
    case resolving
    case ready
    case mismatch
    case unavailable
}

package struct GatewayRouteStatus: Codable, Equatable, Sendable {
    package var domain: String
    package var upstream: String
    package var resolvedAddresses: [String]
    package var resolvedIPv4s: [String]
    package var expectedIPv4: String?
    package var certificateID: String
    package var resolutionState: GatewayRouteResolutionState
    package var lastResolvedAt: String?
    package var lastOnlineAt: String?
    package var lastError: String?

    package init(
        domain: String,
        upstream: String,
        resolvedAddresses: [String],
        resolvedIPv4s: [String] = [],
        expectedIPv4: String? = nil,
        certificateID: String,
        resolutionState: GatewayRouteResolutionState,
        lastResolvedAt: String? = nil,
        lastOnlineAt: String? = nil,
        lastError: String? = nil
    ) {
        self.domain = domain
        self.upstream = upstream
        self.resolvedAddresses = resolvedAddresses
        self.resolvedIPv4s = resolvedIPv4s
        self.expectedIPv4 = expectedIPv4
        self.certificateID = certificateID
        self.resolutionState = resolutionState
        self.lastResolvedAt = lastResolvedAt
        self.lastOnlineAt = lastOnlineAt
        self.lastError = lastError
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decode(String.self, forKey: .domain)
        upstream = try container.decode(String.self, forKey: .upstream)
        resolvedAddresses = try container.decodeIfPresent([String].self, forKey: .resolvedAddresses) ?? []
        resolvedIPv4s = try container.decodeIfPresent([String].self, forKey: .resolvedIPv4s) ?? []
        expectedIPv4 = try container.decodeIfPresent(String.self, forKey: .expectedIPv4)
        certificateID = try container.decode(String.self, forKey: .certificateID)
        resolutionState = try container.decode(GatewayRouteResolutionState.self, forKey: .resolutionState)
        lastResolvedAt = try container.decodeIfPresent(String.self, forKey: .lastResolvedAt)
        lastOnlineAt = try container.decodeIfPresent(String.self, forKey: .lastOnlineAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }

    private enum CodingKeys: String, CodingKey {
        case domain
        case upstream
        case resolvedAddresses = "resolved_addresses"
        case resolvedIPv4s = "resolved_ipv4s"
        case expectedIPv4 = "expected_ipv4"
        case certificateID = "certificate_id"
        case resolutionState = "resolution_state"
        case lastResolvedAt = "last_resolved_at"
        case lastOnlineAt = "last_online_at"
        case lastError = "last_error"
    }
}

package enum GatewayCertificateState: String, Codable, Equatable, Sendable {
    case pending
    case issuing
    case active
    case renewing
    case degraded
    case failed
}

package enum GatewayCertificateServingMode: String, Codable, Equatable, Sendable {
    case pendingHTTPS = "pending_https"
    case https
    case httpOnly = "http_only"
}

package struct GatewayCertificateStatus: Codable, Equatable, Sendable {
    package var id: String
    package var domains: [String]
    package var challenge: String
    package var state: GatewayCertificateState
    package var servingMode: GatewayCertificateServingMode
    package var notBefore: String?
    package var notAfter: String?
    package var nextRenewalAt: String?
    package var lastAttemptAt: String?
    package var lastError: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case domains
        case challenge
        case state
        case servingMode = "serving_mode"
        case notBefore = "not_before"
        case notAfter = "not_after"
        case nextRenewalAt = "next_renewal_at"
        case lastAttemptAt = "last_attempt_at"
        case lastError = "last_error"
    }
}
