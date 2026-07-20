import EasyTierShared
import Foundation

struct PublishedServiceTargetOption: Identifiable, Equatable, Sendable {
    let peerID: String
    let instanceID: String?
    let hostname: String
    let ipv4: String?
    let isLocal: Bool

    var id: String { peerID }

    var label: String {
        let address = ipv4 ?? "Address unavailable"
        return "\(hostname) — \(address)"
    }

    static func creationOptions(
        members: [NetworkMemberStatus]
    ) -> [PublishedServiceTargetOption] {
        var optionsByPeerID: [String: PublishedServiceTargetOption] = [:]

        for member in members where member.isLive {
            let peerID = member.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !peerID.isEmpty,
                  peerID != "-",
                  let hostname = try? GatewayPublishedServicesValidator.normalizeLabel(
                      member.hostname,
                      field: "Target hostname"
                  )
            else {
                continue
            }

            let candidate = PublishedServiceTargetOption(
                peerID: peerID,
                instanceID: member.instanceID,
                hostname: hostname,
                ipv4: member.copyableIPv4Address,
                isLocal: member.isLocal
            )
            if optionsByPeerID[peerID] == nil || member.isLocal {
                optionsByPeerID[peerID] = candidate
            }
        }

        return optionsByPeerID.values.sorted { lhs, rhs in
            if lhs.isLocal != rhs.isLocal { return lhs.isLocal }
            let hostnameOrder = lhs.hostname.localizedStandardCompare(rhs.hostname)
            if hostnameOrder == .orderedSame { return lhs.peerID < rhs.peerID }
            return hostnameOrder == .orderedAscending
        }
    }

    static func initialPeerID(
        in options: [PublishedServiceTargetOption],
        preferredPeerID: String?
    ) -> String? {
        if let preferredPeerID,
           options.contains(where: { $0.peerID == preferredPeerID })
        {
            return preferredPeerID
        }
        return options.first(where: \.isLocal)?.peerID ?? options.first?.peerID
    }

    static func options(
        for service: GatewayPublishedService,
        currentIPv4: String,
        members: [NetworkMemberStatus]
    ) -> [PublishedServiceTargetOption] {
        var optionsByPeerID: [String: PublishedServiceTargetOption] = [:]

        for member in members {
            let peerID = member.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !peerID.isEmpty,
                  peerID != "-",
                  let ipv4 = member.copyableIPv4Address,
                  let hostname = try? GatewayPublishedServicesValidator.normalizeLabel(
                      member.hostname,
                      field: "Target hostname"
                  )
            else {
                continue
            }

            let candidate = PublishedServiceTargetOption(
                peerID: peerID,
                instanceID: member.instanceID,
                hostname: hostname,
                ipv4: ipv4,
                isLocal: member.isLocal
            )
            if optionsByPeerID[peerID] == nil || member.isLive {
                optionsByPeerID[peerID] = candidate
            }
        }

        if optionsByPeerID[service.targetPeerID] == nil {
            optionsByPeerID[service.targetPeerID] = PublishedServiceTargetOption(
                peerID: service.targetPeerID,
                instanceID: service.targetInstanceID,
                hostname: service.lastKnownTargetHostname,
                ipv4: currentIPv4 == "—" ? nil : currentIPv4,
                isLocal: false
            )
        }

        return optionsByPeerID.values.sorted { lhs, rhs in
            let lhsIsCurrent = isCurrent(lhs, for: service)
            let rhsIsCurrent = isCurrent(rhs, for: service)
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            let hostnameOrder = lhs.hostname.localizedStandardCompare(rhs.hostname)
            if hostnameOrder == .orderedSame { return lhs.peerID < rhs.peerID }
            return hostnameOrder == .orderedAscending
        }
    }

    private static func isCurrent(
        _ option: PublishedServiceTargetOption,
        for service: GatewayPublishedService
    ) -> Bool {
        if let targetInstanceID = service.targetInstanceID {
            return option.instanceID == targetInstanceID
        }
        return option.peerID == service.targetPeerID
    }
}
