@testable import EasyTierMac
import EasyTierShared
import Testing

@Test func networkCollectionSummaryUsesAggregatePrecedenceAndCountsEveryState() {
    let items = [
        presentationItem(id: "connected", state: .connected),
        presentationItem(id: "connecting", state: .connecting),
        presentationItem(id: "failed", state: .error),
        presentationItem(id: "stopped", state: .idle),
    ]

    let summary = NetworkCollectionSummary(items: items)

    #expect(summary.totalCount == 4)
    #expect(summary.connectedCount == 1)
    #expect(summary.connectingCount == 1)
    #expect(summary.failedCount == 1)
    #expect(summary.stoppedCount == 1)
    #expect(summary.connectionState == .error)
    #expect(summary.displayText == "1 Connected · 1 Connecting · 1 Issue · 1 Stopped")
}

@Test func networkCollectionSummaryHandlesEmptyAndStoppedCollections() {
    #expect(NetworkCollectionSummary(items: []).displayText == "No Networks")

    let stopped = [
        presentationItem(id: "first", state: .idle),
        presentationItem(id: "second", state: .idle),
    ]
    let summary = NetworkCollectionSummary(items: stopped)

    #expect(summary.connectionState == .idle)
    #expect(summary.displayText == "All Networks Stopped")
}

@MainActor
@Test func networkPresentationResolverDistinguishesLocalAndManagedNetworks() {
    let local = NetworkConfig(instance_id: "local-id", hostname: "local-host", network_name: "Local")
    let store = EasyTierAppStore(client: PreviewEasyTierCoreClient())
    store.configs = [local]
    store.selectedConfigID = local.id

    var items = NetworkPresentationResolver.items(for: store)

    #expect(items.first?.source == .local)
    #expect(items.first?.canToggle == true)
    #expect(items.first?.isSelected == true)

    store.instances = [NetworkInstance(instance_id: "managed-id", name: "Managed", running: true)]
    store.setConfigurationAuthority(.configServer)
    items = NetworkPresentationResolver.items(for: store)

    #expect(items.first?.source == .configServer)
    #expect(items.first?.canToggle == false)
}

private func presentationItem(id: String, state: ConnectionGlyphState) -> NetworkPresentationItem {
    NetworkPresentationItem(
        id: id,
        networkName: id,
        hostname: nil,
        source: .local,
        readiness: state == .idle ? .stopped : .ready,
        connectionState: state,
        isSelected: false,
        canToggle: true
    )
}
