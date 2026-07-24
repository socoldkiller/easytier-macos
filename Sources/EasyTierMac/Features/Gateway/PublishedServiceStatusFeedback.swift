enum PublishedServiceStatusFeedback: Equatable, Sendable {
    case none
    case success
    case failure

    init(
        operation: PublishedServiceFeedbackOperation?,
        presentation: PublishedServicePresentation,
        configurationApplied: Bool,
        serviceEnabled: Bool
    ) {
        guard let operation else {
            self = .none
            return
        }
        if operation.phase == .failed {
            self = .failure
        } else if operation.targetDeployment == nil {
            self = .none
        } else if !configurationApplied {
            self = .none
        } else if !operation.expectsEnabledService, !serviceEnabled {
            self = .success
        } else if operation.expectsEnabledService,
                  presentation.tone == .positive,
                  presentation.canOpen
        {
            self = .success
        } else if operation.expectsEnabledService,
                  presentation.isTerminalFailure
        {
            self = .failure
        } else {
            self = .none
        }
    }
}
