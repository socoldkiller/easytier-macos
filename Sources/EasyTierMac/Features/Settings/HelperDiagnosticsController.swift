import EasyTierShared
import Foundation
import Observation

@MainActor
@Observable
final class HelperDiagnosticsController {
    let bundledEasyTierHelper = PrivilegedHelperBuildInfo(bundle: .main)
    let bundledGatewayHelper = GatewayHelperBuildInfo(bundle: .main)
    private(set) var activeEasyTierHelper: PrivilegedHelperBuildInfo?
    private(set) var activeGatewayHelper: GatewayHelperBuildInfo?
    private(set) var status = "Checking helpers…"

    @ObservationIgnored private let easyTierClient = PrivilegedEasyTierClient()
    @ObservationIgnored private let gatewayClient = PrivilegedGatewayClient()

    var displayedEasyTierHelper: PrivilegedHelperBuildInfo {
        activeEasyTierHelper ?? bundledEasyTierHelper
    }

    var displayedGatewayHelper: GatewayHelperBuildInfo {
        activeGatewayHelper ?? bundledGatewayHelper
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
        status = "EasyTier: \(easyTier.status) Gateway: \(gateway.status)"
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
