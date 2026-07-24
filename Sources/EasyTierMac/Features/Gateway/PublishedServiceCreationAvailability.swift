import EasyTierShared

struct PublishedServiceCreationAvailability: Equatable, Sendable {
    let isAvailable: Bool
    let emptyStateDescription: String
    let helpText: String

    init(magicDNSIsReady: Bool, hasTargets: Bool) {
        if !magicDNSIsReady {
            isAvailable = false
            emptyStateDescription = "Wait for Magic DNS to become ready before publishing a service."
            helpText = "Wait for Magic DNS to become ready"
        } else if !hasTargets {
            isAvailable = false
            emptyStateDescription = "Run a network with at least one online member before publishing a service."
            helpText = "Run a network with at least one online member first"
        } else {
            isAvailable = true
            emptyStateDescription = "Publish an HTTP service from an online network member."
            helpText = "Publish a service from an online network member"
        }
    }

    init(
        magicDNSState: MagicDNSOperationalState,
        targets: [PublishedServiceTargetOption]
    ) {
        self.init(
            magicDNSIsReady: magicDNSState == .ready,
            hasTargets: !targets.isEmpty
        )
    }
}
