import EasyTierShared
import Foundation

enum PublishedServiceFormValidation {
    static let defaultPort = 80
    static let publicNameGuidance = "Optional; letters, numbers, and hyphens, up to 63 characters."

    static func normalizedPublicName(_ value: String) -> String? {
        try? GatewayPublishedServicesValidator.normalizeServiceLabel(value)
    }

    static func publicNameError(
        _ value: String,
        targetDomain: String,
        existingPublicHostnames: Set<String>
    ) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedName = normalizedPublicName(value) else {
            return "Use 1–63 letters, numbers, or hyphens; don't start or end with a hyphen."
        }
        let hostname = trimmedValue.isEmpty
            ? targetDomain
            : "\(normalizedName).\(targetDomain)"
        guard !existingPublicHostnames.contains(hostname) else {
            return "This public address is already in use."
        }
        return nil
    }

    static func publicHostname(publicName: String, targetDomain: String) -> String {
        guard let name = normalizedPublicName(publicName), !name.isEmpty else {
            return targetDomain
        }
        return "\(name).\(targetDomain)"
    }

    static func parsedPort(_ value: String) -> Int? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return defaultPort }
        guard let port = Int(value),
              (1 ... 65_535).contains(port)
        else {
            return nil
        }
        return port
    }

    static func portError(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
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
