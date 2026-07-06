import EasyTierShared
@preconcurrency import AppKit
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
    case remoteConfig = "Remote Config"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .mode: "slider.horizontal.3"
        case .magicDNS: "globe"
        case .rpcServer: "server.rack"
        case .remoteConfig: "cloud"
        }
    }

    var tint: Color {
        switch self {
        case .mode: SettingsTint.mode
        case .magicDNS: SettingsTint.magicDNS
        case .rpcServer: SettingsTint.rpcServer
        case .remoteConfig: SettingsTint.remoteConfig
        }
    }

    var subtitle: String {
        switch self {
        case .mode: "Choose how this EasyTier instance is configured."
        case .magicDNS: "Resolve EasyTier network names through the built-in DNS."
        case .rpcServer: "Local control plane exposing EasyTier state to the GUI and peers."
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
        case configServer = "Config Server"
        var id: String { rawValue }
    }

    @Environment(\.dismissWindow) private var dismissWindow
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
            _kind = State(initialValue: configServerURL == nil ? .normal : .configServer)
            _rpcListenEnabled = State(initialValue: rpcListenEnabled)
            _rpcListenPort = State(initialValue: rpcListenPort)
            _rpcPortalWhitelist = State(initialValue: Self.initialRPCPortalWhitelist(from: rpcPortalWhitelist))
            _configServerURL = State(initialValue: configServerURL?.absoluteString ?? "")
            _remoteRPCAddress = State(initialValue: Self.normalizedSingleValue(Self.defaultRemoteRPCAddress, fallback: Self.defaultRemoteRPCAddress))
        case let .remote(remoteRPCAddress):
            _kind = State(initialValue: .normal)
            _rpcListenEnabled = State(initialValue: true)
            _rpcListenPort = State(initialValue: AppMode.defaultRPCListenPort)
            _rpcPortalWhitelist = State(initialValue: AppMode.defaultRPCPortalWhitelist)
            _configServerURL = State(initialValue: "")
            _remoteRPCAddress = State(initialValue: Self.normalizedSingleValue(remoteRPCAddress, fallback: Self.defaultRemoteRPCAddress))
        }
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: effectiveSelectionBinding, visibleEasyTierSections: visibleEasyTierSections)
                .navigationSplitViewColumnWidth(min: 200, ideal: Self.sidebarWidth, max: 240)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .toolbar {
            if isEasyTierActive {
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") { saveSettings() }
                        .keyboardShortcut(.defaultAction)
                        .help("Save changes (⏎)")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { dismissWindow() }
                    .keyboardShortcut(isEasyTierActive ? .cancelAction : .defaultAction)
                    .help("Close settings (⎋)")
            }
        }
        .frame(
            minWidth: Self.windowSize.width,
            idealWidth: Self.windowSize.width,
            minHeight: Self.windowSize.height,
            idealHeight: 620,
            alignment: .topLeading
        )
        .hideScrollViewScrollers()
        .background(
            SettingsEscapeKeyBridge(isEnabled: settingsEscapeKeyHandlingEnabled) {
                dismissSettingsWithoutSaving()
            }
            .frame(width: 0, height: 0)
        )
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
        switch effectiveSelection {
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
        VStack(alignment: .leading, spacing: 18) {
            paneHeader(title: "General", subtitle: "Appearance, launch, and quit behavior for the EasyTier GUI.")

            Form {
                Section {
                    Toggle("Frosted Glass", isOn: appearance.glassEffectsEnabledBinding)
                    Toggle("Panel Backgrounds", isOn: appearance.glassPanelBackgroundsEnabledBinding)
                        .disabled(!appearance.glassEffectsEnabled)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Panel backgrounds apply only while frosted glass is enabled. Traditional mode keeps solid panels for readability.")
                }

                Section {
                    Toggle("Launch at Login", isOn: $loginItem.isEnabled)
                        .onChange(of: loginItem.isEnabled) { _, _ in loginItem.apply() }
                } header: {
                    Text("General")
                } footer: {
                    Text("Open EasyTier automatically when you sign in.")
                }

                Section {
                    Toggle("Keep VPN Running After Quit", isOn: vpnOnDemandBinding)
                } header: {
                    Text("Quit Behavior")
                } footer: {
                    Text("Only helper-backed VPN networks can keep running after the app quits. no_tun networks stop with the app.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { loginItem.refresh() }
    }

    @ViewBuilder
    private func paneHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title2.weight(.semibold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: EasyTier

    @ViewBuilder
    private func easyTierSectionView(_ section: EasyTierSection) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            paneHeader(title: section.rawValue, subtitle: section.subtitle)

            switch section {
            case .mode: modeSection
            case .magicDNS: magicDNSSection
            case .rpcServer: rpcServerSection
            case .remoteConfig: remoteConfigSection
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var modeSection: some View {
        VStack(spacing: 8) {
            ModeOptionTile(
                title: "Normal",
                description: "Run a local EasyTier node with its own listeners and RPC server.",
                systemImage: "desktopcomputer",
                tint: SettingsTint.mode,
                isSelected: kind == .normal,
                action: { selectKind(.normal) }
            )
            ModeOptionTile(
                title: "Config Server",
                description: "Pull the network profile from a config server on launch.",
                systemImage: "icloud.and.arrow.down",
                tint: SettingsTint.remoteConfig,
                isSelected: kind == .configServer,
                action: { selectKind(.configServer) }
            )
        }
    }

    private var magicDNSSection: some View {
        Form {
            Section {
                LabeledContent("DNS Suffix") {
                    TextField("", text: $magicDNSSuffix)
                        .textFieldStyle(.glassField)
                        .font(.body.monospaced())
                        .frame(width: 160)
                }
                LabeledContent("DNS Routing") {
                    Text("Split DNS")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Resolver") {
                    HStack(spacing: 8) {
                        Text(MagicDNSDisplay.resolverIP)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                        StatusDot(tone: .positive, accessibilityLabel: "Active")
                    }
                }
            } footer: {
                Text("Only names under this suffix are resolved by EasyTier. Other domains keep using system DNS. Running networks need a restart after it changes.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var rpcServerSection: some View {
        Form {
            Section("Status") {
                LabeledContent("Status", value: rpcListenEnabled ? "Listening" : "Off")
                LabeledContent("Port", value: rpcListenEnabled ? "\(rpcListenPort)" : "-")
                LabeledContent("Whitelist", value: "\(rpcPortalWhitelist.count)")
            }

            Section {
                Toggle("TCP Listen", isOn: rpcListenBinding)
                LabeledContent("Portal") {
                    if rpcListenEnabled {
                        Text(verbatim: "tcp://0.0.0.0:\(rpcListenPort)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        StatusPill("Off", tone: .neutral)
                    }
                }
                LabeledContent("Listen Port") {
                    HStack(spacing: 8) {
                        TextField("", text: integerText($rpcListenPort))
                            .textFieldStyle(.glassField)
                            .font(.body.monospacedDigit())
                            .frame(width: 96)
                        Stepper("Listen Port", value: $rpcListenPort, in: 1...65_535)
                            .labelsHidden()
                    }
                    .disabled(!rpcListenEnabled)
                }
                LabeledContent("Whitelist") {
                    RPCPortalWhitelistEditor(values: $rpcPortalWhitelist)
                        .disabled(!rpcListenEnabled)
                }
                LabeledContent("Remote RPC") {
                    TextField("", text: $remoteRPCAddress)
                        .textFieldStyle(.glassField)
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Address the GUI uses to reach EasyTier.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var remoteConfigSection: some View {
        Form {
            Section {
                LabeledContent("Config Server") {
                    TextField("https://example.com/config", text: $configServerURL)
                        .textFieldStyle(.glassField)
                }
            } footer: {
                Text("EasyTier fetches the network profile from this URL on launch.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Footer

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
            dismissWindow()
        } catch {
            settingsError = error.localizedDescription
        }
    }

    private var settingsEscapeKeyHandlingEnabled: Bool {
        settingsError == nil && !showingDisableRPCListenWarning
    }

    private func dismissSettingsWithoutSaving() {
        dismissWindow()
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
        case .configServer:
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
                target = sanitizedSelection(.easyTier(current))
            } else {
                target = .easyTier(.mode)
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
        if case .easyTier = effectiveSelection { return true }
        return false
    }

    private var effectiveSelection: SettingsSelection {
        sanitizedSelection(selection)
    }

    private var effectiveSelectionBinding: Binding<SettingsSelection> {
        Binding(
            get: { effectiveSelection },
            set: { selection = sanitizedSelection($0) }
        )
    }

    private func sanitizedSelection(_ candidate: SettingsSelection) -> SettingsSelection {
        switch candidate {
        case .easyTier(let section) where !visibleEasyTierSections.contains(section):
            .easyTier(.mode)
        default:
            candidate
        }
    }

    private var visibleEasyTierSections: [EasyTierSection] {
        Self.visibleEasyTierSections(for: kind)
    }

    private static func visibleEasyTierSections(for kind: ModeKind) -> [EasyTierSection] {
        switch kind {
        case .normal: [.mode, .magicDNS, .rpcServer]
        case .configServer: [.mode, .magicDNS, .remoteConfig]
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

    private static func normalizedSingleValue(_ value: String, fallback: String) -> String {
        let parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.isEmpty { return fallback }
        if Set(parts).count == 1 { return parts[0] }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let defaultRemoteRPCAddress = "tcp://127.0.0.1:\(AppMode.defaultRPCListenPort)"

    private static let sidebarWidth: CGFloat = 220
    fileprivate static let sidebarTopClearance: CGFloat = 8
    private static let windowSize = CGSize(width: 600, height: 500)
}

private struct SettingsEscapeKeyBridge: NSViewRepresentable {
    nonisolated(unsafe) var isEnabled: Bool
    nonisolated(unsafe) var onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = SettingsEscapeMonitorView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.window = window
        }
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.window = nsView.window
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator {
        nonisolated(unsafe) var parent: SettingsEscapeKeyBridge
        nonisolated(unsafe) weak var window: NSWindow?
        private var monitor: Any?

        init(parent: SettingsEscapeKeyBridge) {
            self.parent = parent
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard parent.isEnabled, event.keyCode == Self.escapeKeyCode else { return event }
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            guard let window, event.window == window else { return event }

            parent.onEscape()
            return nil
        }

        private static let escapeKeyCode: UInt16 = 53
    }
}

private final class SettingsEscapeMonitorView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
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

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsSelection.general)
            } header: {
                Color.clear
                    .frame(height: EasyTierSettingsSheet.sidebarTopClearance)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .accessibilityHidden(true)
            }

            Section("EasyTier") {
                ForEach(visibleEasyTierSections) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(SettingsSelection.easyTier(section))
                }
            }

            Section {
                Label("About", systemImage: "info.circle")
                    .tag(SettingsSelection.about)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .hideScrollViewScrollers()
    }
}

private struct SettingsAboutView: View {
    @Environment(SoftwareUpdateController.self) private var updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let appInfo = AppVersionInfo.current
    private let revisions = SettingsSourceRevisionInfo.current

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
            .padding(.bottom, 4)

            Form {
                Section("Version") {
                    SettingsMetadataRow(label: "GUI", value: "\(appInfo.version) · \(revisions.guiCommit)")
                    SettingsMetadataRow(label: "Core", value: revisions.coreVersion)
                    SettingsMetadataRow(label: "Build", value: appInfo.build)
                }

                Section("Resources") {
                    HStack(spacing: 14) {
                        Link("Docs", destination: URL(string: "https://easytier.cn")!)
                        Link("Releases", destination: URL(string: "https://github.com/socoldkiller/easytier-macos/releases")!)
                        Link("GitHub", destination: URL(string: "https://github.com/socoldkiller/easytier-macos")!)
                        Link("License", destination: URL(string: "https://github.com/socoldkiller/easytier-macos/blob/main/LICENSE")!)
                    }
                    .controlSize(.small)
                    SettingsMetadataRow(label: "License", value: "MIT © 2026 contributors")
                }

                Section("Software Update") {
                    LabeledContent {
                        HStack(spacing: 10) {
                            if case .available = updater.state {
                                StatusPill("Update available", tone: .warning)
                            }
                            Spacer(minLength: 0)
                            Button("Check for Updates…") { updater.checkForUpdatesAndPresent() }
                                .controlSize(.small)
                        }
                    } label: {
                        Text(updateSummaryText)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let lastCheck = updater.lastCheckFormatted {
                        LabeledContent("Last check", value: lastCheck)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: updateSummaryText)
    }

    private var updateSummaryText: String {
        switch updater.state {
        case .checking:
            "Checking stable releases…"
        case .noUpdate:
            "EasyTier is up to date."
        case .available(let update, _):
            "EasyTier \(update.version) is available."
        case .downloading:
            "Downloading update…"
        case .readyToInstall:
            "Update ready to install."
        case .failed, .downloadFailed, .verificationFailed:
            "Updater needs attention."
        case .idle:
            "Checks stable releases only."
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
                    TextField("", text: Binding(
                        get: { values.indices.contains(index) ? values[index] : "" },
                        set: { newValue in
                            guard values.indices.contains(index) else { return }
                            values[index] = newValue
                        }
                    ))
                    .textFieldStyle(.glassField)
                    .font(.body.monospaced())

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
            .font(.body)
        }
        .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: values.count)
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
}
