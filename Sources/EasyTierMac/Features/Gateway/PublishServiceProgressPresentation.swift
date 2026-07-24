import EasyTierShared

struct PublishServiceProgressPresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case requesting
        case waitingRetry
        case failed
        case https
        case httpOnly
    }

    let phase: Phase
    let title: String
    let detail: String
    let systemImage: String
    let showsProgress: Bool
    let canRetry: Bool

    init(
        certificate: GatewayCertificateStatus?,
        route: GatewayRouteStatus?,
        convergence: GatewayConvergenceSnapshot
    ) {
        if route?.servingMode == .https {
            phase = .https
            title = "Service Published"
            detail = "HTTPS is ready. HTTP requests redirect securely."
            systemImage = "checkmark.circle.fill"
            showsProgress = false
            canRetry = false
            return
        }

        if convergence.phase == .blocked {
            phase = .failed
            title = "Publishing Needs Attention"
            detail = convergence.message ?? "The Gateway configuration could not be applied."
            systemImage = "exclamationmark.triangle.fill"
            showsProgress = false
            canRetry = false
            return
        }

        if convergence.phase == .retryScheduled {
            phase = .waitingRetry
            title = "Publishing Delayed"
            detail = convergence.message ?? "The Gateway will retry applying this service automatically."
            systemImage = "clock.arrow.circlepath"
            showsProgress = false
            canRetry = false
            return
        }

        if route?.servingMode == .httpOnly {
            phase = .httpOnly
            title = "Published over HTTP"
            detail = "Both certificate authorities were exhausted. Certificate requests can be retried later."
            systemImage = "lock.open.fill"
            showsProgress = false
            canRetry = true
            return
        }

        if certificate?.operation == .suspended {
            phase = .failed
            title = "Certificate Needs Attention"
            detail = certificate?.failure?.message ?? "The certificate request could not continue."
            systemImage = "exclamationmark.triangle.fill"
            showsProgress = false
            canRetry = true
            return
        }

        if certificate?.operation == .waitingRetry {
            phase = .waitingRetry
            title = "Certificate Request Delayed"
            detail = certificate?.failure?.message
                ?? "The request will retry automatically when it becomes eligible."
            systemImage = "clock.arrow.circlepath"
            showsProgress = false
            canRetry = true
            return
        }

        if certificate?.availability == .valid {
            if route?.resolutionState == .mismatch || route?.resolutionState == .unavailable {
                phase = .failed
                title = route?.resolutionState == .mismatch ? "DNS Target Mismatch" : "Service Target Unavailable"
                detail = route?.lastError ?? "The selected service target is not ready."
                systemImage = "exclamationmark.triangle.fill"
                showsProgress = false
                canRetry = false
                return
            }
            phase = .requesting
            title = "Preparing Secure Route"
            detail = switch route?.resolutionState {
            case .waiting: "Waiting for the published hostname to become available."
            case .resolving: "Resolving the service target before enabling HTTPS."
            case .mismatch, .unavailable: "The selected service target is not ready."
            case .ready, nil: "Finishing the HTTPS route configuration."
            }
            systemImage = "lock.shield"
            showsProgress = true
            canRetry = false
            return
        }

        phase = .requesting
        title = certificateStageTitle(certificate?.stage, convergence: convergence)
        detail = requestingDetail(certificate: certificate)
        systemImage = "lock.shield"
        showsProgress = true
        canRetry = false
    }
}

private func certificateStageTitle(
    _ stage: GatewayCertificateStage?,
    convergence: GatewayConvergenceSnapshot
) -> String {
    if convergence.phase == .applying || convergence.phase == .retryScheduled {
        return "Publishing Service"
    }
    return switch stage {
    case .account: "Preparing Certificate Account"
    case .ordering: "Requesting Certificate"
    case .provisioningChallenge: "Creating DNS Validation Record"
    case .validating: "Waiting for DNS Validation"
    case .finalizing: "Finalizing Certificate"
    case .downloading: "Downloading Certificate"
    case .installing: "Installing Certificate"
    case .cleanup: "Finishing DNS Validation"
    case nil: "Requesting Certificate"
    }
}

private func requestingDetail(certificate: GatewayCertificateStatus?) -> String {
    guard let certificate else {
        return "Applying the Gateway configuration before certificate issuance begins."
    }
    return "\(certificate.authority.label) is validating \(certificate.domains.first ?? "the service domain")."
}
