import Foundation
import Testing
@testable import EasyTierMac
@testable import EasyTierShared

@Test(arguments: ["api", "API-2", "  my-service  "])
func publishedServicePublicNameNormalizesValidLabels(_ input: String) {
    #expect(
        PublishedServiceFormValidation.normalizedPublicName(input)
            == input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    )
    #expect(
        PublishedServiceFormValidation.publicNameError(
            input,
            targetDomain: "target.et.net",
            existingPublicHostnames: []
        ) == nil
    )
}

@Test(arguments: ["-api", "api-", "api_service", String(repeating: "a", count: 64)])
func publishedServicePublicNameRejectsInvalidLabels(_ input: String) {
    #expect(PublishedServiceFormValidation.normalizedPublicName(input) == nil)
    #expect(
        PublishedServiceFormValidation.publicNameError(
            input,
            targetDomain: "target.et.net",
            existingPublicHostnames: []
        ) == "Use 1–63 letters, numbers, or hyphens; don't start or end with a hyphen."
    )
}

@Test func publishedServicePublicNameExplainsEmptyAndDuplicateValues() {
    #expect(
        PublishedServiceFormValidation.publicNameError(
            "   ",
            targetDomain: "target.et.net",
            existingPublicHostnames: []
        ) == "Enter a public name."
    )
    #expect(
        PublishedServiceFormValidation.publicNameError(
            "API",
            targetDomain: "target.et.net",
            existingPublicHostnames: ["api.target.et.net"]
        ) == "This public address is already in use."
    )
}

@Test func publishedServicePublicHostnameUsesNormalizedNameOrPlaceholder() {
    #expect(
        PublishedServiceFormValidation.publicHostname(
            publicName: " API ",
            targetDomain: "target.et.net"
        ) == "api.target.et.net"
    )
    #expect(
        PublishedServiceFormValidation.publicHostname(
            publicName: "",
            targetDomain: "target.et.net"
        ) == "service.target.et.net"
    )
}

@Test(arguments: ["1", "65535", " 8080 "])
func publishedServicePortAcceptsValidValues(_ input: String) {
    #expect(
        PublishedServiceFormValidation.parsedPort(input)
            == Int(input.trimmingCharacters(in: .whitespacesAndNewlines))
    )
    #expect(PublishedServiceFormValidation.portError(input) == nil)
}

@Test(arguments: ["abc", "0", "65536"])
func publishedServicePortRejectsInvalidValues(_ input: String) {
    #expect(PublishedServiceFormValidation.parsedPort(input) == nil)
    #expect(PublishedServiceFormValidation.portError(input) == "Enter a port from 1 to 65535.")
}

@Test func publishedServicePortExplainsEmptyValue() {
    #expect(PublishedServiceFormValidation.parsedPort("  ") == nil)
    #expect(PublishedServiceFormValidation.portError("  ") == "Enter a port.")
}

@Test(arguments: ["ops@example.com", "  ops@example.com  "])
func publishedServiceContactEmailNormalizesValidValues(_ input: String) {
    #expect(
        PublishedServiceFormValidation.normalizedContactEmail(input)
            == input.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    #expect(PublishedServiceFormValidation.contactEmailError(input) == nil)
}

@Test(arguments: ["ops example.com", "@example.com", "ops@"])
func publishedServiceContactEmailRejectsInvalidValues(_ input: String) {
    #expect(PublishedServiceFormValidation.normalizedContactEmail(input) == nil)
    #expect(PublishedServiceFormValidation.contactEmailError(input) == "Enter a valid email address.")
}

@Test func publishedServiceContactEmailExplainsEmptyValue() {
    #expect(PublishedServiceFormValidation.normalizedContactEmail("  ") == nil)
    #expect(
        PublishedServiceFormValidation.contactEmailError("  ")
            == "Enter a certificate contact email."
    )
}

@Test func publishedServiceEditChangeDetectionCoversEveryEditableValue() {
    let service = publishedServiceFormTestService()
    let unchangedTarget = publishedServiceFormTestTarget()

    #expect(
        !PublishedServiceFormValidation.editHasChanges(
            service: service,
            selectedTarget: unchangedTarget,
            port: service.targetPort,
            certificatePolicy: service.certificatePolicy
        )
    )
    #expect(
        PublishedServiceFormValidation.editHasChanges(
            service: service,
            selectedTarget: unchangedTarget,
            port: 8_080,
            certificatePolicy: service.certificatePolicy
        )
    )
    #expect(
        PublishedServiceFormValidation.editHasChanges(
            service: service,
            selectedTarget: publishedServiceFormTestTarget(peerID: "peer-b"),
            port: service.targetPort,
            certificatePolicy: service.certificatePolicy
        )
    )
    #expect(
        PublishedServiceFormValidation.editHasChanges(
            service: service,
            selectedTarget: publishedServiceFormTestTarget(instanceID: "instance-b"),
            port: service.targetPort,
            certificatePolicy: service.certificatePolicy
        )
    )
    #expect(
        PublishedServiceFormValidation.editHasChanges(
            service: service,
            selectedTarget: publishedServiceFormTestTarget(hostname: "other"),
            port: service.targetPort,
            certificatePolicy: service.certificatePolicy
        )
    )
    #expect(
        PublishedServiceFormValidation.editHasChanges(
            service: service,
            selectedTarget: unchangedTarget,
            port: service.targetPort,
            certificatePolicy: GatewayCertificatePolicy(authority: .zeroSSL)
        )
    )
}

@Test func publishedServiceCreationAvailabilityExplainsEachState() {
    let waitingForDNS = PublishedServiceCreationAvailability(
        magicDNSIsReady: false,
        hasTargets: true
    )
    let missingTarget = PublishedServiceCreationAvailability(
        magicDNSIsReady: true,
        hasTargets: false
    )
    let available = PublishedServiceCreationAvailability(
        magicDNSIsReady: true,
        hasTargets: true
    )

    #expect(!waitingForDNS.isAvailable)
    #expect(
        waitingForDNS.emptyStateDescription
            == "Wait for Magic DNS to become ready before publishing a service."
    )
    #expect(waitingForDNS.helpText == "Wait for Magic DNS to become ready")
    #expect(!missingTarget.isAvailable)
    #expect(
        missingTarget.emptyStateDescription
            == "Run a network with at least one online member before publishing a service."
    )
    #expect(missingTarget.helpText == "Run a network with at least one online member first")
    #expect(available.isAvailable)
    #expect(
        available.emptyStateDescription
            == "Publish an HTTP service from an online network member."
    )
    #expect(available.helpText == "Publish a service from an online network member")
}

private func publishedServiceFormTestService() -> GatewayPublishedService {
    GatewayPublishedService(
        id: "service-a",
        networkConfigID: "network-a",
        targetPeerID: "peer-a",
        targetInstanceID: "instance-a",
        publicNodeLabel: "target",
        publicDNSSuffix: "et.net.",
        lastKnownTargetHostname: "target",
        lastKnownMagicDNSSuffix: "et.net.",
        serviceLabel: "api",
        publicHostname: "api.target.et.net",
        targetPort: 3_000,
        desiredEnabled: true
    )
}

private func publishedServiceFormTestTarget(
    peerID: String = "peer-a",
    instanceID: String = "instance-a",
    hostname: String = "target"
) -> PublishedServiceTargetOption {
    PublishedServiceTargetOption(
        peerID: peerID,
        instanceID: instanceID,
        hostname: hostname,
        ipv4: "10.0.0.8",
        isLocal: false
    )
}
