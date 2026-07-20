import Testing
@testable import EasyTierShared

@Test func helperBuildInfoReadsAndFormatsInjectedMetadata() {
    let info = PrivilegedHelperBuildInfo(
        infoDictionary: [
            "CFBundleShortVersionString": "1.4.0",
            "CFBundleVersion": "20260718124530",
            "EasyTierBuildTime": "2026-07-18T12:45:30Z",
            "EasyTierGUICommit": "0123456789abcdef0123456789abcdef01234567-dirty",
            "EasyTierCoreTag": "v2.4.5",
            "EasyTierCoreCommit": "fedcba9876543210fedcba9876543210fedcba98",
        ]
    )

    #expect(info.easyTierHelperDisplay == "v2.4.5 · fedcba98")
    #expect(info.binaryDisplay == "1.4.0 (20260718124530) · protocol 17")
    #expect(info.buildTime == "2026-07-18T12:45:30Z")
}

@Test func helperBuildInfoUsesDiagnosticFallbacksForLocalBuilds() {
    let info = PrivilegedHelperBuildInfo(infoDictionary: [:])

    #expect(info.version == "Development")
    #expect(info.build == "0")
    #expect(info.easyTierHelperDisplay == "unknown")
}

@Test func gatewayHelperBuildInfoUsesIndependentMetadata() {
    let info = GatewayHelperBuildInfo(
        infoDictionary: [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "20260718124530",
            "GatewayBuildTime": "2026-07-18T12:45:30Z",
            "GatewayVersion": "0.1.0",
            "GatewayCommit": "0123456789abcdef0123456789abcdef01234567-dirty",
        ]
    )

    #expect(info.componentDisplay == "0.1.0 · 01234567-dirty · schema 4")
    #expect(info.binaryDisplay == "0.1.0 (20260718124530) · protocol 5")
}
