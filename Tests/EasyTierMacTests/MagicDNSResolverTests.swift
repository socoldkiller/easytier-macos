import Testing
@testable import EasyTierMac

@Test func magicDNSAQueryUsesTheExpectedWireFormat() throws {
    let query = try #require(MagicDNSMessage.makeAQuery(hostname: "A.ET.NET.", id: 0x1234))

    #expect(query == [
        0x12, 0x34,
        0x01, 0x00,
        0x00, 0x01,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x01, 0x61,
        0x02, 0x65, 0x74,
        0x03, 0x6E, 0x65, 0x74,
        0x00,
        0x00, 0x01,
        0x00, 0x01,
    ])
}

@Test func magicDNSResponseDecodesCompressedIPv4Answers() throws {
    let query = try #require(MagicDNSMessage.makeAQuery(hostname: "a.et.net", id: 0x1234))
    var response: [UInt8] = [
        0x12, 0x34,
        0x81, 0x80,
        0x00, 0x01,
        0x00, 0x02,
        0x00, 0x00,
        0x00, 0x00,
    ]
    response.append(contentsOf: query.dropFirst(12))
    response.append(contentsOf: magicDNSARecord(address: [10, 0, 64, 7]))
    response.append(contentsOf: magicDNSARecord(address: [10, 0, 64, 8]))

    #expect(
        MagicDNSMessage.ipv4Addresses(from: response, queryID: 0x1234)
            == ["10.0.64.7", "10.0.64.8"]
    )
}

@Test func magicDNSResponseRejectsWrongQueryAndTruncatedData() throws {
    let query = try #require(MagicDNSMessage.makeAQuery(hostname: "a.et.net", id: 0x1234))
    var response: [UInt8] = [
        0x12, 0x34,
        0x81, 0x80,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x00,
        0x00, 0x00,
    ]
    response.append(contentsOf: query.dropFirst(12))
    response.append(contentsOf: magicDNSARecord(address: [10, 0, 64, 7]))

    #expect(MagicDNSMessage.ipv4Addresses(from: response, queryID: 0x4321).isEmpty)
    #expect(MagicDNSMessage.ipv4Addresses(from: Array(response.dropLast()), queryID: 0x1234).isEmpty)
}

private func magicDNSARecord(address: [UInt8]) -> [UInt8] {
    [
        0xC0, 0x0C,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x00, 0x00, 0x1E,
        0x00, 0x04,
    ] + address
}
