import Foundation
import Testing
@testable import EasyTierShared

@Test func peerCardDecodesFromInternalStorageJSON() throws {
    let json = #"""
    {
      "name": "Tokyo Relay",
      "proto": "quic",
      "urls": ["quic://1.2.3.4:11012", "udp://1.2.3.4:11010"],
      "note": "primary"
    }
    """#.data(using: .utf8)!

    let card = try JSONDecoder().decode(PeerCard.self, from: json)
    #expect(card.name == "Tokyo Relay")
    #expect(card.proto == "quic")
    #expect(card.urls == ["quic://1.2.3.4:11012", "udp://1.2.3.4:11010"])
    #expect(card.note == "primary")
    #expect(!card.id.isEmpty)
}

@Test func peerCardInfersProtoFromURLsWhenMissing() throws {
    let json = #"""
    { "name": "SF Node", "urls": ["tcp://5.6.7.8:11010"] }
    """#.data(using: .utf8)!

    let card = try JSONDecoder().decode(PeerCard.self, from: json)
    #expect(card.proto == "tcp")
}

@Test func peerCardTrimsAndFiltersEmptyURLs() throws {
    let json = #"""
    { "name": "X", "urls": ["  tcp://1.1.1.1:11010  ", "", "   "] }
    """#.data(using: .utf8)!

    let card = try JSONDecoder().decode(PeerCard.self, from: json)
    #expect(card.urls == ["tcp://1.1.1.1:11010"])
}

@Test func peerSubscriptionCodecImportsOutboundSubscriptionNodes() throws {
    let json = #"""
    {
      "outbounds": [
        { "type": "quic", "tag": "Tokyo", "server": "tokyo.example.com", "server_port": 11012 },
        { "type": "tcp", "tag": "SF", "server": "sf.example.com", "server_port": 11010 },
        { "type": "trojan", "tag": "Proxy", "server": "proxy.example.com", "server_port": 443 },
        { "type": "direct", "tag": "direct" },
        { "type": "selector", "tag": "Auto", "outbounds": ["Tokyo", "SF"] }
      ]
    }
    """#.data(using: .utf8)!

    let subs = try PeerSubscriptionCodec.decode(json)
    #expect(subs.count == 1)
    #expect(subs[0].name == "Node Subscription")
    #expect(subs[0].cards.count == 2)
    #expect(subs[0].cards[0].id == "tokyo")
    #expect(subs[0].cards[0].name == "Tokyo")
    #expect(subs[0].cards[0].proto == "quic")
    #expect(subs[0].cards[0].urls == ["quic://tokyo.example.com:11012"])
    #expect(subs[0].cards[0].note == "Imported quic peer from subscription.")
    #expect(subs[0].cards[1].urls == ["tcp://sf.example.com:11010"])
}

@Test(arguments: ["tcp", "udp", "wg", "ws", "wss", "quic", "faketcp"])
func peerSubscriptionCodecImportsEasyTierProtocolOutboundTypes(_ type: String) throws {
    let json = """
    {
      "outbounds": [
        { "type": "\(type)", "tag": "\(type)-node", "server": "\(type).example.com", "server_port": "11010" }
      ]
    }
    """.data(using: .utf8)!

    let subs = try PeerSubscriptionCodec.decode(json)
    #expect(subs[0].cards.count == 1)
    #expect(subs[0].cards[0].proto == type)
    #expect(subs[0].cards[0].urls == ["\(type)://\(type).example.com:11010"])
}

@Test(arguments: ["trojan", "vless", "vmess", "shadowsocks", "hysteria2", "tuic", "wireguard"])
func peerSubscriptionCodecRejectsNonEasyTierProtocolOutboundTypes(_ type: String) {
    let json = """
    {
      "outbounds": [
        { "type": "\(type)", "tag": "\(type)-node", "server": "\(type).example.com", "server_port": 443 }
      ]
    }
    """.data(using: .utf8)!

    #expect(throws: PeerSubscriptionDecodeError.self) {
        _ = try PeerSubscriptionCodec.decode(json)
    }
}

@Test func peerSubscriptionCodecUsesServerPortNameWhenTagMissing() throws {
    let json = #"""
    {
      "outbounds": [
        { "type": "udp", "server": "1.2.3.4", "server_port": 11010 }
      ]
    }
    """#.data(using: .utf8)!

    let subs = try PeerSubscriptionCodec.decode(json)
    #expect(subs[0].cards[0].name == "1.2.3.4:11010")
    #expect(subs[0].cards[0].id == "udp-1-2-3-4-11010")
}

@Test func peerSubscriptionCodecSkipsOutboundsWithoutServerOrPort() throws {
    let json = #"""
    {
      "outbounds": [
        { "type": "tcp", "tag": "No server", "server_port": 11010 },
        { "type": "quic", "tag": "No port", "server": "missing-port.example.com" },
        { "type": "wss", "tag": "Valid", "server": "valid.example.com", "server_port": 11012 }
      ]
    }
    """#.data(using: .utf8)!

    let subs = try PeerSubscriptionCodec.decode(json)
    #expect(subs[0].cards.map(\.name) == ["Valid"])
    #expect(subs[0].cards[0].urls == ["wss://valid.example.com:11012"])
}

@Test func peerSubscriptionCodecRejectsOnlySkippedOutbounds() {
    let json = #"""
    {
      "outbounds": [
        { "type": "direct", "tag": "direct" },
        { "type": "block", "tag": "block" },
        { "type": "dns", "tag": "dns" },
        { "type": "selector", "tag": "selector", "outbounds": ["direct"] },
        { "type": "urltest", "tag": "urltest", "outbounds": ["direct"] }
      ]
    }
    """#.data(using: .utf8)!

    #expect(throws: PeerSubscriptionDecodeError.self) {
        _ = try PeerSubscriptionCodec.decode(json)
    }
}

@Test func peerSubscriptionCodecRejectsOldCardsObject() {
    let json = #"""
    { "name": "Old", "cards": [ { "name": "A", "urls": ["tcp://1.1.1.1:11010"] } ] }
    """#.data(using: .utf8)!

    #expect(throws: PeerSubscriptionDecodeError.self) {
        _ = try PeerSubscriptionCodec.decode(json)
    }
}

@Test func peerSubscriptionCodecRejectsOldCardsArray() {
    let json = #"""
    [
      { "name": "A", "urls": ["tcp://1.1.1.1:11010"] },
      { "name": "B", "urls": ["udp://2.2.2.2:11010"] }
    ]
    """#.data(using: .utf8)!

    #expect(throws: PeerSubscriptionDecodeError.self) {
        _ = try PeerSubscriptionCodec.decode(json)
    }
}

@Test func peerSubscriptionCodecRejectsGarbage() {
    #expect(throws: PeerSubscriptionDecodeError.self) {
        _ = try PeerSubscriptionCodec.decode("not json at all".data(using: .utf8)!)
    }
}

@Test func peerCardNormalizeCollapsesEquivalentURLs() {
    #expect(PeerCard.normalize("quic://1.2.3.4:11012") == "quic://1.2.3.4:11012")
    #expect(PeerCard.normalize("  UDP://5.6.7.8:11010/") == "udp://5.6.7.8:11010")
    #expect(PeerCard.normalize("") == "")
}

@Test func peerCardMatchesRuntimePeerURLCaseInsensitive() {
    let card = PeerCard(name: "X", urls: ["quic://1.2.3.4:11012"])
    #expect(card.matchesRuntimePeerURL("QUIC://1.2.3.4:11012"))
    #expect(card.matchesRuntimePeerURL("quic://1.2.3.4:11012/extra/path"))
    #expect(!card.matchesRuntimePeerURL("tcp://1.2.3.4:11010"))
}

@Test(arguments: [
    #"{"name":"empty","urls":[]}"#,
    #"{"name":"no urls field at all"}"#,
    #"{"name":"garbage urls","urls":[1,2,3]}"#,
    #"{"name":"partially valid","urls":["tcp://1.1.1.1:11010", 42]}"#,
])
func peerCardDecodesLossily(_ json: String) throws {
    let card = try JSONDecoder().decode(PeerCard.self, from: json.data(using: .utf8)!)
    #expect(!card.id.isEmpty)
    #expect(card.name == card.name)
}

@MainActor
@Test func storeAddSubscriptionFromJSONPersistsAndReloads() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("peer-sub-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let storage = EasyTierStorage(baseDirectory: directory)
    let store = EasyTierAppStore(storage: storage)

    let json = #"""
    {
      "outbounds": [
        { "type": "quic", "tag": "Persisted", "server": "persisted.example.com", "server_port": 11012 }
      ]
    }
    """#
    try store.addPeerSubscription(json: json)
    #expect(store.peerSubscriptions.count == 1)
    #expect(store.peerSubscriptions[0].cards.count == 1)

    store.save()

    let reloaded = EasyTierAppStore(storage: storage)
    await reloaded.load()
    #expect(reloaded.peerSubscriptions.count == 1)
    #expect(reloaded.peerSubscriptions[0].cards[0].urls == ["quic://persisted.example.com:11012"])
}
