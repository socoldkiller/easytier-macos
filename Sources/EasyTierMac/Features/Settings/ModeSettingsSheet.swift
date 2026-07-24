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

private enum SettingsTextField: Hashable {
    case magicDNSSuffix
    case rpcListenPort
}

struct EasyTierSettingsSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppContext.self) private var appContext
    @State private var selection: EasyTierSettingsTab
    @State private var rpcListenEnabled: Bool
    @State private var rpcListenPort: Int
    @State private var rpcPortalWhitelist: [String]
    @State private var magicDNSSuffix: String
    @State private var settingsError: String?
    @State private var showingDisableRPCListenWarning = false
    @FocusState private var focusedTextField: SettingsTextField?
    private let appInfo = AppVersionInfo.current

    var onChange: (AppMode, MagicDNSSettings) -> Void

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var appearance: AppAppearanceSettings { appContext.settings.appearance }
    private var updater: SoftwareUpdateController { appContext.softwareUpdate.controller }
    private var loginItem: LoginItemController { appContext.settings.loginItem }

    init(
        initialTab: EasyTierSettingsTab = .general,
        mode: AppMode,
        magicDNSSettings: MagicDNSSettings,
        onChange: @escaping (AppMode, MagicDNSSettings) -> Void
    ) {
        self.onChange = onChange
        _selection = State(initialValue: initialTab)
        _magicDNSSuffix = State(initialValue: magicDNSSettings.dnsSuffix)

        _rpcListenEnabled = State(initialValue: mode.rpcListenEnabled)
        _rpcListenPort = State(initialValue: mode.rpcListenPort)
        _rpcPortalWhitelist = State(initialValue: Self.initialRPCPortalWhitelist(from: mode.rpcPortalWhitelist))
    }

    var body: some View {
        TabView(selection: $selection) {
            generalSettings
                .tabItem { Label(EasyTierSettingsTab.general.title, systemImage: EasyTierSettingsTab.general.systemImage) }
                .tag(EasyTierSettingsTab.general)

            networkSettings
                .tabItem { Label(EasyTierSettingsTab.network.title, systemImage: EasyTierSettingsTab.network.systemImage) }
                .tag(EasyTierSettingsTab.network)

            GatewaySettingsView()
                .tabItem { Label(EasyTierSettingsTab.gateway.title, systemImage: EasyTierSettingsTab.gateway.systemImage) }
                .tag(EasyTierSettingsTab.gateway)

            advancedSettings
                .tabItem { Label(EasyTierSettingsTab.advanced.title, systemImage: EasyTierSettingsTab.advanced.systemImage) }
                .tag(EasyTierSettingsTab.advanced)

            SettingsAboutView()
                .tabItem { Label(EasyTierSettingsTab.about.title, systemImage: EasyTierSettingsTab.about.systemImage) }
                .tag(EasyTierSettingsTab.about)
        }
        .frame(width: 680, height: 560)
        .onChange(of: appContext.settings.requestedTab) { _, tab in
            selectSettingsTab(tab)
        }
        .onChange(of: selection) { _, newSelection in
            appContext.settings.request(newSelection)
        }
        .onChange(of: rpcListenEnabled) { _, _ in
            applySettings()
        }
        .onChange(of: focusedTextField) { oldValue, newValue in
            guard oldValue != nil, oldValue != newValue else { return }
            applySettings()
        }
        .hideScrollViewScrollers()
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

    // MARK: General

    private var generalSettings: some View {
        settingsForm {
            Section {
                settingsSwitch("Use Frosted Glass", isOn: appearance.glassEffectsEnabledBinding)
                settingsSwitch("Show EasyTier in Dock", isOn: appearance.showsDockIconBinding)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Frosted Glass is an optional preview appearance. EasyTier always respects Reduce Transparency.")
            }

            Section {
                settingsSwitch("Launch at Login", isOn: loginItemBinding)
                    .onChange(of: loginItem.isEnabled) { _, _ in loginItem.apply() }
                settingsSwitch("Keep Networks Running After Quit", isOn: vpnOnDemandBinding)
            } header: {
                Text("Startup & Background")
            } footer: {
                Text("Helper-managed networks can continue running after the EasyTier app quits.")
            }

            Section {
                settingsSwitch("Check for Updates Automatically", isOn: autoCheckUpdatesBinding)
                LabeledContent("Update Channel") {
                    Picker("Update Channel", selection: updateTrackBinding) {
                        ForEach(SoftwareUpdateTrack.allCases) { track in
                            Text(track.displayName).tag(track)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                    .disabled(updater.sessionInProgress)
                }
                LabeledContent("Updates") {
                    Button("Check for Updates…", action: performUpdateAction)
                        .controlSize(.small)
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                Text("Software Update")
            } footer: {
                Text(softwareUpdateFooterText)
            }
        }
        .task {
            await Task.yield()
            loginItem.refresh()
        }
    }

    // MARK: Network

    private var networkSettings: some View {
        settingsForm {
            Section {
                LabeledContent("DNS Suffix") {
                    TextField("et.net.", text: $magicDNSSuffix)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(width: 180)
                        .focused($focusedTextField, equals: .magicDNSSuffix)
                        .onSubmit { focusedTextField = nil }
                }
                LabeledContent("DNS Routing", value: "Split DNS")
            } header: {
                Text("Magic DNS")
            } footer: {
                Text("Only names under this suffix are resolved by EasyTier. Running networks need a restart after the suffix changes.")
            }
        }
    }

    // MARK: Advanced

    private var advancedSettings: some View {
        settingsForm {
            Section {
                settingsSwitch("Allow TCP RPC Connections", isOn: rpcListenBinding)

                if rpcListenEnabled {
                    LabeledContent("Portal") {
                        Text(verbatim: "tcp://0.0.0.0:\(rpcListenPort)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Listen Port") {
                        HStack(spacing: 8) {
                            TextField("Port", text: integerText($rpcListenPort))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                .frame(width: 96)
                                .focused($focusedTextField, equals: .rpcListenPort)
                                .onSubmit { focusedTextField = nil }
                            Stepper("Listen Port", value: rpcListenPortStepperBinding, in: 1...65_535)
                                .labelsHidden()
                        }
                    }
                    LabeledContent("Whitelist") {
                        RPCPortalWhitelistEditor(values: $rpcPortalWhitelist) {
                            applySettings()
                        }
                        .frame(maxWidth: 360, alignment: .leading)
                    }
                }
            } header: {
                Text("RPC Server")
            } footer: {
                Text("Enable this only when remote EasyTier clients need to access this Mac's control plane.")
            }

            Section {
                settingsSwitch(
                    "Use Backgrounds Behind Panels",
                    isOn: appearance.glassPanelBackgroundsEnabledBinding
                )
                .disabled(!appearance.glassEffectsEnabled)
            } header: {
                Text("Experimental Appearance")
            } footer: {
                Text("Panel backgrounds require Frosted Glass and may change as the appearance evolves.")
            }

            HelperDiagnosticsSection()
        }
    }

    private func settingsForm<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden, axes: .vertical)
            .hideScrollViewScrollers()
    }

    private func settingsSwitch(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
    }

    // MARK: Bindings

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.isEnabled = $0 }
        )
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

    private var rpcListenPortStepperBinding: Binding<Int> {
        Binding(
            get: { rpcListenPort },
            set: { newValue in
                rpcListenPort = newValue
                applySettings()
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

    private var autoCheckUpdatesBinding: Binding<Bool> {
        Binding {
            updater.automaticallyChecksForUpdates
        } set: { isEnabled in
            updater.automaticallyChecksForUpdates = isEnabled
        }
    }

    private var updateTrackBinding: Binding<SoftwareUpdateTrack> {
        Binding {
            updater.updateTrack
        } set: { track in
            updater.updateTrack = track
        }
    }

    private var softwareUpdateFooterText: String {
        if updater.updateTrack == .nightly {
            return "Built nightly from the latest EasyTier GUI and Core. Nightly builds may be unstable."
        }
        if appInfo.buildChannel == .nightly {
            return "Stable updates are selected. This Nightly build remains installed until a newer Stable release is available."
        }
        return "EasyTier checks signed Stable releases at most once every 24 hours."
    }

    private func performUpdateAction() {
        updater.checkForUpdates()
    }

    private var settingsErrorPresented: Binding<Bool> {
        Binding(
            get: { settingsError != nil },
            set: { isPresented in
                if !isPresented { settingsError = nil }
            }
        )
    }

    private func applySettings(surfacesValidationError: Bool = true) {
        do {
            let settings = try MagicDNSSettings(dnsSuffix: magicDNSSuffix)
            settingsError = nil
            onChange(buildMode(), settings)
        } catch {
            settingsError = surfacesValidationError ? error.localizedDescription : nil
        }
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

    private var normalizedRPCPortalWhitelist: [String]? {
        let values = rpcPortalWhitelist.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }

    private static func initialRPCPortalWhitelist(from whitelist: [String]?) -> [String] {
        let values = (whitelist ?? AppMode.defaultRPCPortalWhitelist)
            .flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let legacyDefaults = Set(["127.0.0.0/8", "::1/128", "10.126.126.0/24"])
        return values.isEmpty || Set(values).isSubset(of: legacyDefaults) ? AppMode.defaultRPCPortalWhitelist : values
    }

}

private struct SettingsAboutView: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let appInfo = AppVersionInfo.current
    private let revisions = SettingsSourceRevisionInfo.current

    private var updater: SoftwareUpdateController { appContext.softwareUpdate.controller }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 7) {
                EasyTierMark()
                    .frame(width: 72, height: 72)

                Text("EasyTier for macOS")
                    .font(.title2.weight(.semibold))

                Text("Version \(appInfo.displayVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text("Native GUI for managing EasyTier networks.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)

            Form {
                Section("Software Update") {
                    HStack(spacing: 12) {
                        Text(updateSummaryText)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Check for Updates…", action: performUpdateAction)
                            .controlSize(.small)
                            .disabled(!updater.canCheckForUpdates)
                    }
                    LabeledContent("Update Channel", value: updater.updateTrack.displayName)
                    if let lastCheck = updater.lastUpdateCheckDate {
                        LabeledContent("Last Check", value: lastCheck.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                Section("Version") {
                    SettingsMetadataRow(label: "GUI", value: "\(appInfo.version) · \(revisions.guiCommit)")
                    SettingsMetadataRow(label: "Core", value: revisions.coreVersion)
                    SettingsMetadataRow(label: "Build Channel", value: appInfo.buildChannel.buildDisplayName)
                    SettingsMetadataRow(label: "Build", value: appInfo.build)
                }

                Section("Resources") {
                    HStack(spacing: 14) {
                        Link("Docs", destination: URL(string: "https://easytier.cn") ?? URL(fileURLWithPath: "/"))
                        Link("Releases", destination: URL(string: "https://github.com/socoldkiller/easytier-macos/releases") ?? URL(fileURLWithPath: "/"))
                        Link("GitHub", destination: URL(string: "https://github.com/socoldkiller/easytier-macos") ?? URL(fileURLWithPath: "/"))
                        Link("License", destination: URL(string: "https://github.com/socoldkiller/easytier-macos/blob/main/LICENSE") ?? URL(fileURLWithPath: "/"))
                    }
                    .controlSize(.small)
                    SettingsMetadataRow(label: "License", value: "MIT © 2026 contributors")
                }

            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden, axes: .vertical)
            .hideScrollViewScrollers()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: updateSummaryText)
    }

    private var updateSummaryText: String {
        if updater.sessionInProgress { return "Software update is in progress…" }
        if appInfo.buildChannel == .nightly, updater.updateTrack == .stable {
            return "Stable updates selected; this Nightly build will remain until a newer Stable release is available."
        }
        guard updater.automaticallyChecksForUpdates else {
            return "Automatic update checks are disabled."
        }
        return updater.updateTrack == .nightly
            ? "EasyTier checks signed Stable and Nightly builds automatically."
            : "EasyTier checks signed Stable releases automatically."
    }

    private func performUpdateAction() {
        updater.checkForUpdates()
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
                .frame(maxWidth: .infinity, alignment: .trailing)
        } label: {
            Text(label)
                .font(.body)
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
            guiCommit: abbreviated(bundledGUI) ?? "unknown",
            coreVersion: joinedVersion(tag: bundledCoreTag, commit: bundledCore)
        )
    }

    private static func joinedVersion(tag: String?, commit: String?) -> String {
        let abbreviatedCommit = abbreviated(commit)
        if let tag, let abbreviatedCommit, !tag.contains(abbreviatedCommit) {
            return "\(tag) · \(abbreviatedCommit)"
        }
        return tag ?? abbreviatedCommit ?? "unknown"
    }

    private static func abbreviated(_ value: String?) -> String? {
        guard let value else { return nil }
        let isFullCommit = value.count == 40 && value.allSatisfy(\.isHexDigit)
        return isFullCommit ? String(value.prefix(8)) : value
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "unknown" else { return nil }
        return value
    }
}

private struct RPCPortalWhitelistEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var values: [String]
    @FocusState private var focusedIndex: Int?
    var onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(values.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("", text: Binding(
                        get: { values.indices.contains(index) ? values[index] : "" },
                        set: { newValue in
                            guard values.indices.contains(index) else { return }
                            values[index] = newValue
                        }
                    ))
                    .textFieldStyle(.glassField)
                    .font(.body.monospaced())
                    .focused($focusedIndex, equals: index)
                    .onSubmit {
                        focusedIndex = nil
                    }

                    Button(role: .destructive) {
                        guard values.indices.contains(index) else { return }
                        let hadFocusedField = focusedIndex != nil
                        focusedIndex = nil
                        _ = withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
                            values.remove(at: index)
                        }
                        if !hadFocusedField {
                            onCommit()
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
            .font(.body)
        }
        .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: values.count)
        .onChange(of: focusedIndex) { oldValue, newValue in
            guard oldValue != nil, oldValue != newValue else { return }
            onCommit()
        }
    }
}

private func integerText(_ value: Binding<Int>) -> Binding<String> {
    Binding(
        get: { String(value.wrappedValue) },
        set: { newValue in
            let parts = newValue.split(whereSeparator: \.isWhitespace).map(String.init)
            let normalizedValue = Set(parts).count == 1 ? (parts.first ?? newValue) : newValue
            let digits = normalizedValue.filter(\.isNumber)
            guard let intValue = Int(digits) else { return }
            value.wrappedValue = min(max(intValue, 1), 65_535)
        }
    )
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

    var showsDockIconBinding: Binding<Bool> {
        Binding(
            get: { self.showsDockIcon },
            set: { self.showsDockIcon = $0 }
        )
    }
}
