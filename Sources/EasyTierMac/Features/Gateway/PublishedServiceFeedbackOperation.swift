import EasyTierShared
import Foundation

struct PublishedServiceFeedbackOperation: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case publish
        case update
        case enable
        case disable
        case retryCertificate
    }

    enum Phase: Equatable, Sendable {
        case pending
        case failed
    }

    let id: UUID
    let serviceID: String
    let kind: Kind
    let expectsEnabledService: Bool
    var targetDeployment: GatewayDeploymentIdentity?
    var phase: Phase
}
