import Foundation

struct RuntimeIntentObservation {
    var instanceID: String
    var hostname: String?
    var ipv4: String?
    var rpcURL: URL?
    var label: String
}

enum RuntimeIntentReconciliation: Equatable {
    case ignore
    case unreachable
    case applied
    case conflict(current: String?, base: String?)
    case apply(hostname: String)
}

enum RuntimeIntentReconciler {
    static func upsert(_ intent: RuntimeIntent, in intents: inout [RuntimeIntent]) -> RuntimeIntent {
        if let index = intents.firstIndex(where: { $0.reconcileKey == intent.reconcileKey }) {
            var updated = intent
            updated.id = intents[index].id
            intents[index] = updated
            return updated
        }
        intents.append(intent)
        return intent
    }

    @discardableResult
    static func update(
        id: String,
        in intents: inout [RuntimeIntent],
        mutate: (inout RuntimeIntent) -> Void
    ) -> Bool {
        guard let index = intents.firstIndex(where: { $0.id == id }) else { return false }
        var updated = intents[index]
        mutate(&updated)
        guard intents[index] != updated else { return false }
        intents[index] = updated
        return true
    }

    @discardableResult
    static func removeExpired(
        from intents: inout [RuntimeIntent],
        now: Date = Date(),
        maximumCount: Int = 20
    ) -> Bool {
        let original = intents
        let appliedExpiration = now.addingTimeInterval(-300)
        let unreachableExpiration = now.addingTimeInterval(-600)

        intents.removeAll { intent in
            (intent.status == .applied && intent.updatedAt < appliedExpiration)
                || (intent.status == .unreachable && intent.updatedAt < unreachableExpiration)
        }
        if intents.count > maximumCount {
            intents = Array(intents.suffix(maximumCount))
        }
        return intents != original
    }

    static func reconciliation(
        for intent: RuntimeIntent,
        observation: RuntimeIntentObservation?,
        force: Bool
    ) -> RuntimeIntentReconciliation {
        guard let desiredHostname = intent.desiredHostname.trimmedNilIfEmpty else { return .ignore }
        guard let observation else { return .unreachable }

        let currentHostname = observation.hostname?.trimmedNilIfEmpty
        if currentHostname == desiredHostname {
            return .applied
        }
        if !force, intent.status == .conflict {
            return .ignore
        }

        let baseHostname = intent.baseHostname?.trimmedNilIfEmpty
        guard force || currentHostname == baseHostname else {
            return .conflict(current: currentHostname, base: baseHostname)
        }
        return .apply(hostname: desiredHostname)
    }
}
