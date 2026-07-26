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
    case account = "Account"
    case general = "General"
    case network = "Network"
    case advanced = "Advanced"
    case about = "About"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: "Accounts"
        case .general: "General"
        case .network: "Network"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .account: "person.crop.circle"
        case .general: "gearshape"
        case .network: "globe"
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
    @State private var tabTransitionEdge: Edge = .trailing

    private static let tabTransitionDistance: CGFloat = 14

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
        ZStack {
            TabView(selection: selectionBinding) {
                Tab(
                    EasyTierSettingsTab.account.title,
                    systemImage: EasyTierSettingsTab.account.systemImage,
                    value: EasyTierSettingsTab.account
                ) {
                    Color.clear
                        .accessibilityHidden(true)
                }

                Tab(
                    EasyTierSettingsTab.general.title,
                    systemImage: EasyTierSettingsTab.general.systemImage,
                    value: EasyTierSettingsTab.general
                ) {
                    Color.clear
                        .accessibilityHidden(true)
                }

                Tab(
                    EasyTierSettingsTab.network.title,
                    systemImage: EasyTierSettingsTab.network.systemImage,
                    value: EasyTierSettingsTab.network
                ) {
                    Color.clear
                        .accessibilityHidden(true)
                }

                Tab(
                    EasyTierSettingsTab.advanced.title,
                    systemImage: EasyTierSettingsTab.advanced.systemImage,
                    value: EasyTierSettingsTab.advanced
                ) {
                    Color.clear
                        .accessibilityHidden(true)
                }

                Tab(
                    EasyTierSettingsTab.about.title,
                    systemImage: EasyTierSettingsTab.about.systemImage,
                    value: EasyTierSettingsTab.about
                ) {
                    Color.clear
                        .accessibilityHidden(true)
                }
            }

            MotionSwitch(
                id: selection,
                insertionEdge: tabTransitionEdge,
                distance: Self.tabTransitionDistance
            ) {
                SettingsTabContent(
                    selection: selection,
                    rpcListenEnabled: rpcListenBinding,
                    rpcListenPort: $rpcListenPort,
                    rpcPortalWhitelist: $rpcPortalWhitelist,
                    magicDNSSuffix: $magicDNSSuffix,
                    commitModeSettings: applyModeSettings,
                    commitMagicDNSSettings: commitMagicDNSSettings
                )
            }
        }
        .frame(width: 612, height: 504)
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

    private var selectionBinding: Binding<EasyTierSettingsTab> {
        Binding(
            get: { selection },
            set: { newSelection in
                selectSettingsTab(newSelection)
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
        guard appContext.workspace.store.persistenceIsReady else { return }
        onChange(buildMode(), committedMagicDNSSettings)
    }

    private func commitMagicDNSSettings(_ settings: MagicDNSSettings) {
        guard appContext.workspace.store.persistenceIsReady else { return }
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
        tabTransitionEdge = tabIndex(tab) > tabIndex(selection) ? .trailing : .leading
        withAnimation(EasyTierMotion.selection(reduceMotion: reduceMotion)) {
            selection = tab
        }
    }

    private func tabIndex(_ tab: EasyTierSettingsTab) -> Int {
        EasyTierSettingsTab.allCases.firstIndex(of: tab) ?? 0
    }

    private static func initialRPCPortalWhitelist(from whitelist: [String]?) -> [String] {
        let values = (whitelist ?? AppMode.defaultRPCPortalWhitelist)
            .flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? AppMode.defaultRPCPortalWhitelist : values
    }
}
