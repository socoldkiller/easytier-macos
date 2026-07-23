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
        magicDNSState: MagicDNSOperationalState = .ready,
        convergence: GatewayConvergenceSnapshot = .disabled
    ) {
        let routesAreConverging = status.routes.contains { route in
            route.resolutionState == .waiting || route.resolutionState == .resolving
        }
        let certificatesAreConverging = status.certificates.contains { certificate in
            certificate.operation == .queued
                || certificate.operation == .issuing
                || certificate.operation == .renewing
                || certificate.operation == .replacing
        }

        if desiredEnabled, convergence.phase == .applying {
            statusLabel = convergence.isServingPreviousConfiguration ? "Updating" : "Starting"
            tone = .neutral
            isInProgress = true
        } else if desiredEnabled, convergence.phase == .retryScheduled {
            statusLabel = convergence.isServingPreviousConfiguration ? "Update Delayed" : "Not Applied"
            tone = .warning
            isInProgress = false
        } else if desiredEnabled, convergence.phase == .blocked {
            statusLabel = "Apply Blocked"
            tone = .warning
            isInProgress = false
        } else if desiredEnabled, magicDNSState == .disabled {
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
        magicDNSState: MagicDNSOperationalState = .ready,
        configurationApplied: Bool = true,
        convergenceMessage: String? = nil
    ) {
        let isRunning = gatewayEnabled && service.desiredEnabled && gatewayState == .running
        let runtimeError = isRunning ? certificate?.failure?.message ?? route?.lastError : nil
        let presentation: (
            status: String,
            detail: String,
            tone: GatewayPresentationTone,
            isInProgress: Bool
        )

        if !service.desiredEnabled {
            presentation = ("Off", "Disabled", .neutral, false)
        } else if !tlsConfigured {
            presentation = ("HTTPS Setup", "Add certificate email", .warning, false)
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
        } else if !configurationApplied {
            presentation = (
                "Not Applied",
                convergenceMessage ?? "Runtime is using a different configuration",
                .warning,
                false
            )
        } else if certificate?.operation == .suspended {
            presentation = (
                "HTTPS Error",
                runtimeError ?? "Certificate request failed",
                .warning,
                false
            )
        } else if certificate?.operation == .waitingRetry {
            presentation = (
                "HTTPS Warning",
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
        } else if certificate?.availability == .valid,
                  certificate?.operation == .idle,
                  route?.resolutionState == .ready
        {
            presentation = ("Live", "Enabled", .positive, false)
        } else if route?.resolutionState == .waiting {
            presentation = ("Starting", "Waiting for Magic DNS", .neutral, true)
        } else if route?.resolutionState == .resolving {
            presentation = ("Starting", "Resolving target", .neutral, true)
        } else if certificate?.operation == .queued || certificate?.operation == .issuing {
            presentation = (
                "Starting",
                Self.certificateIssuanceDetail(stage: certificate?.stage),
                .neutral,
                true
            )
        } else if certificate?.operation == .renewing || certificate?.operation == .replacing {
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
            && certificate?.availability == .valid
            && route?.resolutionState == .ready
        canRetryCertificate = isRunning && tlsConfigured && magicDNSState == .ready
        certificateActionTitle = certificate?.operation == .suspended
            || certificate?.operation == .waitingRetry
            ? "Retry Certificate"
            : "Renew Certificate"
    }

    private static func certificateIssuanceDetail(stage: GatewayCertificateStage?) -> String {
        switch stage {
        case .account: "Preparing certificate account"
        case .ordering: "Requesting certificate"
        case .provisioningChallenge: "Creating DNS validation record"
        case .validating: "Waiting for DNS validation"
        case .finalizing: "Finalizing certificate"
        case .downloading: "Downloading certificate"
        case .installing: "Installing certificate"
        case .cleanup: "Finishing DNS validation"
        case nil: "Issuing certificate"
        }
    }
}
