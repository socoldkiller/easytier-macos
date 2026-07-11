import Foundation
import Testing
@testable import EasyTierShared

private actor RemoteConfigRPCTransport: EasyTierRPCTransport {
    private var calls: [EasyTierRPCRequest] = []

    func call(_ request: EasyTierRPCRequest) async throws -> String {
        calls.append(request)
        return #"{"ok":true}"#
    }

    func methods() -> [String] {
        calls.map(\.method)
    }
}

@Test func remoteConfigSessionPreparesLiveMemberForLoading() {
    let session = RemoteConfigSessionCoordinator.preparedSession(for: remoteMember())

    #expect(session.isLoading)
    #expect(session.loadError == nil)
    #expect(session.instanceID == "remote-instance")
    #expect(session.rpcURL.absoluteString == "tcp://10.126.126.9:15888")
}

@Test func remoteConfigSessionExplainsUnavailableMemberWithoutLoading() {
    var member = remoteMember()
    member.availability = .connecting
    let session = RemoteConfigSessionCoordinator.preparedSession(for: member)

    #expect(!session.isLoading)
    #expect(session.loadError?.contains("reconnecting") == true)
}

@Test func remoteConfigSessionsUseUniqueRequestIdentities() {
    let member = remoteMember()

    #expect(
        RemoteConfigSessionCoordinator.preparedSession(for: member).requestID
            != RemoteConfigSessionCoordinator.preparedSession(for: member).requestID
    )
}

@Test func remoteConfigSessionValidatesThenRestartsTheSameRemoteInstance() async throws {
    let transport = RemoteConfigRPCTransport()
    let client = EasyTierRemoteRPCClient(transport: transport)
    let instanceID = "11111111-2222-3333-4444-555555555555"
    let config = NetworkConfig(instance_id: instanceID, hostname: "updated-host")
    let session = RemoteConfigSession(
        rpcURL: try #require(URL(string: "tcp://10.126.126.9:15888")),
        instanceID: instanceID,
        member: remoteMember(instanceID: instanceID),
        config: config,
        originalConfig: NetworkConfig(instance_id: instanceID),
        isLoading: false,
        loadError: nil
    )

    try await RemoteConfigSessionCoordinator.validate(session, client: client)
    try await RemoteConfigSessionCoordinator.restart(session, client: client)

    #expect(await transport.methods() == ["validate_config", "run_network_instance"])
}

@Test func editingRemoteConfigClearsACompletedApplyState() {
    let instanceID = "11111111-2222-3333-4444-555555555555"
    var session = RemoteConfigSession(
        rpcURL: URL(string: "tcp://10.126.126.9:15888")!,
        instanceID: instanceID,
        member: remoteMember(instanceID: instanceID),
        config: NetworkConfig(instance_id: instanceID),
        originalConfig: NetworkConfig(instance_id: instanceID),
        isLoading: false,
        loadError: nil,
        applyState: .applied
    )

    session.config.hostname = "next-host"

    #expect(session.applyState == .idle)
    #expect(session.hasUnsavedChanges)
}

private func remoteMember(instanceID: String = "remote-instance") -> NetworkMemberStatus {
    NetworkMemberStatus(
        id: "remote-peer",
        isLocal: false,
        peerID: "42",
        instanceID: instanceID,
        virtualIPv4: "10.126.126.9/24",
        hostname: "remote-mac",
        version: "2.6.4",
        routeCost: "P2P",
        tunnelProto: "tcp",
        latency: "12 ms",
        uploadTotal: "1 KiB",
        downloadTotal: "2 KiB",
        lossRate: "0%",
        natType: "Open Internet",
        isPublicServer: false,
        txBytes: 1_024,
        rxBytes: 2_048
    )
}
