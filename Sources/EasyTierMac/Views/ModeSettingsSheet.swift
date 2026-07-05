import EasyTierShared
import SwiftUI

enum MagicDNSDisplay {
    static let resolverIP = "100.100.100.101"
}

enum EasyTierSettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general = "General"
    case easyTier = "EasyTier"
    case about = "About"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .easyTier: "network"
        case .about: "info.circle"
        }
    }
}

enum EasyTierSection: String, CaseIterable, Identifiable, Hashable {
    case mode = "Mode"
    case magicDNS = "Magic DNS"
    case rpcServer = "RPC Server"
    case advanced = "Advanced"
    case remoteConfig = "Remote Config"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .mode: "slider.horizontal.3"
        case .magicDNS: "globe"
        case .rpcServer: "server.rack"
        case .advanced: "doc.text"
        case .remoteConfig: "cloud"
        }
    }

    var tint: Color {
        switch self {
        case .mode: SettingsTint.mode
        case .magicDNS: SettingsTint.magicDNS
        case .rpcServer: SettingsTint.rpcServer
        case .advanced: SettingsTint.advanced
        case .remoteConfig: SettingsTint.remoteConfig
        }
    }

    var subtitle: String {
        switch self {
        case .mode: "Choose how this EasyTier instance is configured."
        case .magicDNS: "Resolve EasyTier network names through the built-in DNS."
        case .rpcServer: "Local control plane exposing EasyTier state to the GUI and peers."
        case .advanced: "Features managed through your TOML network profile."
        case .remoteConfig: "Pull the network profile from a remote server on launch."
        }
    }
}

enum SettingsSelection: Hashable {
    case general
    case easyTier(EasyTierSection)
    case about
}

struct EasyTierSettingsSheet: View {
    enum ModeKind: String, CaseIterable, Identifiable {
        case normal = "Normal"
        case remote = "Remote"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(EasyTierAppStore.self) private var store
    @Environment(AppAppearanceSettings.self) private var appearance
    @AppStorage(EasyTierSettingsTabRequest.key) private var requestedSettingsTab = EasyTierSettingsTab.general.rawValue
    @State private var loginItem = LoginItemController()
    @State private var selection: SettingsSelection
    @State private var kind: ModeKind
    @State private var rpcListenEnabled: Bool
    @State private var rpcListenPort: Int
    @State private var rpcPortalWhitelist: [String]
    @State private var configServerURL: String
    @State private var remoteRPCAddress: String
    @State private var magicDNSSuffix: String
    @State private var settingsError: String?
    @State private var showingDisableRPCListenWarning = false

    var onSave: (AppMode, MagicDNSSettings) -> Void

    init(
        initialTab: EasyTierSettingsTab = .general,
        mode: AppMode,
        magicDNSSettings: MagicDNSSettings,
        onSave: @escaping (AppMode, MagicDNSSettings) -> Void
    ) {
        self.onSave = onSave
        let requestedRaw = UserDefaults.standard.string(forKey: EasyTierSettingsTabRequest.key)
        let requestedTab = requestedRaw.flatMap(EasyTierSettingsTab.init(rawValue:)) ?? initialTab
        switch requestedTab {
        case .general: _selection = State(initialValue: .general)
        case .easyTier: _selection = State(initialValue: .easyTier(.magicDNS))
        case .about: _selection = State(initialValue: .about)
        }
        _magicDNSSuffix = State(initialValue: magicDNSSettings.dnsSuffix)

        switch mode {
        case let .normal(_, rpcListenEnabled, rpcListenPort, rpcPortalWhitelist, configServerURL):
            _kind = State(initialValue: configServerURL == nil ? .normal : .remote)
            _rpcListenEnabled = State(initialValue: rpcListenEnabled)
            _rpcListenPort = State(initialValue: rpcListenPort)
            _rpcPortalWhitelist = State(initialValue: rpcPortalWhitelist ?? AppMode.defaultRPCPortalWhitelist)
            _configServerURL = State(initialValue: configServerURL?.absoluteString ?? "")
            _remoteRPCAddress = State(initialValue: Self.defaultRemoteRPCAddress)
        case let .remote(remoteRPCAddress):
            _kind = State(initialValue: .normal)
            _rpcListenEnabled = State(initialValue: true)
            _rpcListenPort = State(initialValue: AppMode.defaultRPCListenPort)
            _rpcPortalWhitelist = State(initialValue: AppMode.defaultRPCPortalWhitelist)
            _configServerURL = State(initialValue: "")
            _remoteRPCAddress = State(initialValue: remoteRPCAddress)
        }
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $selection, visibleEasyTierSections: visibleEasyTierSections)
                .navigationSplitViewColumnWidth(min: 180, ideal: Self.sidebarWidth, max: 220)
        } detail: {
            MotionSwitch(id: selection, insertionEdge: .trailing, fillsAvailableSpace: false) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: requestedSettingsTab) { _, tab in
            selectSettingsTab(tab)
        }
        .onChange(of: selection) { _, newSelection in
            let tab: EasyTierSettingsTab
            switch newSelection {
            case .general: tab = .general
            case .easyTier: tab = .easyTier
            case .about: tab = .about
            }
            EasyTierSettingsTabRequest.set(tab)
        }
        .onChange(of: kind) { _, newKind in
            if case .easyTier(let section) = selection,
               !Self.visibleEasyTierSections(for: newKind).contains(section) {
                withAnimation(EasyTierMotion.selection(reduceMotion: reduceMotion)) {
                    selection = .easyTier(.mode)
                }
            }
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .alert("Disable TCP RPC Listen?", isPresented: $showingDisableRPCListenWarning) {
            Button("Keep Enabled", role: .cancel) {}
            Button("Disable", role: .destructive) { rpcListenEnabled = false }
        } message: {
            Text("Remote devices may not be able to fetch this EasyTier instance's current information when TCP RPC listen is off.")
        }
        .alert("Settings Error", isPresented: settingsErrorPresented) {
            Button("OK", role: .cancel) { settingsError = nil }
        } message: {
            Text(settingsError ?? "")
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .general:
            generalSettings
        case .easyTier(let section):
            easyTierSectionView(section)
        case .about:
            SettingsAboutView()
        }
    }

    // MARK: General

    private var generalSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                SectionHeader(
                    title: "General",
                    subtitle: "Appearance, launch, and quit behavior for the EasyTier GUI.",
                    systemImage: "gearshape",
                    tint: SettingsTint.launch
                )

                CardSection(
                    "Appearance",
                    systemImage: "paintbrush",
                    tint: SettingsTint.appearance,
                    footer: "Panel backgrounds apply only while frosted glass is enabled. Traditional mode keeps solid panels for readability."
                ) {
                    FieldRow("Frosted Glass") {
                        Toggle("", isOn: appearance.glassEffectsEnabledBinding).labelsHidden()
                    }
                    FieldRow("Panel Backgrounds", description: "Requires frosted glass.", help: "Requires frosted glass") {
                        Toggle("", isOn: appearance.glassPanelBackgroundsEnabledBinding).labelsHidden()
                    }
                    .disabled(!appearance.glassEffectsEnabled)
                }

                CardSection(
                    "General",
                    systemImage: "power",
                    tint: SettingsTint.launch,
                    footer: "Open EasyTier automatically when you sign in."
                ) {
                    FieldRow("Launch at Login") {
                        Toggle("", isOn: $loginItem.isEnabled).labelsHidden()
                    }
                    .onChange(of: loginItem.isEnabled) { _, _ in loginItem.apply() }
                }

                CardSection(
                    "Quit Behavior",
                    systemImage: "arrow.right.circle",
                    tint: SettingsTint.quit,
                    footer: "Only helper-backed VPN networks can keep running after the app quits. no_tun networks stop with the app."
                ) {
                    FieldRow("Keep VPN Running After Quit") {
                        Toggle("", isOn: vpnOnDemandBinding).labelsHidden()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
        .safeAreaInset(edge: .bottom) { footer }
        .task { loginItem.refresh() }
    }

    // MARK: EasyTier

    @ViewBuilder
    private func easyTierSectionView(_ section: EasyTierSection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                SectionHeader(
                    title: section.rawValue,
                    subtitle: section.subtitle,
                    systemImage: section.systemImage,
                    tint: section.tint
                )

                switch section {
                case .mode: modeSection
                case .magicDNS: magicDNSSection
                case .rpcServer: rpcServerSection
                case .advanced: advancedSection
                case .remoteConfig: remoteConfigSection
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var modeSection: some View {
        VStack(spacing: 7) {
            ModeOptionTile(
                title: "Normal",
                description: "Run a local EasyTier node with its own listeners and RPC server.",
                systemImage: "desktopcomputer",
                tint: SettingsTint.mode,
                isSelected: kind == .normal,
                action: { selectKind(.normal) }
            )
            ModeOptionTile(
                title: "Remote",
                description: "Pull the network profile from a config server on launch.",
                systemImage: "icloud.and.arrow.down",
                tint: SettingsTint.remoteConfig,
                isSelected: kind == .remote,
                action: { selectKind(.remote) }
            )
        }
    }

    private var magicDNSSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCard {
                FieldRow("DNS Suffix", description: "Resolves *.suffix through EasyTier.") {
                    TextField("", text: $magicDNSSuffix)
                        .textFieldStyle(.glassField)
                        .font(.system(size: 13.5, design: .monospaced))
                        .frame(width: 160)
                }
                FieldRow("DNS Routing") {
                    StatusText("Split DNS")
                }
                FieldRow("Resolver", description: "Built-in resolver address.") {
                    HStack(spacing: 8) {
                        CodeText(MagicDNSDisplay.resolverIP)
                        StatusDot(tone: .positive, accessibilityLabel: "Active")
                    }
                }
            }
            Text("Only names under this suffix are resolved by EasyTier. Other domains keep using system DNS. Running networks need a restart after it changes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
    }

    private var rpcServerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusBadge(
                    title: "Status",
                    value: rpcListenEnabled ? "Listening" : "Off",
                    systemImage: "dot.radiowaves.left.and.right"
                )
                StatusBadge(
                    title: "Port",
                    value: rpcListenEnabled ? "\(rpcListenPort)" : "-",
                    systemImage: "number"
                )
                StatusBadge(
                    title: "Whitelist",
                    value: "\(rpcPortalWhitelist.count)",
                    systemImage: "shield"
                )
                Spacer(minLength: 0)
            }

            SettingsCard {
                FieldRow("TCP Listen") {
                    Toggle("", isOn: rpcListenBinding).labelsHidden()
                }
                FieldRow("Portal") {
                    HStack(spacing: 8) {
                        if rpcListenEnabled {
                            CodeText("tcp://0.0.0.0:\(rpcListenPort)")
                            StatusDot(tone: .positive, accessibilityLabel: "On")
                        } else {
                            StatusPill("Off", tone: .neutral)
                        }
                    }
                }
                FieldRow("Listen Port", description: "TCP port for the RPC portal.") {
                    HStack(spacing: 8) {
                        TextField("15888", value: $rpcListenPort, format: .number)
                            .textFieldStyle(.glassField)
                            .frame(width: 96)
                        Stepper("", value: $rpcListenPort, in: 1...65_535)
                            .labelsHidden()
                    }
                    .disabled(!rpcListenEnabled)
                }
                FieldRow("Whitelist", description: "CIDRs allowed to reach the portal.") {
                    RPCPortalWhitelistEditor(values: $rpcPortalWhitelist)
                        .disabled(!rpcListenEnabled)
                }
                FieldRow("Remote RPC", description: "Address the GUI uses to reach EasyTier.") {
                    TextField(Self.defaultRemoteRPCAddress, text: $remoteRPCAddress)
                        .textFieldStyle(.glassField)
                }
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCard {
                VStack(spacing: 8) {
                    SectionIcon(systemImage: "doc.text.fill", tint: SettingsTint.advanced, size: 34)
                    Text("Configured via TOML profile")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("VPN Portal and SOCKS5 proxy are managed through your TOML network profile. They appear here once a profile enabling them is loaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            Text("Requires a config file. Configured via TOML profile.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
        }
    }

    private var remoteConfigSection: some View {
        SettingsCard {
            FieldRow("Config Server", description: "EasyTier fetches the network profile from this URL on launch.") {
                TextField("https://example.com/config", text: $configServerURL)
                    .textFieldStyle(.glassField)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            if isEasyTierActive {
                Button("Save") { saveSettings() }
                    .keyboardShortcut(.defaultAction)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(isEasyTierActive ? .cancelAction : .defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    // MARK: Bindings

    private func selectKind(_ newKind: ModeKind) {
        guard newKind != kind else { return }
        withAnimation(EasyTierMotion.selection(reduceMotion: reduceMotion)) {
            kind = newKind
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

    private var vpnOnDemandBinding: Binding<Bool> {
        Binding(
            get: { store.vpnOnDemandEnabled },
            set: { enabled in
                store.vpnOnDemandEnabled = enabled
                store.saveInBackground()
            }
        )
    }

    private var settingsErrorPresented: Binding<Bool> {
        Binding(
            get: { settingsError != nil },
            set: { isPresented in
                if !isPresented { settingsError = nil }
            }
        )
    }

    private func saveSettings() {
        do {
            let settings = try MagicDNSSettings(dnsSuffix: magicDNSSuffix)
            magicDNSSuffix = settings.dnsSuffix
            onSave(buildMode(), settings)
            dismiss()
        } catch {
            settingsError = error.localizedDescription
        }
    }

    private func buildMode() -> AppMode {
        switch kind {
        case .normal:
            .normal(
                rpcPortal: rpcListenEnabled ? "tcp://0.0.0.0:\(rpcListenPort)" : nil,
                rpcListenEnabled: rpcListenEnabled,
                rpcListenPort: rpcListenPort,
                rpcPortalWhitelist: normalizedRPCPortalWhitelist,
                configServerURL: nil
            )
        case .remote:
            .normal(
                rpcPortal: nil,
                rpcListenEnabled: false,
                rpcListenPort: AppMode.defaultRPCListenPort,
                rpcPortalWhitelist: normalizedRPCPortalWhitelist,
                configServerURL: URL(string: configServerURL.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }
    }

    private func selectSettingsTab(_ rawValue: String) {
        guard let tab = EasyTierSettingsTab(rawValue: rawValue) else { return }
        let target: SettingsSelection
        switch tab {
        case .general:
            target = .general
        case .easyTier:
            if case .easyTier(let current) = selection {
                target = .easyTier(current)
            } else {
                target = .easyTier(.magicDNS)
            }
        case .about:
            target = .about
        }
        guard target != selection else { return }
        withAnimation(EasyTierMotion.selection(reduceMotion: reduceMotion)) {
            selection = target
        }
    }

    private var isEasyTierActive: Bool {
        if case .easyTier = selection { return true }
        return false
    }

    private var visibleEasyTierSections: [EasyTierSection] {
        Self.visibleEasyTierSections(for: kind)
    }

    private static func visibleEasyTierSections(for kind: ModeKind) -> [EasyTierSection] {
        switch kind {
        case .normal: [.mode, .magicDNS, .rpcServer, .advanced]
        case .remote: [.mode, .magicDNS, .remoteConfig]
        }
    }

    private var normalizedRPCPortalWhitelist: [String]? {
        let values = rpcPortalWhitelist.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }

    private static let defaultRemoteRPCAddress = "tcp://127.0.0.1:\(AppMode.defaultRPCListenPort)"

    private static let sidebarWidth: CGFloat = 190
    private static let windowSize = CGSize(width: 640, height: 640)
}

// MARK: - About

enum EasyTierSettingsTabRequest {
    static let key = "EasyTierSettingsTab"

    static func set(_ tab: EasyTierSettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: key)
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSelection
    var visibleEasyTierSections: [EasyTierSection]
    @State private var easyTierExpanded = false

    var body: some View {
        List(selection: $selection) {
            Label("General", systemImage: "gearshape")
                .tag(SettingsSelection.general)

            DisclosureGroup(isExpanded: $easyTierExpanded) {
                ForEach(visibleEasyTierSections) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .foregroundStyle(.secondary)
                        .tag(SettingsSelection.easyTier(section))
                }
            } label: {
                Label("EasyTier", systemImage: "network")
            }

            Label("About", systemImage: "info.circle")
                .tag(SettingsSelection.about)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onAppear {
            if case .easyTier = selection { easyTierExpanded = true }
        }
        .onChange(of: selection) { _, newSelection in
            if case .easyTier = newSelection, !easyTierExpanded {
                easyTierExpanded = true
            }
        }
    }
}

private struct SettingsAboutView: View {
    @Environment(SoftwareUpdateController.self) private var updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    private let appInfo = AppVersionInfo.current
    private let revisions = SettingsSourceRevisionInfo.current

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 10) {
                    EasyTierMark()
                        .frame(width: 96, height: 96)

                    Text("EasyTier for macOS")
                        .font(.largeTitle.weight(.semibold))

                    Text("Version \(appInfo.version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Text("Native GUI for managing EasyTier networks.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 18)
                .padding(.bottom, 4)

                VStack(alignment: .leading, spacing: 14) {
                    CardSection("Version", systemImage: "info.circle", tint: SettingsTint.advanced) {
                        SettingsMetadataRow(label: "GUI", value: "\(appInfo.version) · \(revisions.guiCommit)")
                        SettingsMetadataRow(label: "Core", value: revisions.coreVersion)
                        SettingsMetadataRow(label: "Build", value: appInfo.build)
                    }

                    CardSection("Resources", systemImage: "link", tint: SettingsTint.launch) {
                        HStack(spacing: 14) {
                            Link("Docs", destination: URL(string: "https://easytier.cn")!)
                            Link("Releases", destination: URL(string: "https://github.com/socoldkiller/easytier-swift/releases")!)
                            Link("GitHub", destination: URL(string: "https://github.com/socoldkiller/easytier-swift")!)
                            Link("License", destination: URL(string: "https://github.com/socoldkiller/easytier-swift/blob/main/LICENSE")!)
                        }
                        .controlSize(.small)
                        SettingsMetadataRow(label: "License", value: "LGPL-3.0 © 2026 contributors")
                    }

                    CardSection("Software Update", systemImage: "arrow.down.circle", tint: SettingsTint.rpcServer) {
                        HStack(alignment: .center, spacing: 10) {
                            Text(updateStatusText)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            Spacer(minLength: 0)

                            updateAction
                                .controlSize(.small)
                        }

                        updateProgress
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: updateStatusText)
    }

    private var updateStatusText: String {
        switch updater.state {
        case .checking:
            "Checking stable releases…"
        case .noUpdate:
            "EasyTier is already the latest version."
        case .available(let update, _):
            "EasyTier \(update.version) is available."
        case .downloading:
            "Downloading update…"
        case .readyToInstall:
            "DMG opened. Quit before replacing EasyTier."
        case .failed, .downloadFailed, .verificationFailed:
            "Updater needs attention."
        case .idle:
            "Checks stable releases only."
        }
    }

    @ViewBuilder
    private var updateAction: some View {
        switch updater.state {
        case .checking:
            Button("Checking…") {}
                .disabled(true)
        case .available:
            Button("Download") { updater.downloadAvailableUpdate() }
        case .downloading:
            Button("Downloading…") {}
                .disabled(true)
        case .downloadFailed, .verificationFailed:
            Button("Try Again") { updater.downloadAvailableUpdate() }
        case .readyToInstall:
            Button("Quit EasyTier") { updater.quitEasyTier() }
                .keyboardShortcut(.defaultAction)
        default:
            Button("Check Now") { updater.checkForUpdates() }
        }
    }

    @ViewBuilder
    private var updateProgress: some View {
        switch updater.state {
        case .available:
            Button("Release Notes") { updater.openReleaseNotes() }
                .buttonStyle(.link)
                .font(.callout)
        case .downloading(_, let progress):
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message), .downloadFailed(_, let message), .verificationFailed(_, let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }
}

// MARK: - Reusable pieces

private struct SettingsMetadataRow: View {
    var label: String
    var value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(label)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsSourceRevisionInfo: Equatable {
    var guiCommit: String
    var coreVersion: String

    static var current: SettingsSourceRevisionInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundledGUI = normalized(info["EasyTierGUICommit"] as? String)
        let bundledCoreTag = normalized(info["EasyTierCoreTag"] as? String)
        let bundledCore = normalized(info["EasyTierCoreCommit"] as? String)

        return SettingsSourceRevisionInfo(
            guiCommit: bundledGUI ?? "unknown",
            coreVersion: bundledCoreTag ?? bundledCore ?? "unknown"
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "unknown" else { return nil }
        return value
    }
}

private struct RPCPortalWhitelistEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(values.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("10.126.126.0/24", text: Binding(
                        get: { values.indices.contains(index) ? values[index] : "" },
                        set: { newValue in
                            guard values.indices.contains(index) else { return }
                            values[index] = newValue
                        }
                    ))
                    .textFieldStyle(.glassField)
                    .font(.system(size: 13, design: .monospaced))

                    Button(role: .destructive) {
                        guard values.indices.contains(index) else { return }
                        _ = withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
                            values.remove(at: index)
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 6))
            }

            Button {
                withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
                    values.append("")
                }
            } label: {
                Label("Add CIDR", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13.5))
        }
        .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: values.count)
    }
}

private struct StatusText: View {
    var value: String

    init(_ value: String) { self.value = value }

    var body: some View {
        Text(value)
            .font(.body)
            .foregroundStyle(.secondary)
    }
}

private struct CodeText: View {
    var value: String

    init(_ value: String) { self.value = value }

    var body: some View {
        Text(value)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Appearance binding helper

private extension AppAppearanceSettings {
    var glassEffectsEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.glassEffectsEnabled },
            set: { self.glassEffectsEnabled = $0 }
        )
    }

    var glassPanelBackgroundsEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.glassPanelBackgroundsEnabled },
            set: { self.glassPanelBackgroundsEnabled = $0 }
        )
    }
}
