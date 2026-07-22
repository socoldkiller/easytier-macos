import Darwin
import Foundation

package enum GatewayConfigurationValidationError: LocalizedError, Equatable, Sendable {
    case invalid(String)

    package var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}

package enum GatewayConfigurationValidator {
    package static func validate(_ configuration: GatewayConfiguration) throws -> GatewayConfiguration {
        guard configuration.schemaVersion == GatewaySchema.runtimeVersion else {
            throw invalid("Unsupported Gateway schema version \(configuration.schemaVersion).")
        }
        guard UUID(uuidString: configuration.deployment.configurationID) != nil,
              !configuration.deployment.fingerprint
                  .trimmingCharacters(in: .whitespacesAndNewlines)
                  .isEmpty
        else {
            throw invalid("Gateway deployment identity is invalid.")
        }
        guard configuration.certificates.isEmpty || configuration.acme.termsOfServiceAgreed else {
            throw invalid("ACME terms of service must be accepted.")
        }

        var normalized = configuration
        if let email = configuration.acme.contactEmail {
            let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidEmail(email) else {
                throw invalid("ACME contact email is invalid.")
            }
            normalized.acme.contactEmail = email
        }

        var certificatesByID: [String: Set<String>] = [:]
        normalized.certificates = try configuration.certificates.map { certificate in
            try validateIdentifier(certificate.id, label: "Certificate ID")
            if case let .dns01(configuration) = certificate.challenge {
                try validateIdentifier(configuration.credentialID, label: "DNS credential ID")
                guard configuration.credentialRevision > 0 else {
                    throw invalid("DNS credential revision must be greater than zero.")
                }
            }
            guard !certificate.domains.isEmpty else {
                throw invalid("Certificate \(certificate.id) must contain at least one domain.")
            }

            var seen = Set<String>()
            let domains = try certificate.domains.map { rawDomain in
                let domain = try normalizeCertificateDomain(
                    rawDomain,
                    challenge: certificate.challenge
                )
                guard seen.insert(domain).inserted else {
                    throw invalid("Certificate \(certificate.id) contains duplicate domain \(domain).")
                }
                return domain
            }.sorted()

            guard certificatesByID.updateValue(Set(domains), forKey: certificate.id) == nil else {
                throw invalid("Duplicate certificate ID \(certificate.id).")
            }
            return GatewayCertificateConfiguration(
                id: certificate.id,
                domains: domains,
                authority: certificate.authority,
                challenge: certificate.challenge
            )
        }

        var routeDomains = Set<String>()
        normalized.routes = try configuration.routes.map { route in
            let domain = try normalizeDomain(route.domain, label: "Route domain")
            guard routeDomains.insert(domain).inserted else {
                throw invalid("Duplicate route domain \(domain).")
            }
            guard let certificateDomains = certificatesByID[route.certificateID] else {
                throw invalid("Route \(domain) references unknown certificate \(route.certificateID).")
            }
            guard certificateDomains.contains(where: { certificateDomain in
                certificateDomain == domain || wildcard(certificateDomain, covers: domain)
            }) else {
                throw invalid("Certificate \(route.certificateID) does not cover route domain \(domain).")
            }

            return GatewayRouteConfiguration(
                domain: domain,
                certificateID: route.certificateID,
                upstream: try normalizeUpstream(route.upstream)
            )
        }.sorted { $0.domain < $1.domain }

        var localDomains = Set<String>()
        normalized.localDomains = try configuration.localDomains.map { rawDomain in
            let domain = try normalizeDomain(rawDomain, label: "Local DNS domain")
            guard routeDomains.contains(domain) else {
                throw invalid("Local DNS domain \(domain) does not have a Gateway route.")
            }
            guard localDomains.insert(domain).inserted else {
                throw invalid("Duplicate local DNS domain \(domain).")
            }
            return domain
        }.sorted()

        normalized.certificates.sort { $0.id < $1.id }
        return normalized
    }

    private static func normalizeUpstream(
        _ upstream: GatewayUpstreamConfiguration
    ) throws -> GatewayUpstreamConfiguration {
        guard let components = URLComponents(string: upstream.url),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else {
            throw invalid("Upstream URL must use HTTP or HTTPS and include a host.")
        }
        guard components.user == nil, components.password == nil else {
            throw invalid("Upstream URL must not include credentials.")
        }
        guard components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw invalid("Upstream URL must not include a path, query, or fragment.")
        }

        let isIPAddress = isIPAddress(host)
        let hostHeader = try normalizeHeaderValue(upstream.hostHeader)
        let tlsServerName: String?
        if scheme == "http" {
            guard upstream.tlsServerName == nil else {
                throw invalid("tls_server_name is valid only for HTTPS upstreams.")
            }
            tlsServerName = nil
        } else if let rawName = upstream.tlsServerName {
            tlsServerName = try normalizeDomain(rawName, label: "TLS server name")
        } else if isIPAddress {
            throw invalid("HTTPS upstreams addressed by IP require tls_server_name.")
        } else {
            tlsServerName = try normalizeDomain(host, label: "TLS server name")
        }

        let expectedIPv4 = try normalizeIPv4(upstream.expectedIPv4, field: "expected_ipv4")
        let allowedIPv4CIDR = try normalizeIPv4CIDR(upstream.allowedIPv4CIDR)
        switch upstream.availability {
        case .waiting, .unavailable:
            guard expectedIPv4 == nil else {
                throw invalid("A non-ready upstream must not include expected_ipv4.")
            }
        case .ready:
            break
        }
        if let allowedIPv4CIDR, let expectedIPv4,
           !ipv4(expectedIPv4, isInside: allowedIPv4CIDR)
        {
            throw invalid("expected_ipv4 must be inside allowed_ipv4_cidr.")
        }

        return GatewayUpstreamConfiguration(
            url: upstream.url,
            hostHeader: hostHeader,
            tlsServerName: tlsServerName,
            allowedIPv4CIDR: allowedIPv4CIDR,
            availability: upstream.availability,
            expectedIPv4: expectedIPv4
        )
    }

    private static func normalizeIPv4(_ value: String?, field: String) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = in_addr()
        guard normalized.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            throw invalid("\(field) must be an IPv4 address.")
        }
        return normalized
    }

    private static func normalizeIPv4CIDR(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0 ... 32).contains(prefix)
        else {
            throw invalid("allowed_ipv4_cidr must be an IPv4 CIDR.")
        }
        var address = in_addr()
        let ip = String(parts[0])
        guard ip.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            throw invalid("allowed_ipv4_cidr must be an IPv4 CIDR.")
        }
        return "\(ip)/\(prefix)"
    }

    private static func ipv4(_ address: String, isInside cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let prefix = UInt32(parts[1]) else { return false }
        var addressValue = in_addr()
        var networkValue = in_addr()
        guard address.withCString({ inet_pton(AF_INET, $0, &addressValue) }) == 1,
              String(parts[0]).withCString({ inet_pton(AF_INET, $0, &networkValue) }) == 1
        else { return false }
        let mask = prefix == 0 ? UInt32(0) : UInt32.max << (32 - prefix)
        return UInt32(bigEndian: addressValue.s_addr) & mask
            == UInt32(bigEndian: networkValue.s_addr) & mask
    }

    private static func normalizeHeaderValue(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ scalar in
            scalar.value == 9 || (scalar.value >= 32 && scalar.value != 127)
        }) else {
            throw invalid("Upstream host_header contains invalid control characters.")
        }
        return trimmed
    }

    private static func validateIdentifier(_ value: String, label: String) throws {
        guard (1 ... 64).contains(value.utf8.count), value != ".", value != ".." else {
            throw invalid("\(label) must contain 1 to 64 characters and cannot be '.' or '..'.")
        }
        guard value.utf8.allSatisfy({ byte in
            byte < 128 && (
                (65 ... 90).contains(byte)
                    || (97 ... 122).contains(byte)
                    || (48 ... 57).contains(byte)
                    || byte == 45
                    || byte == 46
                    || byte == 95
            )
        }) else {
            throw invalid("\(label) may contain only ASCII letters, numbers, '.', '-', and '_'.")
        }
    }

    private static func normalizeDomain(_ value: String, label: String) throws -> String {
        var domain = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while domain.last == "." {
            domain.removeLast()
        }
        guard !domain.isEmpty,
              !domain.contains("*"),
              !domain.contains(where: \Character.isWhitespace),
              !isIPAddress(domain),
              domain.utf8.count <= 253
        else {
            throw invalid("\(label) must be an exact DNS name, not an IP address or wildcard.")
        }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty
                      && label.utf8.count <= 63
                      && label.first != "-"
                      && label.last != "-"
                      && label.utf8.allSatisfy { byte in
                          (65 ... 90).contains(byte)
                              || (97 ... 122).contains(byte)
                              || (48 ... 57).contains(byte)
                              || byte == 45
                      }
              })
        else {
            throw invalid("\(label) is not a valid DNS name.")
        }
        return domain
    }

    private static func normalizeCertificateDomain(
        _ value: String,
        challenge: GatewayChallengeConfiguration
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("*.") else {
            return try normalizeDomain(trimmed, label: "Certificate domain")
        }
        guard case .dns01 = challenge else {
            throw invalid("HTTP-01 certificates cannot contain wildcard domains.")
        }
        let baseDomain = try normalizeDomain(
            String(trimmed.dropFirst(2)),
            label: "Wildcard certificate domain"
        )
        return "*.\(baseDomain)"
    }

    private static func wildcard(_ certificateDomain: String, covers routeDomain: String) -> Bool {
        guard certificateDomain.hasPrefix("*.") else { return false }
        let suffix = String(certificateDomain.dropFirst(2))
        guard routeDomain.hasSuffix(".\(suffix)") else { return false }
        let prefix = routeDomain.dropLast(suffix.count + 1)
        return !prefix.isEmpty && !prefix.contains(".")
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString { pointer in
            inet_pton(AF_INET, pointer, &ipv4) == 1 || inet_pton(AF_INET6, pointer, &ipv6) == 1
        }
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
