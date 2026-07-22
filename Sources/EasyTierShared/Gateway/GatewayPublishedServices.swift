import Darwin
import CryptoKit
import Foundation

package enum GatewayPublishedServicesValidator {
    package static func makeService(
        networkConfigID: String,
        targetPeerID: String,
        targetInstanceID: String? = nil,
        targetHostname: String,
        magicDNSSuffix: String,
        serviceLabel: String,
        targetPort: Int,
        desiredEnabled: Bool,
        certificatePolicy: GatewayCertificatePolicy
    ) throws -> GatewayPublishedService {
        let serviceLabel = try normalizeLabel(serviceLabel, field: "Service name")
        let nodeLabel = try normalizeLabel(targetHostname, field: "Target hostname")
        let suffix = try MagicDNSSettings.normalizedDNSSuffix(magicDNSSuffix)
        try validatePort(targetPort)
        return GatewayPublishedService(
            networkConfigID: try required(networkConfigID, field: "Network ID"),
            targetPeerID: try required(targetPeerID, field: "Target Peer ID"),
            targetInstanceID: targetInstanceID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            publicNodeLabel: nodeLabel,
            publicDNSSuffix: suffix,
            lastKnownTargetHostname: nodeLabel,
            lastKnownMagicDNSSuffix: suffix,
            serviceLabel: serviceLabel,
            publicHostname: makePublicHostname(
                serviceLabel: serviceLabel,
                nodeLabel: nodeLabel,
                suffix: suffix
            ),
            targetPort: targetPort,
            desiredEnabled: desiredEnabled,
            certificatePolicy: certificatePolicy
        )
    }

    package static func validate(_ state: GatewayPersistedState) throws -> GatewayPersistedState {
        guard state.schemaVersion == GatewaySchema.persistedVersion else {
            throw invalid("Unsupported Gateway schema version \(state.schemaVersion).")
        }

        guard UUID(uuidString: state.configurationID) != nil else {
            throw invalid("Gateway configuration ID is invalid.")
        }

        var normalized = state
        if var acme = state.acmeAccount {
            if let email = acme.contactEmail {
                let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isValidEmail(email) else {
                    throw invalid("ACME contact email is invalid.")
                }
                acme.contactEmail = email
            }
            normalized.acmeAccount = acme
        }

        var credentialIDs = Set<String>()
        normalized.dnsCredentials = try state.dnsCredentials.map { credential in
            var credential = credential
            credential.id = try required(credential.id, field: "DNS credential ID")
            credential.label = try required(credential.label, field: "DNS credential name")
            guard credentialIDs.insert(credential.id).inserted else {
                throw invalid("Duplicate DNS credential ID \(credential.id).")
            }
            return credential
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }

        if let cidr = state.lastKnownNetworkIPv4CIDR {
            normalized.lastKnownNetworkIPv4CIDR = try normalizeIPv4CIDR(cidr)
        }

        var serviceIDs = Set<String>()
        var publicHostnames = Set<String>()
        var networkIDs = Set<String>()
        normalized.services = try state.services.map { service in
            var service = service
            service.id = try required(service.id, field: "Service ID")
            guard serviceIDs.insert(service.id).inserted else {
                throw invalid("Duplicate service ID \(service.id).")
            }
            service.networkConfigID = try required(service.networkConfigID, field: "Network ID")
            service.targetPeerID = try required(service.targetPeerID, field: "Target Peer ID")
            service.targetInstanceID = service.targetInstanceID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            service.serviceLabel = try normalizeLabel(service.serviceLabel, field: "Service name")
            service.publicNodeLabel = try normalizeLabel(service.publicNodeLabel, field: "Public node label")
            service.publicDNSSuffix = try MagicDNSSettings.normalizedDNSSuffix(service.publicDNSSuffix)
            service.lastKnownTargetHostname = try normalizeLabel(
                service.lastKnownTargetHostname,
                field: "Target hostname"
            )
            service.lastKnownMagicDNSSuffix = try MagicDNSSettings.normalizedDNSSuffix(
                service.lastKnownMagicDNSSuffix
            )
            try validatePort(service.targetPort)

            let expectedHostname = makePublicHostname(
                serviceLabel: service.serviceLabel,
                nodeLabel: service.publicNodeLabel,
                suffix: service.publicDNSSuffix
            )
            let publicHostname = try normalizeDomain(service.publicHostname, field: "Public hostname")
            guard publicHostname == expectedHostname else {
                throw invalid("Public hostname must remain \(expectedHostname).")
            }
            guard publicHostnames.insert(publicHostname).inserted else {
                throw invalid("Duplicate public hostname \(publicHostname).")
            }
            service.publicHostname = publicHostname
            switch service.certificatePolicy.challenge {
            case .http01:
                break
            case let .dns01(credentialID):
                guard credentialIDs.contains(credentialID) else {
                    throw invalid("Service references an unknown DNS credential.")
                }
            }
            networkIDs.insert(service.networkConfigID)
            return service
        }.sorted { $0.publicHostname < $1.publicHostname }

        guard networkIDs.count <= 1 else {
            throw invalid("Published Services can belong to only one EasyTier network.")
        }
        let actualNetworkID = networkIDs.first
        guard state.publishingNetworkConfigID == actualNetworkID else {
            throw invalid("Publishing network ID does not match the service records.")
        }

        if normalized.hasEnabledServices {
            guard let acme = normalized.acmeAccount, acme.termsOfServiceAgreed else {
                throw invalid("Accept the certificate service terms before enabling a service.")
            }
            guard acme.contactEmail != nil else {
                throw invalid("Enter a certificate contact email before enabling a service.")
            }
        }
        return normalized
    }

    package static func normalizeLabel(_ value: String, field: String) throws -> String {
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (1 ... 63).contains(label.utf8.count),
              label.first != "-",
              label.last != "-",
              label.utf8.allSatisfy({ byte in
                  (97 ... 122).contains(byte) || (48 ... 57).contains(byte) || byte == 45
              })
        else {
            throw invalid("\(field) must be a 1–63 character DNS label using letters, numbers, or hyphens.")
        }
        return label
    }

    package static func normalizeIPv4(_ value: String, field: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            throw invalid("\(field) is not a valid IPv4 address.")
        }
        return value
    }

    package static func normalizeIPv4CIDR(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0 ... 32).contains(prefix)
        else {
            throw invalid("EasyTier network address must be an IPv4 CIDR.")
        }
        let ip = try normalizeIPv4(String(parts[0]), field: "EasyTier network address")
        return "\(ip)/\(prefix)"
    }

    private static func makePublicHostname(
        serviceLabel: String,
        nodeLabel: String,
        suffix: String
    ) -> String {
        let suffix = suffix.hasSuffix(".") ? String(suffix.dropLast()) : suffix
        return "\(serviceLabel).\(nodeLabel).\(suffix)"
    }

    private static func normalizeDomain(_ value: String, field: String) throws -> String {
        var domain = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while domain.last == "." { domain.removeLast() }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3,
              domain.utf8.count <= 253,
              labels.allSatisfy({ label in
                  (1 ... 63).contains(label.utf8.count)
                      && label.first != "-"
                      && label.last != "-"
                      && label.utf8.allSatisfy { byte in
                          (97 ... 122).contains(byte) || (48 ... 57).contains(byte) || byte == 45
                      }
              })
        else {
            throw invalid("\(field) is not a valid DNS name.")
        }
        return domain
    }

    private static func validatePort(_ port: Int) throws {
        guard (1 ... 65_535).contains(port) else {
            throw invalid("Target port must be between 1 and 65535.")
        }
    }

    private static func required(_ value: String, field: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw invalid("\(field) is required.") }
        return value
    }

    private static func isValidEmail(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains(where: \Character.isWhitespace)
            && value.first != "@"
            && value.last != "@"
            && value.contains("@")
    }

    private static func invalid(_ message: String) -> GatewayConfigurationValidationError {
        .invalid(message)
    }
}

package enum GatewayConfigurationFactory {
    package static func makeRuntimeConfiguration(
        from state: GatewayPersistedState,
        routeAvailability: GatewayUpstreamAvailability = .ready,
        routeAvailabilityByServiceID: [String: GatewayUpstreamAvailability] = [:],
        expectedIPv4ByServiceID: [String: String] = [:]
    ) throws -> GatewayConfiguration {
        let state = try GatewayPublishedServicesValidator.validate(state)
        let enabledServices = state.services.filter(\.desiredEnabled)
        var allowedIPv4CIDR: String?
        if !enabledServices.isEmpty {
            guard let networkIPv4CIDR = state.lastKnownNetworkIPv4CIDR else {
                throw GatewayConfigurationValidationError.invalid(
                    "The publishing EasyTier network does not have a usable IPv4 subnet yet."
                )
            }
            allowedIPv4CIDR = networkIPv4CIDR
        }
        let acme = state.acmeAccount ?? GatewayACMEConfiguration(
            contactEmail: nil,
            termsOfServiceAgreed: false
        )

        var configuration = try GatewayConfigurationValidator.validate(
            GatewayConfiguration(
                deployment: GatewayDeploymentIdentity(
                    configurationID: state.configurationID,
                    revision: state.revision,
                    fingerprint: "pending"
                ),
                acme: acme,
                certificates: enabledServices.map { service in
                    GatewayCertificateConfiguration(
                        id: service.id,
                        domains: [service.publicHostname],
                        authority: service.certificatePolicy.authority,
                        challenge: try runtimeChallenge(
                            service.certificatePolicy.challenge,
                            credentials: state.dnsCredentials
                        )
                    )
                },
                routes: enabledServices.map { service in
                    let serviceAvailability = routeAvailabilityByServiceID[service.id]
                        ?? routeAvailability
                    return GatewayRouteConfiguration(
                        domain: service.publicHostname,
                        certificateID: service.id,
                        upstream: GatewayUpstreamConfiguration(
                            url: "http://\(service.targetDomain):\(service.targetPort)",
                            allowedIPv4CIDR: allowedIPv4CIDR,
                            availability: serviceAvailability == .ready
                                && expectedIPv4ByServiceID[service.id] == nil
                                ? .unavailable
                                : serviceAvailability,
                            expectedIPv4: serviceAvailability == .ready
                                ? expectedIPv4ByServiceID[service.id]
                                : nil
                        )
                    )
                },
                localDomains: enabledServices.map(\.publicHostname)
            )
        )
        configuration.deployment.fingerprint = try deploymentFingerprint(
            configuration: configuration
        )
        return configuration
    }

    private static func deploymentFingerprint(
        configuration: GatewayConfiguration
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        let digits = Array("0123456789abcdef")
        return SHA256.hash(data: data).map { byte in
            String([digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]])
        }.joined()
    }

    private static func runtimeChallenge(
        _ challenge: GatewayPublishedServiceChallenge,
        credentials: [GatewayDNSCredentialDescriptor]
    ) throws -> GatewayChallengeConfiguration {
        switch challenge {
        case .http01:
            return .http01
        case let .dns01(credentialID):
            let credential = try credential(id: credentialID, in: credentials)
            return .dns01(
                GatewayDNS01Configuration(
                    provider: credential.provider,
                    credentialID: credential.id,
                    credentialRevision: credential.revision
                )
            )
        }
    }

    private static func credential(
        id: String,
        in credentials: [GatewayDNSCredentialDescriptor]
    ) throws -> GatewayDNSCredentialDescriptor {
        guard let credential = credentials.first(where: { $0.id == id }) else {
            throw GatewayConfigurationValidationError.invalid(
                "Published service references an unknown DNS credential."
            )
        }
        return credential
    }
}
