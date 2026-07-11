import Foundation
import Observation

public enum ConfigApplyResult: Equatable, Sendable {
    case saved
    case restarted
    case failed(String)

    public var succeeded: Bool {
        switch self {
        case .saved, .restarted:
            true
        case .failed:
            false
        }
    }
}

public struct LocalConfigApplyRequest: Equatable, Sendable {
    public var configID: String
    public var config: NetworkConfig
    public var replacing: NetworkInstance?

    public init(configID: String, config: NetworkConfig, replacing: NetworkInstance?) {
        self.configID = configID
        self.config = config
        self.replacing = replacing
    }
}

@MainActor
@Observable
public final class ConfigApplyCoordinator {
    public enum Phase: Equatable, Sendable {
        case idle
        case pending
        case applying
        case applied
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var targetConfigID: String?

    @ObservationIgnored private let debounceDuration: Duration
    @ObservationIgnored private let successDisplayDuration: Duration
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var successResetTask: Task<Void, Never>?
    @ObservationIgnored private var latestRequest: LocalConfigApplyRequest?
    @ObservationIgnored private var failedRequest: LocalConfigApplyRequest?
    @ObservationIgnored private var operation: ((LocalConfigApplyRequest) async -> ConfigApplyResult)?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var flushAfterCurrentApply = false

    package init(
        debounceDuration: Duration = .milliseconds(1_200),
        successDisplayDuration: Duration = .seconds(2)
    ) {
        self.debounceDuration = debounceDuration
        self.successDisplayDuration = successDisplayDuration
    }

    public func schedule(
        _ request: LocalConfigApplyRequest,
        operation: @escaping (LocalConfigApplyRequest) async -> ConfigApplyResult
    ) {
        self.operation = operation
        latestRequest = request
        failedRequest = nil
        targetConfigID = request.configID
        revision &+= 1
        phase = .pending
        successResetTask?.cancel()
        armDebounce(for: revision)
    }

    public func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        guard !isApplying else {
            flushAfterCurrentApply = true
            return
        }
        await applyLatest(expectedRevision: revision)
    }

    public func retry() async {
        guard let failedRequest else { return }
        self.failedRequest = nil
        latestRequest = failedRequest
        targetConfigID = failedRequest.configID
        revision &+= 1
        phase = .pending
        await applyLatest(expectedRevision: revision)
    }

    public func cancelPending() {
        revision &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        successResetTask?.cancel()
        successResetTask = nil
        latestRequest = nil
        failedRequest = nil
        operation = nil
        targetConfigID = nil
        flushAfterCurrentApply = false
        if !isApplying {
            phase = .idle
        }
    }

    private func armDebounce(for expectedRevision: UInt64) {
        debounceTask?.cancel()
        let delay = debounceDuration
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            await self.applyLatest(expectedRevision: expectedRevision)
        }
    }

    private func applyLatest(expectedRevision: UInt64) async {
        guard expectedRevision == revision, !isApplying else { return }
        guard let request = latestRequest, let operation else { return }

        debounceTask = nil
        latestRequest = nil
        isApplying = true
        phase = .applying
        let result = await operation(request)
        isApplying = false

        if latestRequest != nil {
            failedRequest = nil
            phase = .pending
            let nextRevision = revision
            if flushAfterCurrentApply {
                flushAfterCurrentApply = false
                await applyLatest(expectedRevision: nextRevision)
            } else {
                armDebounce(for: nextRevision)
            }
            return
        }

        flushAfterCurrentApply = false
        switch result {
        case .saved, .restarted:
            failedRequest = nil
            self.operation = nil
            phase = .applied
            armSuccessReset(for: revision)
        case let .failed(message):
            failedRequest = request
            phase = .failed(message)
        }
    }

    private func armSuccessReset(for expectedRevision: UInt64) {
        successResetTask?.cancel()
        let delay = successDisplayDuration
        successResetTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, self.revision == expectedRevision, self.phase == .applied else { return }
            self.phase = .idle
            self.targetConfigID = nil
        }
    }
}
