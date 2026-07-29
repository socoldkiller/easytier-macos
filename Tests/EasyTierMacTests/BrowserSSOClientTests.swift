@testable import EasyTierMac
import Foundation
import Testing

@Test func controlServerOriginRequiresAPureHTTPSOrigin() throws {
    #expect(try ControlServerOrigin("https://IW.Example.com/").url.absoluteString == "https://iw.example.com")
    #expect(throws: BrowserSSOError.invalidServerAddress) {
        try ControlServerOrigin("https://user@iw.example.com")
    }
    #expect(throws: BrowserSSOError.invalidServerAddress) {
        try ControlServerOrigin("https://iw.example.com/custom")
    }
    #expect(throws: BrowserSSOError.invalidServerAddress) {
        try ControlServerOrigin("http://iw.example.com", allowsInsecureLocalhost: true)
    }
    #expect(try ControlServerOrigin("http://127.0.0.1:8080", allowsInsecureLocalhost: true).url.port == 8080)
}

@Test func bootstrapAcceptsOnlyVersionOneSameOriginPathsAndTCP() throws {
    let origin = try ControlServerOrigin("https://iw.example.com")
    let valid = EasyTierClientBootstrap(
        protocolVersion: 1,
        configEndpoint: "tcp://config.example.com:22020",
        loginPath: "/#/auth",
        consolePath: "/#/console"
    )
    let result = try valid.validate(for: origin)
    #expect(result.consoleURL.absoluteString == "https://iw.example.com/#/console")

    #expect(throws: BrowserSSOError.unsupportedProtocolVersion) {
        try EasyTierClientBootstrap(
            protocolVersion: 2,
            configEndpoint: valid.configEndpoint,
            loginPath: valid.loginPath,
            consolePath: valid.consolePath
        ).validate(for: origin)
    }
    #expect(throws: BrowserSSOError.invalidBootstrap) {
        try EasyTierClientBootstrap(
            protocolVersion: 1,
            configEndpoint: "wss://config.example.com:443",
            loginPath: valid.loginPath,
            consolePath: valid.consolePath
        ).validate(for: origin)
    }
    #expect(throws: BrowserSSOError.invalidBootstrap) {
        try EasyTierClientBootstrap(
            protocolVersion: 1,
            configEndpoint: valid.configEndpoint,
            loginPath: "https://evil.example/auth",
            consolePath: valid.consolePath
        ).validate(for: origin)
    }
}

@Test func loopbackCallbackRequiresExactPathStateAndSingleTicket() {
    let request = Data("GET /easytier/callback?state=abc&ticket=etn1.ticket HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
    #expect(LoopbackSSOCallbackServer.ticket(from: request, expectedState: "abc") == "etn1.ticket")
    #expect(LoopbackSSOCallbackServer.ticket(from: request, expectedState: "wrong") == nil)

    let duplicate = Data("GET /easytier/callback?state=abc&ticket=one&ticket=two HTTP/1.1\r\n\r\n".utf8)
    #expect(LoopbackSSOCallbackServer.ticket(from: duplicate, expectedState: "abc") == nil)
}

@Test func nativeStateContainsThirtyTwoRandomBytes() throws {
    let state = try NativeSSOSecureRandom.state()
    let base64 = state.replacing("-", with: "+").replacing("_", with: "/")
    let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
    #expect(Data(base64Encoded: base64 + padding)?.count == 32)
}
