import EasyTierShared
import Foundation

enum GatewayConvergencePhase: Equatable, Sendable {
    case disabled
    case stopping
    case applying
    case converged
    case retryScheduled
    case blocked
}

struct GatewayConvergenceSnapshot: Equatable, Sendable {
    var desired: GatewayDeploymentIdentity?
    var applied: GatewayDeploymentIdentity?
    var phase: GatewayConvergencePhase
    var retryAt: Date?
    var message: String?

    static let disabled = GatewayConvergenceSnapshot(
        desired: nil,
        applied: nil,
        phase: .disabled,
        retryAt: nil,
        message: nil
    )

    var isConverged: Bool {
        phase == .converged && desired == applied
    }

    var isServingPreviousConfiguration: Bool {
        desired != nil && applied != nil && desired != applied
    }
}
