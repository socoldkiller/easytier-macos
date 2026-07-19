import EasyTierShared

enum GatewayPresentationTone: Equatable, Sendable {
    case neutral
    case positive
    case warning

    var statusPillTone: StatusPill.Tone {
        switch self {
        case .neutral: .neutral
        case .positive: .positive
        case .warning: .warning
        }
    }
}

struct GatewayRuntimePresentation: Equatable, Sendable {
    let statusLabel: String
    let tone: GatewayPresentationTone
    let serviceCountLabel: String

    init(
        status: GatewayStatus,
        desiredEnabled: Bool,
        services: [GatewayPublishedService]
    ) {
        switch status.state {
        case .stopped:
            statusLabel = desiredEnabled ? "Waiting" : "Off"
            tone = .neutral
        case .starting:
            statusLabel = "Starting"
            tone = .neutral
        case .running:
            statusLabel = "Running"
            tone = .positive
        case .stopping:
            statusLabel = "Stopping"
            tone = .neutral
        case .failed:
            statusLabel = "Failed"
            tone = .warning
        }

        serviceCountLabel = switch services.count {
        case 0: "No Services"
        case 1: "1 Service"
        default: "\(services.count) Services"
        }
    }
}

struct PublishedServicePresentation: Equatable, Sendable {
    let statusLabel: String
    let tone: GatewayPresentationTone
    let errorMessage: String?
    let canToggleEnabled: Bool
    let canOpen: Bool
    let canRetryCertificate: Bool
    let certificateActionTitle: String

    init(
        service: GatewayPublishedService,
        certificate: GatewayCertificateStatus?,
        route: GatewayRouteStatus?,
        gatewayEnabled: Bool,
        tlsConfigured: Bool
    ) {
        let isRunning = gatewayEnabled && service.desiredEnabled

        if !service.desiredEnabled {
            statusLabel = "Off"
            tone = .neutral
        } else if !tlsConfigured {
            statusLabel = "TLS Required"
            tone = .warning
        } else if !gatewayEnabled {
            statusLabel = "Waiting"
            tone = .neutral
        } else if certificate?.state == .failed {
            statusLabel = "TLS Error"
            tone = .warning
        } else if certificate?.state == .degraded {
            statusLabel = "TLS Warning"
            tone = .warning
        } else if route?.resolutionState == .unavailable {
            statusLabel = "Target Offline"
            tone = .warning
        } else if certificate?.state == .active, route?.resolutionState == .ready {
            statusLabel = "Live"
            tone = .positive
        } else {
            statusLabel = "Starting"
            tone = .neutral
        }

        errorMessage = isRunning ? certificate?.lastError ?? route?.lastError : nil
        canToggleEnabled = service.desiredEnabled || tlsConfigured
        canOpen = isRunning
            && certificate?.state == .active
            && route?.resolutionState == .ready
        canRetryCertificate = isRunning && tlsConfigured
        certificateActionTitle = certificate?.state == .failed || certificate?.state == .degraded
            ? "Retry Certificate"
            : "Renew Certificate"
    }
}
