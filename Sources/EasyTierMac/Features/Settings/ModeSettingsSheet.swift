import EasyTierShared
import SwiftUI

enum MagicDNSDisplay {
    static let resolverIP = MagicDNSSystemResolverConfigurator.resolverIP

    static func memberDomain(
        hostname: String,
        config: NetworkConfig?,
        settings: MagicDNSSettings
    ) -> String? {
        guard config?.enable_magic_dns == true else { return nil }
        let hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty, hostname != "-" else { return nil }
        let suffix = settings.dnsSuffix
        let strippedSuffix = suffix.hasSuffix(".") ? String(suffix.dropLast()) : suffix
        return "\(hostname).\(strippedSuffix)"
    }
}

enum EasyTierSettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general = "General"
    // Keep the legacy raw value so existing installations restore this pane.
    case network = "EasyTier"
    case gateway = "Gateway"
    case advanced = "Advanced"
    case about = "About"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .network: "Network"
        case .gateway: "Gateway"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .network: "globe"
        case .gateway: "network.badge.shield.half.filled"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}

struct EasyTierSettingsSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppContext.self) private var appContext

    private let onChange: (AppMode, MagicDNSSettings) -> Void

    @State private var selection: EasyTierSettingsTab
    @State private var rpcListenEnabled: Bool
    @State private var rpcListenPort: Int
    @State private var rpcPortalWhitelist: [String]
    @State private var magicDNSSuffix: String
    @State private var committedMagicDNSSettings: MagicDNSSettings
    @State private var showingDisableRPCListenWarning = false

    init(
        initialTab: EasyTierSettingsTab = .general,
        mode: AppMode,
        magicDNSSettings: MagicDNSSettings,
        onChange: @escaping (AppMode, MagicDNSSettings) -> Void
    ) {
        self.onChange = onChange
        _selection = State(initialValue: initialTab)
        _rpcListenEnabled = State(initialValue: mode.rpcListenEnabled)
        _rpcListenPort = State(initialValue: mode.rpcListenPort)
        _rpcPortalWhitelist = State(
            initialValue: Self.initialRPCPortalWhitelist(from: mode.rpcPortalWhitelist)
        )
        _magicDNSSuffix = State(initialValue: magicDNSSettings.dnsSuffix)
        _committedMagicDNSSettings = State(initialValue: magicDNSSettings)
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(
                EasyTierSettingsTab.general.title,
                systemImage: EasyTierSettingsTab.general.systemImage,
                value: EasyTierSettingsTab.general
            ) {
                GeneralSettingsView()
            }

            Tab(
                EasyTierSettingsTab.network.title,
                systemImage: EasyTierSettingsTab.network.systemImage,
                value: EasyTierSettingsTab.network
            ) {
                NetworkSettingsView(
                    dnsSuffix: $magicDNSSuffix,
                    managedDNSSuffix: appContext.runtime.gateway.defaultDNSZoneBinding?.dnsSuffix,
                    commit: commitMagicDNSSettings
                )
            }

            Tab(
                EasyTierSettingsTab.gateway.title,
                systemImage: EasyTierSettingsTab.gateway.systemImage,
                value: EasyTierSettingsTab.gateway
            ) {
                GatewaySettingsView()
            }

            Tab(
                EasyTierSettingsTab.advanced.title,
                systemImage: EasyTierSettingsTab.advanced.systemImage,
                value: EasyTierSettingsTab.advanced
            ) {
                AdvancedSettingsView(
                    rpcListenEnabled: rpcListenBinding,
                    rpcListenPort: $rpcListenPort,
                    rpcPortalWhitelist: $rpcPortalWhitelist,
                    commit: applyModeSettings
                )
            }

            Tab(
                EasyTierSettingsTab.about.title,
                systemImage: EasyTierSettingsTab.about.systemImage,
                value: EasyTierSettingsTab.about
            ) {
                EasyTierAboutView()
            }
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 520, idealHeight: 560)
        .onChange(of: appContext.settings.requestedTab) { _, tab in
            selectSettingsTab(tab)
        }
        .onChange(of: selection) { _, newSelection in
            appContext.settings.request(newSelection)
        }
        .onChange(of: rpcListenEnabled) { _, _ in
            applyModeSettings()
        }
        .onChange(of: appContext.workspace.store.magicDNSSettings) { _, settings in
            magicDNSSuffix = settings.dnsSuffix
            committedMagicDNSSettings = settings
        }
        .hideScrollViewScrollers()
        .alert("Disable TCP RPC Listen?", isPresented: $showingDisableRPCListenWarning) {
            Button("Keep Enabled", role: .cancel) {}
            Button("Disable", role: .destructive) {
                rpcListenEnabled = false
            }
        } message: {
            Text("Remote devices may not be able to fetch this EasyTier instance's current information when TCP RPC listen is off.")
        }
    }

    private var rpcListenBinding: Binding<Bool> {
        Binding(
            get: { rpcListenEnabled },
            set: { newValue in
                if newValue {
                    rpcListenEnabled = true
                } else if rpcListenEnabled {
                    showingDisableRPCListenWarning = true
                }
            }
        )
    }

    private var normalizedRPCPortalWhitelist: [String]? {
        let values = rpcPortalWhitelist
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }

    private func applyModeSettings() {
        onChange(buildMode(), committedMagicDNSSettings)
    }

    private func commitMagicDNSSettings(_ settings: MagicDNSSettings) {
        committedMagicDNSSettings = settings
        onChange(buildMode(), settings)
    }

    private func buildMode() -> AppMode {
        AppMode(
            rpcListenEnabled: rpcListenEnabled,
            rpcListenPort: rpcListenPort,
            rpcPortalWhitelist: normalizedRPCPortalWhitelist
        )
    }

    private func selectSettingsTab(_ tab: EasyTierSettingsTab) {
        guard tab != selection else { return }
        withAnimation(EasyTierMotion.selection(reduceMotion: reduceMotion)) {
            selection = tab
        }
    }

    private static func initialRPCPortalWhitelist(from whitelist: [String]?) -> [String] {
        let values = (whitelist ?? AppMode.defaultRPCPortalWhitelist)
            .flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let legacyDefaults = Set(["127.0.0.0/8", "::1/128", "10.126.126.0/24"])
        return values.isEmpty || Set(values).isSubset(of: legacyDefaults)
            ? AppMode.defaultRPCPortalWhitelist
            : values
    }
}
