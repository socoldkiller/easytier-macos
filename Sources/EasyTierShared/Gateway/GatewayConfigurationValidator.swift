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
        guard configuration.schemaVersion == GatewaySchema.version else {
            throw invalid("Unsupported Gateway schema version \(configuration.schemaVersion).")
        }
        guard configuration.acme.termsOfServiceAgreed else {
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
            guard !certificate.domains.isEmpty else {
                throw invalid("Certificate \(certificate.id) must contain at least one domain.")
            }

            var seen = Set<String>()
            let domains = try certificate.domains.map { rawDomain in
                let domain = try normalizeDomain(rawDomain, label: "Certificate domain")
                guard !rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("*.") else {
                    throw invalid("HTTP-01 certificates cannot contain wildcard domains.")
                }
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
                challenge: .http01
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
            guard certificateDomains.contains(domain) else {
                throw invalid("Certificate \(route.certificateID) does not cover route domain \(domain).")
            }

            return GatewayRouteConfiguration(
                domain: domain,
                certificateID: route.certificateID,
                upstream: try normalizeUpstream(route.upstream)
            )
        }.sorted { $0.domain < $1.domain }

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

        return GatewayUpstreamConfiguration(
            url: upstream.url,
            hostHeader: hostHeader,
            tlsServerName: tlsServerName
        )
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
