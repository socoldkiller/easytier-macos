import Foundation

package enum GatewaySchema {
    package static let version: UInt32 = 1
}

package struct GatewayConfiguration: Codable, Equatable, Sendable {
    package var schemaVersion: UInt32
    package var acme: GatewayACMEConfiguration
    package var certificates: [GatewayCertificateConfiguration]
    package var routes: [GatewayRouteConfiguration]

    package init(
        schemaVersion: UInt32 = GatewaySchema.version,
        acme: GatewayACMEConfiguration,
        certificates: [GatewayCertificateConfiguration] = [],
        routes: [GatewayRouteConfiguration] = []
    ) {
        self.schemaVersion = schemaVersion
        self.acme = acme
        self.certificates = certificates
        self.routes = routes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case acme
        case certificates
        case routes
    }
}

package struct GatewayACMEConfiguration: Codable, Equatable, Sendable {
    package var directory: GatewayACMEDirectory
    package var contactEmail: String?
    package var termsOfServiceAgreed: Bool

    package init(
        directory: GatewayACMEDirectory = .letsencryptStaging,
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

package enum GatewayChallengeConfiguration: Equatable, Sendable {
    case http01
}

extension GatewayChallengeConfiguration: Codable {
    private enum CodingKeys: String, CodingKey { case type }
    private enum Kind: String, Codable { case http01 }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Kind.self, forKey: .type) == .http01 else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Gateway v1 supports only HTTP-01 challenges."
            )
        }
        self = .http01
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Kind.http01, forKey: .type)
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

    package init(url: String, hostHeader: String? = nil, tlsServerName: String? = nil) {
        self.url = url
        self.hostHeader = hostHeader
        self.tlsServerName = tlsServerName
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case hostHeader = "host_header"
        case tlsServerName = "tls_server_name"
    }
}

package struct GatewayPersistedState: Codable, Equatable, Sendable {
    package var schemaVersion: UInt32
    package var enabled: Bool
    package var configuration: GatewayConfiguration

    package init(
        schemaVersion: UInt32 = GatewaySchema.version,
        enabled: Bool,
        configuration: GatewayConfiguration
    ) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.configuration = configuration
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case enabled
        case configuration
    }
}

package struct GatewayFFIConfiguration: Codable, Equatable, Sendable {
    package var schemaVersion: UInt32
    package var storageDirectory: String
    package var listeners: GatewayListenerConfiguration
    package var acme: GatewayACMEConfiguration
    package var certificates: [GatewayCertificateConfiguration]
    package var routes: [GatewayRouteConfiguration]

    package init(
        configuration: GatewayConfiguration,
        storageDirectory: String,
        httpListener: String,
        httpsListener: String
    ) {
        schemaVersion = configuration.schemaVersion
        self.storageDirectory = storageDirectory
        listeners = GatewayListenerConfiguration(http: httpListener, https: httpsListener)
        acme = configuration.acme
        certificates = configuration.certificates
        routes = configuration.routes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case storageDirectory = "storage_dir"
        case listeners
        case acme
        case certificates
        case routes
    }
}

package struct GatewayListenerConfiguration: Codable, Equatable, Sendable {
    package var http: String
    package var https: String
}

package struct GatewaySecrets: Codable, Equatable, Sendable {
    package var schemaVersion: UInt32
    package var cloudflare: [String: GatewayCloudflareSecret]

    package static let empty = GatewaySecrets(
        schemaVersion: GatewaySchema.version,
        cloudflare: [:]
    )

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cloudflare
    }
}

package struct GatewayCloudflareSecret: Codable, Equatable, Sendable {
    package var apiToken: String

    private enum CodingKeys: String, CodingKey {
        case apiToken = "api_token"
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
        schemaVersion: GatewaySchema.version,
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
}

package struct GatewayRouteStatus: Codable, Equatable, Sendable {
    package var domain: String
    package var upstream: String
    package var resolvedAddresses: [String]
    package var certificateID: String

    private enum CodingKeys: String, CodingKey {
        case domain
        case upstream
        case resolvedAddresses = "resolved_addresses"
        case certificateID = "certificate_id"
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

package struct GatewayCertificateStatus: Codable, Equatable, Sendable {
    package var id: String
    package var domains: [String]
    package var challenge: String
    package var state: GatewayCertificateState
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
        case notBefore = "not_before"
        case notAfter = "not_after"
        case nextRenewalAt = "next_renewal_at"
        case lastAttemptAt = "last_attempt_at"
        case lastError = "last_error"
    }
}
