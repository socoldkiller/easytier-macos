enum PublishedServiceStatusFeedback: Equatable, Sendable {
    case none
    case success
    case failure

    init(presentation: PublishedServicePresentation) {
        if presentation.tone == .positive, presentation.canOpen {
            self = .success
        } else if presentation.tone == .warning {
            self = .failure
        } else {
            self = .none
        }
    }
}
