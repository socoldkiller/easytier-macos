import EasyTierShared
import Foundation

enum PublishedServiceTargetResolver {
    static func ipv4(
        for service: GatewayPublishedService,
        route: GatewayRouteStatus?,
        members: [NetworkMemberStatus]
    ) -> String? {
        let matchingMembers = members.filter { member in
            if let targetInstanceID = service.targetInstanceID {
                return member.instanceID == targetInstanceID
            }
            return member.peerID == service.targetPeerID
        }
        if let liveAddress = matchingMembers
            .first(where: \.isLive)?
            .copyableIPv4Address
        {
            return liveAddress
        }
        return matchingMembers.lazy.compactMap(\.copyableIPv4Address).first
    }
}
