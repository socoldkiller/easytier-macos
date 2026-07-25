import EasyTierShared
import Foundation
import Observation

@MainActor
@Observable
final class HelperDiagnosticsController {
    let bundledEasyTierHelper: PrivilegedHelperBuildInfo?
    let bundledGatewayHelper: GatewayHelperBuildInfo?
    let bundledMetadataError: String?
    private(set) var activeEasyTierHelper: PrivilegedHelperBuildInfo?
    private(set) var activeGatewayHelper: GatewayHelperBuildInfo?
    private(set) var status = "Checking helpers…"

    @ObservationIgnored private let easyTierClient = PrivilegedEasyTierClient()
    @ObservationIgnored private let gatewayClient = PrivilegedGatewayClient()

    var displayedEasyTierHelper: PrivilegedHelperBuildInfo? {
        activeEasyTierHelper ?? bundledEasyTierHelper
    }

    var displayedGatewayHelper: GatewayHelperBuildInfo? {
        activeGatewayHelper ?? bundledGatewayHelper
    }

    init(bundle: Bundle = .main) {
        let metadata: (PrivilegedHelperBuildInfo?, GatewayHelperBuildInfo?, String?)
        do {
            metadata = (
                try PrivilegedHelperBuildInfo(bundle: bundle),
                try GatewayHelperBuildInfo(bundle: bundle),
                nil
            )
        } catch {
            metadata = (nil, nil, error.localizedDescription)
        }
        bundledEasyTierHelper = metadata.0
        bundledGatewayHelper = metadata.1
        bundledMetadataError = metadata.2
    }

    func refresh(
        easyTierRegistration: HelperRegistrationService?,
        gatewayRegistration: HelperRegistrationService?
    ) async {
        async let easyTierResult = loadEasyTierHelper(registration: easyTierRegistration)
        async let gatewayResult = loadGatewayHelper(registration: gatewayRegistration)
        let (easyTier, gateway) = await (easyTierResult, gatewayResult)
        activeEasyTierHelper = easyTier.info
        activeGatewayHelper = gateway.info
        let metadataStatus = bundledMetadataError.map { " Bundle metadata invalid: \($0)" } ?? ""
        status = "EasyTier: \(easyTier.status) Gateway: \(gateway.status)\(metadataStatus)"
    }

    private func loadEasyTierHelper(
        registration: HelperRegistrationService?
    ) async -> (info: PrivilegedHelperBuildInfo?, status: String) {
        guard let registration else { return (nil, "unavailable.") }
        await registration.refresh()
        guard registration.state == .enabled else { return (nil, "\(registration.detail)") }
        do {
            return (try await easyTierClient.helperBuildInfo(), "active.")
        } catch {
            return (nil, "bundled metadata shown; \(error.localizedDescription)")
        }
    }

    private func loadGatewayHelper(
        registration: HelperRegistrationService?
    ) async -> (info: GatewayHelperBuildInfo?, status: String) {
        guard let registration else { return (nil, "unavailable.") }
        await registration.refresh()
        guard registration.state == .enabled else { return (nil, "\(registration.detail)") }
        do {
            return (try await gatewayClient.helperBuildInfo(), "active.")
        } catch {
            return (nil, "bundled metadata shown; \(error.localizedDescription)")
        }
    }
}
