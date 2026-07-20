import EasyTierShared
import Foundation

struct PublishedServiceCertificatePresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case unavailable
        case notIssued
        case issuing
        case renewing
        case degraded
        case failed
        case active
        case expires(Date)
        case expiresSoon(Date)
        case expired(Date)
    }

    let state: State
    let renewalAt: Date?
    let errorMessage: String?

    init(
        provider: PublishedServiceSSLProvider,
        certificate: GatewayCertificateStatus?,
        now: Date = .now
    ) {
        renewalAt = Self.date(from: certificate?.nextRenewalAt)
        errorMessage = certificate?.lastError

        guard provider != .httpOnly else {
            state = .unavailable
            return
        }
        guard let certificate else {
            state = .notIssued
            return
        }

        switch certificate.state {
        case .pending, .issuing:
            state = .issuing
        case .renewing:
            state = .renewing
        case .failed:
            state = .failed
        case .degraded:
            state = .degraded
        case .active:
            guard let expirationDate = Self.date(from: certificate.notAfter) else {
                state = .active
                return
            }
            if expirationDate <= now {
                state = .expired(expirationDate)
            } else if expirationDate.timeIntervalSince(now) <= 30 * 24 * 60 * 60 {
                state = .expiresSoon(expirationDate)
            } else {
                state = .expires(expirationDate)
            }
        }
    }

    var label: String {
        switch state {
        case .unavailable: "—"
        case .notIssued: "Not issued"
        case .issuing: "Issuing…"
        case .renewing: "Renewing…"
        case .degraded: "Delayed"
        case .failed: "Failed"
        case .active: "Active"
        case .expires(let date), .expiresSoon(let date), .expired(let date):
            date.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }

    var tone: GatewayPresentationTone {
        switch state {
        case .expires, .active: .positive
        case .expiresSoon, .expired, .degraded, .failed, .notIssued: .warning
        case .unavailable, .issuing, .renewing: .neutral
        }
    }

    var helpText: String {
        switch state {
        case .unavailable:
            "HTTP Only services do not use a certificate."
        case .notIssued:
            "A certificate has not been issued for this service."
        case .issuing:
            "The certificate is being issued."
        case .renewing:
            renewalDescription(prefix: "The certificate is being renewed")
        case .degraded:
            errorMessage ?? "Certificate renewal is delayed."
        case .failed:
            errorMessage ?? "Certificate issuance or renewal failed."
        case .active:
            renewalDescription(prefix: "The certificate is active")
        case .expires(let date):
            expirationDescription(date: date, prefix: "Expires")
        case .expiresSoon(let date):
            expirationDescription(date: date, prefix: "Expires soon")
        case .expired(let date):
            expirationDescription(date: date, prefix: "Expired")
        }
    }

    private func expirationDescription(date: Date, prefix: String) -> String {
        let expiration = date.formatted(date: .complete, time: .standard)
        return renewalAt.map {
            "\(prefix): \(expiration)\nNext renewal: \($0.formatted(date: .complete, time: .standard))"
        } ?? "\(prefix): \(expiration)"
    }

    private func renewalDescription(prefix: String) -> String {
        renewalAt.map {
            "\(prefix).\nNext renewal: \($0.formatted(date: .complete, time: .standard))"
        } ?? "\(prefix)."
    }

    private static func date(from timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        return try? Date(timestamp, strategy: .iso8601)
    }
}
