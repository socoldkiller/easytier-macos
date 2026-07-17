@MainActor
final class SoftwareUpdatePreparationRace {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    static func run(
        timeout: Duration,
        operation: @escaping @MainActor () async -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let race = SoftwareUpdatePreparationRace(continuation: continuation)
            race.start(timeout: timeout, operation: operation)
        }
    }

    private init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    private func start(
        timeout: Duration,
        operation: @escaping @MainActor () async -> Void
    ) {
        operationTask = Task {
            await operation()
            finish(completed: true)
        }
        timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            operationTask?.cancel()
            finish(completed: false)
        }
    }

    private func finish(completed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        if completed {
            timeoutTask?.cancel()
        }
        operationTask = nil
        timeoutTask = nil
        continuation.resume(returning: completed)
    }
}
