import Foundation

struct PublishedServiceStatusFeedbackObservation: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case present(PublishedServiceStatusFeedback, operationID: UUID)
        case discard(operationID: UUID)
    }

    let feedback: PublishedServiceStatusFeedback
    let operationID: UUID?
    let isWindowInteractive: Bool

    func transition(
        from previous: PublishedServiceStatusFeedbackObservation
    ) -> Event? {
        guard operationID != previous.operationID || feedback != previous.feedback else { return nil }
        return terminalEvent()
    }

    func initialEvent() -> Event? {
        terminalEvent()
    }

    private func terminalEvent() -> Event? {
        guard let operationID, feedback != .none else { return nil }
        if isWindowInteractive {
            return .present(feedback, operationID: operationID)
        }
        return .discard(operationID: operationID)
    }
}
