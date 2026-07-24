import EasyTierShared
import Foundation
import Testing
@testable import EasyTierMac

@Test func gatewayRuntimePresentationSummarizesRuntimeAndServices() {
    var status = GatewayStatus.stopped
    var presentation = GatewayRuntimePresentation(
        status: status,
        desiredEnabled: false,
        services: []
    )
    #expect(presentation.statusLabel == "Off")
    #expect(presentation.tone == .neutral)
    #expect(presentation.serviceCountLabel == "No Services")
    #expect(!presentation.isInProgress)

    presentation = GatewayRuntimePresentation(
        status: status,
        desiredEnabled: true,
        services: []
    )
    #expect(presentation.statusLabel == "Waiting")

    status.state = .starting
    presentation = GatewayRuntimePresentation(
        status: status,
        desiredEnabled: true,
        services: []
    )
    #expect(presentation.statusLabel == "Starting")
    #expect(presentation.tone == .neutral)
    #expect(presentation.isInProgress)

    status.state = .running
    presentation = GatewayRuntimePresentation(
        status: status,
        desiredEnabled: true,
        services: [presentationTestService()]
    )
    #expect(presentation.statusLabel == "Running")
    #expect(presentation.tone == .positive)
    #expect(presentation.serviceCountLabel == "1 Service")
    #expect(!presentation.isInProgress)

    status.state = .stopping
    presentation = GatewayRuntimePresentation(
        status: status,
        desiredEnabled: true,
        services: []
    )
    #expect(presentation.statusLabel == "Stopping")
    #expect(presentation.tone == .neutral)
    #expect(presentation.isInProgress)

    status.state = .failed
    presentation = GatewayRuntimePresentation(
        status: status,
        desiredEnabled: true,
        services: [presentationTestService(), presentationTestService(id: "service-b")]
    )
    #expect(presentation.statusLabel == "Failed")
    #expect(presentation.tone == .warning)
    #expect(presentation.serviceCountLabel == "2 Services")
}

@Test func gatewayRuntimePresentationKeepsConvergingRoutesInStartingState() throws {
    var status = GatewayStatus.stopped
    status.state = .running
    status.routes = [try presentationRoute(state: .resolving)]

    let presentation = GatewayRuntimePresentation(
        status: status,
        desiredEnabled: true,
        services: [presentationTestService()]
    )

    #expect(presentation.statusLabel == "Starting")
    #expect(presentation.tone == .neutral)
    #expect(presentation.isInProgress)
}

@Test func publishedServicePresentationPrioritizesActionableStates() throws {
    let service = presentationTestService()
    let activeCertificate = try presentationCertificate(state: .active)
    let readyRoute = try presentationRoute(state: .ready)

    var presentation = PublishedServicePresentation(
        service: service,
        certificate: activeCertificate,
        route: readyRoute,
        gatewayEnabled: true,
        tlsConfigured: true
    )
    #expect(presentation.statusLabel == "Live")
    #expect(presentation.detailLabel == "Enabled")
    #expect(presentation.tone == .positive)
    #expect(!presentation.isInProgress)
    #expect(presentation.canToggleEnabled)
    #expect(presentation.canOpen)
    #expect(presentation.canRetryCertificate)

    presentation = PublishedServicePresentation(
        service: service,
        certificate: nil,
        route: nil,
        gatewayEnabled: true,
        tlsConfigured: false
    )
    #expect(presentation.statusLabel == "HTTPS Setup")
    #expect(presentation.detailLabel == "Add certificate email")
    #expect(presentation.tone == .warning)

    presentation = PublishedServicePresentation(
        service: service,
        certificate: nil,
        route: nil,
        gatewayEnabled: true,
        tlsConfigured: true
    )
    #expect(presentation.statusLabel == "Starting")
    #expect(presentation.detailLabel == "Applying configuration")
    #expect(presentation.tone == .neutral)
    #expect(presentation.isInProgress)

    presentation = PublishedServicePresentation(
        service: service,
        certificate: try presentationCertificate(state: .degraded, error: "Renewal delayed"),
        route: readyRoute,
        gatewayEnabled: true,
        tlsConfigured: true
    )
    #expect(presentation.statusLabel == "HTTPS Warning")
    #expect(presentation.errorMessage == "Renewal delayed")

    presentation = PublishedServicePresentation(
        service: service,
        certificate: try presentationCertificate(state: .failed, error: "ACME failed"),
        route: try presentationRoute(state: .unavailable, error: "Target offline"),
        gatewayEnabled: true,
        tlsConfigured: true
    )
    #expect(presentation.statusLabel == "HTTPS Error")
    #expect(presentation.errorMessage == "ACME failed")
    #expect(presentation.certificateActionTitle == "Retry Certificate")
    #expect(!presentation.canOpen)

    presentation = PublishedServicePresentation(
        service: service,
        certificate: activeCertificate,
        route: try presentationRoute(state: .unavailable, error: "Target offline"),
        gatewayEnabled: true,
        tlsConfigured: true
    )
    #expect(presentation.statusLabel == "Target Offline")
    #expect(presentation.errorMessage == "Target offline")
}

@Test func publishedServicePresentationExplainsAutomaticRecoveryProgress() throws {
    let service = presentationTestService()
    let activeCertificate = try presentationCertificate(state: .active)

    var presentation = PublishedServicePresentation(
        service: service,
        certificate: activeCertificate,
        route: nil,
        gatewayEnabled: true,
        tlsConfigured: true,
        magicDNSState: .loading
    )
    #expect(presentation.statusLabel == "Loading")
    #expect(presentation.detailLabel == "Checking Magic DNS")
    #expect(presentation.isInProgress)

    presentation = PublishedServicePresentation(
        service: service,
        certificate: activeCertificate,
        route: try presentationRoute(state: .waiting),
        gatewayEnabled: true,
        tlsConfigured: true
    )
    #expect(presentation.statusLabel == "Starting")
    #expect(presentation.detailLabel == "Waiting for Magic DNS")
    #expect(presentation.isInProgress)

    presentation = PublishedServicePresentation(
        service: service,
        certificate: activeCertificate,
        route: try presentationRoute(state: .resolving),
        gatewayEnabled: true,
        tlsConfigured: true
    )
    #expect(presentation.statusLabel == "Starting")
    #expect(presentation.detailLabel == "Resolving target")
    #expect(presentation.isInProgress)

    var issuingCertificate = try presentationCertificate(state: .issuing)
    issuingCertificate.stage = .validating
    presentation = PublishedServicePresentation(
        service: service,
        certificate: issuingCertificate,
        route: nil,
        gatewayEnabled: true,
        tlsConfigured: true
    )
    #expect(presentation.statusLabel == "Starting")
    #expect(presentation.detailLabel == "Waiting for DNS validation")
    #expect(presentation.isInProgress)
}

@Test func publishedServiceStatusFeedbackOnlyPlaysForInteractiveTransitions() {
    let operationID = UUID()
    let inactiveStarting = PublishedServiceStatusFeedbackObservation(
        feedback: .none,
        operationID: operationID,
        isWindowInteractive: false
    )
    let inactiveSuccess = PublishedServiceStatusFeedbackObservation(
        feedback: .success,
        operationID: operationID,
        isWindowInteractive: false
    )
    let interactiveSuccess = PublishedServiceStatusFeedbackObservation(
        feedback: .success,
        operationID: operationID,
        isWindowInteractive: true
    )
    let interactiveStarting = PublishedServiceStatusFeedbackObservation(
        feedback: .none,
        operationID: operationID,
        isWindowInteractive: true
    )
    let interactiveFailure = PublishedServiceStatusFeedbackObservation(
        feedback: .failure,
        operationID: UUID(),
        isWindowInteractive: true
    )
    let unrelatedSuccess = PublishedServiceStatusFeedbackObservation(
        feedback: .success,
        operationID: nil,
        isWindowInteractive: true
    )

    #expect(
        inactiveSuccess.transition(from: inactiveStarting)
            == .discard(operationID: operationID)
    )
    #expect(interactiveSuccess.transition(from: inactiveSuccess) == nil)
    #expect(
        interactiveSuccess.transition(from: interactiveStarting)
            == .present(.success, operationID: operationID)
    )
    #expect(
        interactiveFailure.transition(from: interactiveSuccess)
            == .present(.failure, operationID: interactiveFailure.operationID!)
    )
    #expect(unrelatedSuccess.initialEvent() == nil)
}

@Test func publishedServiceStatusFeedbackRequiresTheMatchingOperationOutcome() throws {
    let service = presentationTestService()
    var disabledService = service
    disabledService.desiredEnabled = false
    let live = PublishedServicePresentation(
        service: service,
        certificate: try presentationCertificate(state: .active),
        route: try presentationRoute(state: .ready, servingMode: .https),
        gatewayEnabled: true,
        tlsConfigured: true
    )
    let disabled = PublishedServicePresentation(
        service: disabledService,
        certificate: nil,
        route: nil,
        gatewayEnabled: true,
        tlsConfigured: true
    )
    let waitingRetry = PublishedServicePresentation(
        service: service,
        certificate: try presentationCertificate(state: .degraded, error: "Retry later"),
        route: try presentationRoute(state: .ready, servingMode: .https),
        gatewayEnabled: true,
        tlsConfigured: true
    )

    #expect(
        PublishedServiceStatusFeedback(
            operation: nil,
            presentation: live,
            configurationApplied: true,
            serviceEnabled: true
        ) == .none
    )
    #expect(
        PublishedServiceStatusFeedback(
            operation: feedbackOperation(kind: .enable, expectsEnabled: true),
            presentation: live,
            configurationApplied: false,
            serviceEnabled: true
        ) == .none
    )
    #expect(
        PublishedServiceStatusFeedback(
            operation: feedbackOperation(kind: .enable, expectsEnabled: true),
            presentation: live,
            configurationApplied: true,
            serviceEnabled: true
        ) == .success
    )
    #expect(
        PublishedServiceStatusFeedback(
            operation: feedbackOperation(kind: .disable, expectsEnabled: false),
            presentation: disabled,
            configurationApplied: true,
            serviceEnabled: false
        ) == .success
    )
    #expect(
        PublishedServiceStatusFeedback(
            operation: feedbackOperation(kind: .retryCertificate, expectsEnabled: true),
            presentation: waitingRetry,
            configurationApplied: true,
            serviceEnabled: true
        ) == .none
    )
    #expect(
        PublishedServiceStatusFeedback(
            operation: feedbackOperation(
                kind: .retryCertificate,
                expectsEnabled: true,
                targetDeployment: nil,
                phase: .failed
            ),
            presentation: live,
            configurationApplied: true,
            serviceEnabled: true
        ) == .failure
    )
}

@Test func publishServiceProgressUsesCertificateStagesAndServingOutcomes() throws {
    var certificate = try presentationCertificate(state: .issuing)
    certificate.stage = .validating

    var presentation = PublishServiceProgressPresentation(
        certificate: certificate,
        route: nil,
        convergence: .init(
            desired: nil,
            applied: nil,
            phase: .converged,
            retryAt: nil,
            message: nil
        )
    )
    #expect(presentation.phase == .requesting)
    #expect(presentation.title == "Waiting for DNS Validation")
    #expect(presentation.showsProgress)

    presentation = PublishServiceProgressPresentation(
        certificate: try presentationCertificate(state: .active),
        route: try presentationRoute(state: .ready, servingMode: .https),
        convergence: .disabled
    )
    #expect(presentation.phase == .https)
    #expect(presentation.title == "Service Published")
    #expect(!presentation.showsProgress)

    presentation = PublishServiceProgressPresentation(
        certificate: try presentationCertificate(state: .failed, error: "Authorities exhausted"),
        route: try presentationRoute(state: .ready, servingMode: .httpOnly),
        convergence: .disabled
    )
    #expect(presentation.phase == .httpOnly)
    #expect(presentation.canRetry)
}

@Test func publishServiceProgressDoesNotSpinDuringScheduledApplyRetry() {
    let presentation = PublishServiceProgressPresentation(
        certificate: nil,
        route: nil,
        convergence: .init(
            desired: nil,
            applied: nil,
            phase: .retryScheduled,
            retryAt: nil,
            message: "Helper unavailable"
        )
    )

    #expect(presentation.phase == .waitingRetry)
    #expect(presentation.title == "Publishing Delayed")
    #expect(presentation.detail == "Helper unavailable")
    #expect(!presentation.showsProgress)
    #expect(!presentation.canRetry)
}

@Test func publishedServicePresentationHidesStaleErrorsWhileWaiting() throws {
    var disabledService = presentationTestService()
    disabledService.desiredEnabled = false
    let failedCertificate = try presentationCertificate(state: .failed, error: "Old failure")

    var presentation = PublishedServicePresentation(
        service: disabledService,
        certificate: failedCertificate,
        route: nil,
        gatewayEnabled: true,
        tlsConfigured: true
    )
    #expect(presentation.statusLabel == "Off")
    #expect(presentation.errorMessage == nil)
    #expect(presentation.canToggleEnabled)
    #expect(!presentation.canRetryCertificate)

    presentation = PublishedServicePresentation(
        service: disabledService,
        certificate: nil,
        route: nil,
        gatewayEnabled: true,
        tlsConfigured: false
    )
    #expect(!presentation.canToggleEnabled)

    presentation = PublishedServicePresentation(
        service: disabledService,
        certificate: nil,
        route: nil,
        gatewayEnabled: true,
        tlsConfigured: true,
        magicDNSState: .loading
    )
    #expect(presentation.canToggleEnabled)

    presentation = PublishedServicePresentation(
        service: presentationTestService(),
        certificate: failedCertificate,
        route: nil,
        gatewayEnabled: false,
        tlsConfigured: true
    )
    #expect(presentation.statusLabel == "Waiting")
    #expect(presentation.errorMessage == nil)
    #expect(!presentation.canOpen)
}

private func presentationTestService(id: String = "service-a") -> GatewayPublishedService {
    GatewayPublishedService(
        id: id,
        networkConfigID: "network-a",
        targetPeerID: "peer-a",
        publicNodeLabel: "a",
        publicDNSSuffix: "et.net.",
        lastKnownTargetHostname: "a",
        lastKnownMagicDNSSuffix: "et.net.",
        serviceLabel: id,
        publicHostname: "\(id).a.et.net",
        targetPort: 3_000,
        desiredEnabled: true,
        certificateID: id
    )
}

private func feedbackOperation(
    kind: PublishedServiceFeedbackOperation.Kind,
    expectsEnabled: Bool,
    targetDeployment: GatewayDeploymentIdentity? = .manual,
    phase: PublishedServiceFeedbackOperation.Phase = .pending
) -> PublishedServiceFeedbackOperation {
    PublishedServiceFeedbackOperation(
        id: UUID(),
        serviceID: "service-a",
        kind: kind,
        expectsEnabledService: expectsEnabled,
        targetDeployment: targetDeployment,
        phase: phase
    )
}

private func presentationCertificate(
    state: PresentationCertificateState,
    error: String? = nil
) throws -> GatewayCertificateStatus {
    let availability: GatewayCertificateAvailability = switch state {
    case .active, .renewing, .degraded: .valid
    case .failed, .pending, .issuing: .unavailable
    }
    let operation: GatewayCertificateOperation = switch state {
    case .active: .idle
    case .renewing: .renewing
    case .degraded: .waitingRetry
    case .failed: .suspended
    case .pending: .queued
    case .issuing: .issuing
    }
    let failure = error.map {
        GatewayFailure(
            source: .acmeAuthorization,
            kind: state == .failed ? .userActionRequired : .transient,
            code: state == .failed ? "unauthorized" : "retry_scheduled",
            message: $0,
            occurredAt: "2026-07-20T00:00:00Z",
            retryAt: state == .degraded ? "2026-07-20T00:05:00Z" : nil,
            authority: .letsEncrypt,
            challenge: "HTTP-01",
            dnsProvider: nil,
            acmeProblemType: nil,
            httpStatus: nil
        )
    }
    return GatewayCertificateStatus(
        id: "service-a",
        domains: ["service-a.a.et.net"],
        authority: .letsEncrypt,
        challenge: "http-01",
        activeAuthority: availability == .valid ? .letsEncrypt : nil,
        activeChallenge: availability == .valid ? "http-01" : nil,
        availability: availability,
        operation: operation,
        stage: nil,
        notBefore: nil,
        notAfter: nil,
        nextRenewalAt: nil,
        nextAttemptAt: state == .degraded ? "2026-07-20T00:05:00Z" : nil,
        lastAttemptAt: nil,
        failure: failure
    )
}

private enum PresentationCertificateState: Equatable {
    case active
    case renewing
    case degraded
    case failed
    case pending
    case issuing
}

private func presentationRoute(
    state: GatewayRouteResolutionState,
    servingMode: GatewayRouteServingMode = .unavailable,
    error: String? = nil
) throws -> GatewayRouteStatus {
    let payload: [String: Any?] = [
        "domain": "service-a.a.et.net",
        "upstream": "http://a.et.net:3000",
        "resolved_addresses": ["10.0.0.1"],
        "certificate_id": "service-a",
        "serving_mode": servingMode.rawValue,
        "resolution_state": state.rawValue,
        "last_resolved_at": nil,
        "last_online_at": nil,
        "last_error": error,
    ]
    return try decodePresentationFixture(payload)
}

private func decodePresentationFixture<Value: Decodable>(_ payload: [String: Any?]) throws -> Value {
    let normalized = payload.compactMapValues { $0 }
    let data = try JSONSerialization.data(withJSONObject: normalized)
    return try JSONDecoder().decode(Value.self, from: data)
}
