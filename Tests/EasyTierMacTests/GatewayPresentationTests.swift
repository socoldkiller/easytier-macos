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

    status.state = .running
    presentation = GatewayRuntimePresentation(
        status: status,
        desiredEnabled: true,
        services: [presentationTestService()]
    )
    #expect(presentation.statusLabel == "Running")
    #expect(presentation.tone == .positive)
    #expect(presentation.serviceCountLabel == "1 Service")

    status.state = .stopping
    presentation = GatewayRuntimePresentation(
        status: status,
        desiredEnabled: true,
        services: []
    )
    #expect(presentation.statusLabel == "Stopping")
    #expect(presentation.tone == .neutral)

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
    #expect(presentation.tone == .positive)
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
    #expect(presentation.statusLabel == "TLS Required")
    #expect(presentation.tone == .warning)

    presentation = PublishedServicePresentation(
        service: service,
        certificate: nil,
        route: nil,
        gatewayEnabled: true,
        tlsConfigured: true
    )
    #expect(presentation.statusLabel == "Starting")
    #expect(presentation.tone == .neutral)

    presentation = PublishedServicePresentation(
        service: service,
        certificate: try presentationCertificate(state: .degraded, error: "Renewal delayed"),
        route: readyRoute,
        gatewayEnabled: true,
        tlsConfigured: true
    )
    #expect(presentation.statusLabel == "TLS Warning")
    #expect(presentation.errorMessage == "Renewal delayed")

    presentation = PublishedServicePresentation(
        service: service,
        certificate: try presentationCertificate(state: .failed, error: "ACME failed"),
        route: try presentationRoute(state: .unavailable, error: "Target offline"),
        gatewayEnabled: true,
        tlsConfigured: true
    )
    #expect(presentation.statusLabel == "TLS Error")
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
        desiredEnabled: true
    )
}

private func presentationCertificate(
    state: GatewayCertificateState,
    error: String? = nil
) throws -> GatewayCertificateStatus {
    let payload: [String: Any?] = [
        "id": "service-a",
        "domains": ["service-a.a.et.net"],
        "challenge": "http-01",
        "state": state.rawValue,
        "not_before": nil,
        "not_after": nil,
        "next_renewal_at": nil,
        "last_attempt_at": nil,
        "last_error": error,
    ]
    return try decodePresentationFixture(payload)
}

private func presentationRoute(
    state: GatewayRouteResolutionState,
    error: String? = nil
) throws -> GatewayRouteStatus {
    let payload: [String: Any?] = [
        "domain": "service-a.a.et.net",
        "upstream": "http://a.et.net:3000",
        "resolved_addresses": ["10.0.0.1"],
        "certificate_id": "service-a",
        "resolution_state": state.rawValue,
        "last_resolved_at": nil,
        "last_error": error,
    ]
    return try decodePresentationFixture(payload)
}

private func decodePresentationFixture<Value: Decodable>(_ payload: [String: Any?]) throws -> Value {
    let normalized = payload.compactMapValues { $0 }
    let data = try JSONSerialization.data(withJSONObject: normalized)
    return try JSONDecoder().decode(Value.self, from: data)
}
