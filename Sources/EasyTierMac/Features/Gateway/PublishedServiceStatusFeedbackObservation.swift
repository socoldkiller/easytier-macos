struct PublishedServiceStatusFeedbackObservation: Equatable, Sendable {
    let feedback: PublishedServiceStatusFeedback
    let isWindowInteractive: Bool

    func transition(
        from previous: PublishedServiceStatusFeedbackObservation
    ) -> PublishedServiceStatusFeedback? {
        guard previous.isWindowInteractive, isWindowInteractive else { return nil }
        guard feedback != previous.feedback, feedback != .none else { return nil }
        return feedback
    }
}
