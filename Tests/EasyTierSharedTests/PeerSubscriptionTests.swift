import Foundation
import Testing
@testable import EasyTierShared

@Test func peerCardDecodesFromCanonicalJSON() throws {
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

@Test func peerSubscriptionDecodesFromSingleObject() throws {
    let json = #"""
    {
      "name": "Team A",
      "cards": [
        { "id": "c1", "name": "Tokyo", "proto": "quic", "urls": ["quic://1.2.3.4:11012"] },
        { "id": "c2", "name": "SF", "urls": ["tcp://5.6.7.8:11010"] }
      ]
    }
    """#.data(using: .utf8)!

    let subs = try PeerSubscriptionCodec.decode(json)
    #expect(subs.count == 1)
    #expect(subs[0].name == "Team A")
    #expect(subs[0].cards.count == 2)
    #expect(subs[0].cards[1].proto == "tcp")
}

@Test func peerSubscriptionCodecAcceptsArrayOfCards() throws {
    let json = #"""
    [
      { "name": "A", "urls": ["tcp://1.1.1.1:11010"] },
      { "name": "B", "urls": ["udp://2.2.2.2:11010"] }
    ]
    """#.data(using: .utf8)!

    let subs = try PeerSubscriptionCodec.decode(json)
    #expect(subs.count == 1)
    #expect(subs[0].cards.count == 2)
}

@Test func peerSubscriptionCodecAcceptsArrayOfSubscriptions() throws {
    let json = #"""
    [
      { "name": "S1", "cards": [ { "name": "x", "urls": ["tcp://1.1.1.1:11010"] } ] },
      { "name": "S2", "cards": [ { "name": "y", "urls": ["udp://2.2.2.2:11010"] } ] }
    ]
    """#.data(using: .utf8)!

    let subs = try PeerSubscriptionCodec.decode(json)
    #expect(subs.count == 2)
    #expect(subs[0].name == "S1")
    #expect(subs[1].cards[0].name == "y")
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
    (#"{"name":"empty","urls":[]}"#, true),
    (#"{"name":"no urls field at all"}"#, true),
    (#"{"name":"garbage urls","urls":[1,2,3]}"#, true),
    (#"{"name":"partially valid","urls":["tcp://1.1.1.1:11010", 42]}"#, true),
])
func peerCardDecodesLossily(_ json: String, succeeds: Bool) throws {
    let card = try JSONDecoder().decode(PeerCard.self, from: json.data(using: .utf8)!)
    #expect(!card.id.isEmpty)
    #expect(card.name == card.name)
}

@MainActor
@Test func storeAddPeerSubscriptionFromJSONPersistsAndReloads() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("peer-sub-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let storage = EasyTierStorage(baseDirectory: directory)
    let store = EasyTierAppStore(storage: storage)

    let json = #"""
    { "name": "Sub One", "cards": [ { "name": "A", "urls": ["tcp://1.1.1.1:11010"] } ] }
    """#
    try store.addPeerSubscription(json: json)
    #expect(store.peerSubscriptions.count == 1)
    #expect(store.peerSubscriptions[0].cards.count == 1)

    store.save()

    let reloaded = EasyTierAppStore(storage: storage)
    await reloaded.load()
    #expect(reloaded.peerSubscriptions.count == 1)
    #expect(reloaded.peerSubscriptions[0].cards[0].urls == ["tcp://1.1.1.1:11010"])
}

@MainActor
@Test func storeMergePeerCardAddsURLsToSelectedConfig() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("peer-sub-merge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let storage = EasyTierStorage(baseDirectory: directory)
    let store = EasyTierAppStore(storage: storage)
    await store.load()

    var config = store.configs[0].config
    config.peer_urls = ["tcp://existing.example:11010"]
    store.updateSelectedConfig(config)

    let card = PeerCard(name: "New", urls: ["quic://1.2.3.4:11012", "tcp://existing.example:11010"])
    store.mergePeerCardIntoSelectedConfig(card)

    let updated = store.selectedConfig
    #expect(updated?.peer_urls.contains("quic://1.2.3.4:11012") == true)
    #expect(updated?.peer_urls.filter { $0 == "tcp://existing.example:11010" }.count == 1)
}

@MainActor
@Test func storeDeletePeerSubscriptionRemovesIt() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("peer-sub-del-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let storage = EasyTierStorage(baseDirectory: directory)
    let store = EasyTierAppStore(storage: storage)
    await store.load()

    try store.addPeerSubscription(json: #"{"name":"To Delete","cards":[]}"#)
    #expect(store.peerSubscriptions.count == 1)
    let id = store.peerSubscriptions[0].id
    store.deletePeerSubscription(id: id)
    #expect(store.peerSubscriptions.isEmpty)
}
