import EasyTierShared
import Foundation

enum PublishedServiceFormValidation {
    static let publicNameGuidance = "Letters, numbers, and hyphens, up to 63 characters."

    static func normalizedPublicName(_ value: String) -> String? {
        try? GatewayPublishedServicesValidator.normalizeLabel(value, field: "Public name")
    }

    static func publicNameError(
        _ value: String,
        targetDomain: String,
        existingPublicHostnames: Set<String>
    ) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return "Enter a public name." }
        guard let normalizedName = normalizedPublicName(value) else {
            return "Use 1–63 letters, numbers, or hyphens; don't start or end with a hyphen."
        }
        let hostname = "\(normalizedName).\(targetDomain)"
        guard !existingPublicHostnames.contains(hostname) else {
            return "This public address is already in use."
        }
        return nil
    }

    static func publicHostname(publicName: String, targetDomain: String) -> String {
        let name = normalizedPublicName(publicName) ?? "service"
        return "\(name).\(targetDomain)"
    }

    static func parsedPort(_ value: String) -> Int? {
        guard let port = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1 ... 65_535).contains(port)
        else {
            return nil
        }
        return port
    }

    static func portError(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return "Enter a port." }
        return parsedPort(value) == nil ? "Enter a port from 1 to 65535." : nil
    }

    static func normalizedContactEmail(_ value: String) -> String? {
        try? GatewayPublishedServicesValidator.normalizeContactEmail(value)
    }

    static func contactEmailError(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return "Enter a certificate contact email." }
        return normalizedContactEmail(value) == nil ? "Enter a valid email address." : nil
    }

    static func editHasChanges(
        service: GatewayPublishedService,
        selectedTarget: PublishedServiceTargetOption,
        port: Int,
        certificateSelection: GatewayServiceCertificateSelection,
        currentSelection: GatewayServiceCertificateSelection
    ) -> Bool {
        port != service.targetPort
            || selectedTarget.peerID != service.targetPeerID
            || selectedTarget.instanceID != service.targetInstanceID
            || selectedTarget.hostname != service.lastKnownTargetHostname
            || certificateSelection != currentSelection
    }
}
