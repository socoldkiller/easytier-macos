import Foundation
import Testing
@testable import EasyTierShared

@Test func runtimeInfoDerivesLocalAndPeerMembers() throws {
    let json = """
    {
      "dev_name": "utun8",
      "my_node_info": {
        "virtual_ipv4": { "address": { "addr": 168427521 }, "network_length": 24 },
        "hostname": "macbook",
        "version": "2.4.0",
        "peer_id": 100,
        "stun_info": { "udp_nat_type": 1, "tcp_nat_type": 0, "last_update_time": 0 }
      },
      "peer_route_pairs": [
        {
          "route": {
            "peer_id": 200,
            "ipv4_addr": { "address": { "addr": 168427522 }, "network_length": 24 },
            "next_hop_peer_id": 200,
            "cost": 1,
            "hostname": "office-mini",
            "inst_id": "22222222-2222-2222-2222-222222222222",
            "stun_info": { "udp_nat_type": 6, "tcp_nat_type": 0, "last_update_time": 0 },
            "version": "2.4.0"
          },
          "peer": {
            "peer_id": 200,
            "conns": [
              {
                "conn_id": "c1",
                "my_peer_id": 100,
                "is_client": true,
                "peer_id": 200,
                "features": [],
                "tunnel": { "tunnel_type": "tcp", "local_addr": { "url": "tcp://127.0.0.1:11010" }, "remote_addr": { "url": "tcp://example.com:11010" } },
                "stats": { "rx_bytes": 4096, "tx_bytes": 2048, "rx_packets": 4, "tx_packets": 2, "latency_us": 1500 },
                "loss_rate": 0.25
              }
            ]
          }
        }
      ],
      "running": true,
      "instance_id": "11111111-1111-1111-1111-111111111111"
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    let members = info.memberStatuses

    #expect(members.count == 2)
    #expect(members[0].isLocal)
    #expect(members[0].instanceID == "11111111-1111-1111-1111-111111111111")
    #expect(members[0].hostname == "macbook")
    #expect(members[0].virtualIPv4 == "10.10.0.1/24")
    #expect(members[0].copyableIPv4Address == "10.10.0.1")
    #expect(members[0].natType == "Open Internet")

    #expect(!members[1].isLocal)
    #expect(members[1].instanceID == "22222222-2222-2222-2222-222222222222")
    #expect(members[1].peerID == "200")
    #expect(members[1].virtualIPv4 == "10.10.0.2/24")
    #expect(members[1].copyableIPv4Address == "10.10.0.2")
    #expect(members[1].routeCost == "P2P")
    #expect(members[1].tunnelProto == "tcp")
    #expect(members[1].latency == "2 ms")
    #expect(members[1].uploadTotal == "2.0 KiB")
    #expect(members[1].downloadTotal == "4.0 KiB")
    #expect(members[1].lossRate == "25%")
    #expect(members[1].natType == "Symmetric")
}

@Test func runtimeInfoReportsLocalOnlyNodeAsFullyConnected() throws {
    let json = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "running": true
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    let instance = NetworkInstance(instance_id: "local", name: "local", running: true, detail: info)

    #expect(info.isFullyConnected)
    #expect(instance.isFullyConnected)
    #expect(!info.isFullyConnected(expectRemotePeers: true))
    #expect(!instance.isFullyConnected(expectRemotePeers: true))
}

@Test func runtimeInfoTreatsRemotePeerRoutesWithIPv4AsUsable() throws {
    let waitingJSON = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "peer_route_pairs": [
        {
          "route": { "peer_id": 200, "hostname": "office-mini", "cost": 1 },
          "peer": { "peer_id": 200, "conns": [] }
        }
      ],
      "running": true
    }
    """
    let usableJSON = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "peer_route_pairs": [
        {
          "route": { "peer_id": 200, "ipv4_addr": { "address": { "addr": 168427522 },
                     "network_length": 24 }, "hostname": "office-mini", "cost": 2 },
          "peer": { "peer_id": 200, "conns": [] }
        }
      ],
      "running": true
    }
    """
    let routesOnlyJSON = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "routes": [
        { "peer_id": 200, "ipv4_addr": { "address": { "addr": 168427522 }, "network_length": 24 }, "hostname": "office-mini", "cost": 2 }
      ],
      "running": true
    }
    """
    let mixedWithPublicServerJSON = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "peer_route_pairs": [
        {
          "route": { "peer_id": 200, "hostname": "PublicServer_demo", "cost": 1 },
          "peer": { "peer_id": 200, "conns": [ { "conn_id": "public-server" } ] }
        },
        {
          "route": { "peer_id": 201, "ipv4_addr": { "address": { "addr": 168427522 },
                     "network_length": 24 }, "hostname": "office-mini", "cost": 1 },
          "peer": { "peer_id": 201, "conns": [] }
        }
      ],
      "running": true
    }
    """

    let waiting = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(waitingJSON.utf8))
    let usable = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(usableJSON.utf8))
    let routesOnly = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(routesOnlyJSON.utf8))
    let mixedWithPublicServer = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(mixedWithPublicServerJSON.utf8))

    #expect(!waiting.isFullyConnected)
    #expect(!waiting.isFullyConnected(expectRemotePeers: true))
    #expect(usable.isFullyConnected)
    #expect(usable.isFullyConnected(expectRemotePeers: true))
    #expect(routesOnly.isFullyConnected)
    #expect(routesOnly.isFullyConnected(expectRemotePeers: true))
    #expect(mixedWithPublicServer.isFullyConnected)
    #expect(mixedWithPublicServer.isFullyConnected(expectRemotePeers: true))
}

@Test func runtimeInfoTreatsAnyReachablePublicServerAsFullyConnected() throws {
    let json = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "peer_route_pairs": [
        {
          "route": { "peer_id": 200, "hostname": "PublicServer_down", "cost": 1 },
          "peer": { "peer_id": 200, "conns": [] }
        },
        {
          "route": {
            "peer_id": 201,
            "hostname": "relay-online",
            "cost": 1,
            "feature_flag": { "is_public_server": true }
          },
          "peer": { "peer_id": 201, "conns": [ { "conn_id": "relay-online" } ] }
        },
        {
          "route": { "peer_id": 202, "hostname": "office-mini", "cost": 2 },
          "peer": { "peer_id": 202, "conns": [] }
        }
      ],
      "running": true
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))

    #expect(info.isFullyConnected)
    #expect(info.isFullyConnected(expectRemotePeers: true))
}

@Test func runtimeInfoRequiresReachablePublicServerWhenPublicServersAreKnown() throws {
    let json = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "peer_route_pairs": [
        {
          "route": { "peer_id": 200, "hostname": "PublicServer_one", "cost": 1 },
          "peer": { "peer_id": 200, "conns": [] }
        },
        {
          "route": {
            "peer_id": 201,
            "hostname": "relay-two",
            "cost": 1,
            "feature_flag": { "is_public_server": true }
          },
          "peer": { "peer_id": 201, "conns": [] }
        }
      ],
      "running": true
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))

    #expect(!info.isFullyConnected)
    #expect(!info.isFullyConnected(expectRemotePeers: true))
}

@Test func runtimeInfoReadsCurrentApiMemberFields() throws {
    let json = """
    {
      "my_node_info": {
        "ipv4_addr": "10.10.0.1/24",
        "hostname": "public-node",
        "peer_id": 100,
        "feature_flag": { "is_public_server": true }
      },
      "peer_route_pairs": [
        {
          "route": {
            "peer_id": 200,
            "ipv4_addr": { "address": { "addr": 168427522 }, "network_length": 24 },
            "hostname": "remote-public",
            "stun_info": { "udp_nat_type": 3 },
            "feature_flag": { "is_public_server": true }
          },
          "peer": {
            "peer_id": 200,
            "default_conn_id": {
              "part1": 286331153,
              "part2": 572666675,
              "part3": 1145328981,
              "part4": 1717991287
            },
            "conns": [
              { "conn_id": "backup", "loss_rate": 0.8 },
              { "conn_id": "11111111-2222-3333-4444-555566667777", "loss_rate": 0.125 }
            ]
          }
        }
      ]
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    let members = info.memberStatuses

    #expect(members[0].virtualIPv4 == "10.10.0.1/24")
    #expect(members[0].isPublicServer)
    #expect(members[1].lossRate == "93%")
    #expect(members[1].natType == "Full Cone")
    #expect(members[1].isPublicServer)
}

@Test func runtimeInfoRejectsProtobufCamelCaseFieldNames() throws {
    let json = """
    {
      "peer_route_pairs": [
        {
          "route": {
            "peerId": 200,
            "ipv4Addr": "10.10.0.2/24",
            "hostname": "PublicServer_demo",
            "stunInfo": { "udpNatType": "Symmetric" }
          },
          "peer": {
            "peerId": 200,
            "conns": [
              { "connId": "a", "lossRate": 0.2 },
              { "connId": "b", "lossRate": 0.1 }
            ]
          }
        }
      ]
    }
    """

    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    }
}

@Test func runtimeInfoRejectsStringNatEnumNames() throws {
    let json = """
    {
      "peer_route_pairs": [
        {
          "route": {
            "peer_id": 200,
            "hostname": "remote",
            "stun_info": { "udp_nat_type": "PORT_RESTRICTED" }
          },
          "peer": { "peer_id": 200, "conns": [] }
        }
      ]
    }
    """

    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    }
}

@Test func runtimeInfoTotalsTrafficFromPeerRoutePairs() throws {
    let json = """
    {
      "peer_route_pairs": [
        { "peer": { "peer_id": 1, "conns": [ { "stats": { "rx_bytes": 100, "tx_bytes": 200, "latency_us": 900 } } ] } },
        { "peer": { "peer_id": 2, "conns": [ { "stats": { "rx_bytes": 300, "tx_bytes": 400 } } ] } }
      ]
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    let totals = info.trafficTotals

    #expect(totals.txBytes == 600)
    #expect(totals.rxBytes == 400)
    #expect(info.peer_route_pairs?.first?.peer?.conns?.first?.stats?.latency_us == 900)
}

@Test func runtimeInfoRejectsAConnectionWithUnexpectedShape() throws {
    let json = """
    {
      "my_node_info": { "hostname": "macbook", "version": "2.4.0", "peer_id": 100 },
      "peer_route_pairs": [
        {
          "route": { "peer_id": 200, "hostname": "office-mini", "cost": 2, "version": "2.4.0" },
          "peer": {
            "peer_id": 200,
            "conns": [
              { "stats": { "rx_bytes": { "unexpected": true }, "tx_bytes": "1024" } },
              { "stats": { "rx_bytes": "2048", "tx_bytes": "4096" }, "loss_rate": "0.1" }
            ]
          }
        }
      ]
    }
    """

    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    }
}

@Test func workspaceTabsExposeWorkspaceDestinations() {
    #expect(
        WorkspaceTab.allCases.map(\.rawValue)
            == ["Status", "Services", "View", "Config", "Logs", "Peers"]
    )
    #expect(
        WorkspaceTab.allCases.map(\.displayTitle)
            == ["Status", "Services", "Traffic", "Config", "Logs", "Peers"]
    )
}
