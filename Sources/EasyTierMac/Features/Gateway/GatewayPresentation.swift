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
    let isInProgress: Bool

    init(
        status: GatewayStatus,
        desiredEnabled: Bool,
        services: [GatewayPublishedService],
        magicDNSState: MagicDNSOperationalState = .ready
    ) {
        let routesAreConverging = status.routes.contains { route in
            route.resolutionState == .waiting || route.resolutionState == .resolving
        }
        let certificatesAreConverging = status.certificates.contains { certificate in
            certificate.state == .pending
                || certificate.state == .issuing
                || certificate.state == .renewing
        }

        if desiredEnabled, magicDNSState == .disabled {
            statusLabel = "Paused"
            tone = .neutral
            isInProgress = false
        } else if desiredEnabled, magicDNSState == .loading {
            statusLabel = "Loading"
            tone = .neutral
            isInProgress = true
        } else if desiredEnabled, case .mismatch = magicDNSState {
            statusLabel = "DNS Mismatch"
            tone = .warning
            isInProgress = false
        } else if desiredEnabled,
                  status.state == .running,
                  routesAreConverging || certificatesAreConverging
        {
            statusLabel = "Starting"
            tone = .neutral
            isInProgress = true
        } else {
            switch status.state {
            case .stopped:
                statusLabel = desiredEnabled ? "Waiting" : "Off"
                tone = .neutral
                isInProgress = false
            case .starting:
                statusLabel = "Starting"
                tone = .neutral
                isInProgress = true
            case .running:
                statusLabel = "Running"
                tone = .positive
                isInProgress = false
            case .stopping:
                statusLabel = "Stopping"
                tone = .neutral
                isInProgress = true
            case .failed:
                statusLabel = "Failed"
                tone = .warning
                isInProgress = false
            }
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
    let detailLabel: String
    let tone: GatewayPresentationTone
    let errorMessage: String?
    let isInProgress: Bool
    let canToggleEnabled: Bool
    let canOpen: Bool
    let canRetryCertificate: Bool
    let certificateActionTitle: String

    init(
        service: GatewayPublishedService,
        certificate: GatewayCertificateStatus?,
        route: GatewayRouteStatus?,
        gatewayEnabled: Bool,
        tlsConfigured: Bool,
        gatewayState: GatewayState = .running,
        magicDNSState: MagicDNSOperationalState = .ready
    ) {
        let isRunning = gatewayEnabled && service.desiredEnabled && gatewayState == .running
        let runtimeError = isRunning ? certificate?.lastError ?? route?.lastError : nil
        let presentation: (
            status: String,
            detail: String,
            tone: GatewayPresentationTone,
            isInProgress: Bool
        )

        if !service.desiredEnabled {
            presentation = ("Off", "Disabled", .neutral, false)
        } else if !tlsConfigured {
            presentation = ("SSL Required", "Configure SSL", .warning, false)
        } else if !gatewayEnabled {
            presentation = ("Waiting", "Gateway is off", .neutral, false)
        } else if magicDNSState == .disabled {
            presentation = ("Paused", "Magic DNS is off", .neutral, false)
        } else if magicDNSState == .loading {
            presentation = ("Loading", "Checking Magic DNS", .neutral, true)
        } else if case .mismatch = magicDNSState {
            presentation = ("DNS Mismatch", "Magic DNS address mismatch", .warning, false)
        } else if gatewayState == .failed {
            presentation = ("Failed", "Gateway failed", .warning, false)
        } else if gatewayState == .starting {
            presentation = ("Starting", "Applying configuration", .neutral, true)
        } else if gatewayState == .stopping {
            presentation = ("Stopping", "Stopping gateway", .neutral, true)
        } else if gatewayState == .stopped {
            presentation = ("Waiting", "Waiting for gateway", .neutral, false)
        } else if certificate?.servingMode == .httpOnly, route?.resolutionState == .ready {
            presentation = (
                "HTTP Only",
                "Retrying managed HTTPS",
                .warning,
                false
            )
        } else if certificate?.state == .failed {
            presentation = (
                "SSL Error",
                runtimeError ?? "Certificate request failed",
                .warning,
                false
            )
        } else if certificate?.state == .degraded {
            presentation = (
                "SSL Warning",
                runtimeError ?? "Certificate renewal delayed",
                .warning,
                false
            )
        } else if route?.resolutionState == .mismatch {
            presentation = (
                "DNS Mismatch",
                runtimeError ?? "Resolved IPv4 does not match target",
                .warning,
                false
            )
        } else if route?.resolutionState == .unavailable {
            presentation = (
                "Target Offline",
                runtimeError ?? "Target is unavailable",
                .warning,
                false
            )
        } else if certificate?.state == .active, route?.resolutionState == .ready {
            presentation = ("Live", "Enabled", .positive, false)
        } else if route?.resolutionState == .waiting {
            presentation = ("Starting", "Waiting for Magic DNS", .neutral, true)
        } else if route?.resolutionState == .resolving {
            presentation = ("Starting", "Resolving target", .neutral, true)
        } else if certificate?.state == .pending || certificate?.state == .issuing {
            presentation = ("Starting", "Issuing certificate", .neutral, true)
        } else if certificate?.state == .renewing {
            presentation = ("Starting", "Renewing certificate", .neutral, true)
        } else {
            presentation = ("Starting", "Applying configuration", .neutral, true)
        }

        statusLabel = presentation.status
        detailLabel = presentation.detail
        tone = presentation.tone
        errorMessage = runtimeError
        isInProgress = presentation.isInProgress
        canToggleEnabled = service.desiredEnabled
            || (tlsConfigured && magicDNSState != .disabled)
        canOpen = isRunning
            && magicDNSState == .ready
            && (certificate?.servingMode == .https || certificate?.servingMode == .httpOnly)
            && route?.resolutionState == .ready
        canRetryCertificate = isRunning && tlsConfigured && magicDNSState == .ready
        certificateActionTitle = certificate?.state == .failed || certificate?.state == .degraded
            ? "Retry Certificate"
            : "Renew Certificate"
    }
}
