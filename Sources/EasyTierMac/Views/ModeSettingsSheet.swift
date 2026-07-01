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
    @State private var selectedTab: EasyTierSettingsTab
    @State private var kind: ModeKind
    @State private var rpcListenEnabled: Bool
    @State private var rpcListenPort: Int
    @State private var rpcPortalWhitelist: [String]
    @State private var configServerURL: String
    @State private var remoteRPCAddress: String
    @State private var magicDNSSuffix: String
    @State private var settingsError: String?
    @State private var listenersExpanded = false
    @State private var listenerURLs = Self.defaultListeners
    @State private var showingDisableRPCListenWarning = false

    var onSave: (AppMode, MagicDNSSettings) -> Void

    init(
        initialTab: EasyTierSettingsTab = .general,
        mode: AppMode,
        magicDNSSettings: MagicDNSSettings,
        onSave: @escaping (AppMode, MagicDNSSettings) -> Void
    ) {
        self.onSave = onSave
        _selectedTab = State(initialValue: initialTab)
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
            SettingsSidebar(selection: $selectedTab)
                .navigationSplitViewColumnWidth(min: 200, ideal: Self.sidebarWidth, max: 280)
        } detail: {
            MotionSwitch(id: selectedTab, insertionEdge: .trailing, fillsAvailableSpace: false) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            selectSettingsTab(requestedSettingsTab)
        }
        .onChange(of: requestedSettingsTab) { _, tab in
            selectSettingsTab(tab)
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
        switch selectedTab {
        case .general:
            generalSettings
        case .easyTier:
            easyTierSettings
        case .about:
            SettingsAboutView()
        }
    }

    // MARK: General

    private var generalSettings: some View {
        Form {
            Section {
                LabeledContent("Frosted Glass") {
                    Toggle("", isOn: appearance.glassEffectsEnabledBinding).labelsHidden()
                }
                LabeledContent("Panel Backgrounds") {
                    Toggle("", isOn: appearance.glassPanelBackgroundsEnabledBinding).labelsHidden()
                }
                .disabled(!appearance.glassEffectsEnabled)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Panel backgrounds apply only while frosted glass is enabled. Traditional mode keeps solid panels for readability.")
            }

            Section {
                LabeledContent("Launch at Login") {
                    Toggle("", isOn: $loginItem.isEnabled).labelsHidden()
                }
                .onChange(of: loginItem.isEnabled) { _, _ in loginItem.apply() }
            } header: {
                Text("General")
            } footer: {
                Text("Open EasyTier automatically when you sign in.")
            }

            Section {
                LabeledContent("Keep VPN Running After Quit") {
                    Toggle("", isOn: vpnOnDemandBinding).labelsHidden()
                }
            } header: {
                Text("Quit Behavior")
            } footer: {
                Text("Only helper-backed VPN networks can keep running after the app quits. no_tun networks stop with the app.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { footer }
        .task { loginItem.refresh() }
    }

    // MARK: EasyTier

    private var easyTierSettings: some View {
        Form {
            Section {
                LabeledContent("Mode") {
                    Picker("Mode", selection: kindBinding) {
                        ForEach(ModeKind.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .labelsHidden()
                }
            } header: {
                Text("EasyTier RPC")
            }

            Section {
                LabeledContent("DNS Suffix") {
                    TextField("", text: $magicDNSSuffix)
                        .textFieldStyle(.glassField)
                        .font(.system(size: 13.5, design: .monospaced))
                        .frame(width: 160)
                }
                LabeledContent("DNS Routing") {
                    StatusText("Split DNS")
                }
                LabeledContent("Resolver") {
                    CodeText(MagicDNSDisplay.resolverIP)
                }
            } header: {
                Text("Magic DNS")
            } footer: {
                Text("Only names under this suffix are resolved by EasyTier. Other domains keep using system DNS. Running networks need a restart after it changes.")
            }

            if kind == .normal {
                Section {
                    LabeledContent("TCP Listen") {
                        Toggle("", isOn: rpcListenBinding).labelsHidden()
                    }
                    LabeledContent("Portal") {
                        CodeText(rpcListenEnabled ? "tcp://0.0.0.0:\(rpcListenPort)" : "Off")
                    }
                    LabeledContent("Listen Port") {
                        HStack(spacing: 8) {
                            TextField("15888", value: $rpcListenPort, format: .number)
                                .textFieldStyle(.glassField)
                                .frame(width: 96)
                            Stepper("", value: $rpcListenPort, in: 1...65_535)
                                .labelsHidden()
                        }
                        .disabled(!rpcListenEnabled)
                    }
                    LabeledContent("Whitelist") {
                        RPCPortalWhitelistEditor(values: $rpcPortalWhitelist)
                            .disabled(!rpcListenEnabled)
                    }
                    LabeledContent("Remote RPC") {
                        TextField(Self.defaultRemoteRPCAddress, text: $remoteRPCAddress)
                            .textFieldStyle(.glassField)
                    }
                } header: {
                    Text("RPC Server")
                }

                Section {
                    listenersEditor
                } header: {
                    Text("Listeners")
                }

                Section {
                    LabeledContent("Enabled") {
                        Toggle("", isOn: .constant(false)).labelsHidden()
                    }
                    LabeledContent("Listen Port") {
                        DisabledField("22022", width: 96)
                    }
                    LabeledContent("Client CIDR") {
                        HStack(spacing: 5) {
                            DisabledField("10.0.0.0", width: 128)
                            Text("/").foregroundStyle(.secondary)
                            DisabledField("24", width: 44)
                        }
                    }
                    LabeledContent("Enabled") {
                        Toggle("", isOn: .constant(false)).labelsHidden()
                    }
                    LabeledContent("Port") {
                        DisabledField("1080", width: 96)
                    }
                } header: {
                    Text("VPN Portal · SOCKS5")
                } footer: {
                    Text("Requires a config file. Configured via TOML profile.")
                }
                .disabled(true)
            } else {
                Section {
                    LabeledContent("Config Server") {
                        TextField("https://example.com/config", text: $configServerURL)
                            .textFieldStyle(.glassField)
                    }
                } header: {
                    Text("Remote Config")
                } footer: {
                    Text("EasyTier pulls its network profile from this URL on launch.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var listenersEditor: some View {
        DisclosureGroup(isExpanded: $listenersExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("URLs") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(listenerURLs.indices, id: \.self) { index in
                            HStack(spacing: 6) {
                                TextField("scheme://host:port", text: $listenerURLs[index])
                                    .textFieldStyle(.glassField)
                                    .font(.system(size: 13, design: .monospaced))
                                    .frame(width: 220)
                                Button {
                                    listenerURLs.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            listenerURLs.append(ListenerURLDefaults.next(excluding: listenerURLs))
                            listenersExpanded = true
                        } label: {
                            Label("Add URL", systemImage: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13.5))
                    }
                }
                LabeledContent("Mapped") { StatusText("None") }
            }
        } label: {
            HStack(spacing: 8) {
                Text("Default listener set")
                StatusText("\(listenerURLs.count) listeners")
            }
        }
        .controlSize(.small)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            if selectedTab == .easyTier {
                Button("Save") { saveSettings() }
                    .keyboardShortcut(.defaultAction)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(selectedTab == .easyTier ? .cancelAction : .defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: Bindings

    private var kindBinding: Binding<ModeKind> {
        Binding(
            get: { kind },
            set: { newValue in
                guard newValue != kind else { return }
                withAnimation(EasyTierMotion.selection(reduceMotion: reduceMotion)) { kind = newValue }
            }
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
        guard let tab = EasyTierSettingsTab(rawValue: rawValue), selectedTab != tab else { return }
        withAnimation(EasyTierMotion.selection(reduceMotion: reduceMotion)) {
            selectedTab = tab
        }
    }

    private var normalizedRPCPortalWhitelist: [String]? {
        let values = rpcPortalWhitelist.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }

    private static let defaultRemoteRPCAddress = "tcp://127.0.0.1:\(AppMode.defaultRPCListenPort)"

    private static let defaultListeners = [
        "tcp://0.0.0.0:11010",
        "udp://0.0.0.0:11010",
        "wg://0.0.0.0:11011",
    ]

    private static let sidebarWidth: CGFloat = 220
    private static let windowSize = CGSize(width: 720, height: 560)
}

// MARK: - About

enum EasyTierSettingsTabRequest {
    static let key = "EasyTierSettingsTab"

    static func set(_ tab: EasyTierSettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: key)
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: EasyTierSettingsTab

    var body: some View {
        List(selection: $selection) {
            Section("Settings") {
                ForEach(EasyTierSettingsTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

private struct SettingsAboutView: View {
    @Environment(SoftwareUpdateController.self) private var updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    private let appInfo = AppVersionInfo.current
    private let revisions = SettingsSourceRevisionInfo.current

    var body: some View {
        VStack(spacing: 0) {
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
            .padding(.bottom, 14)

            Form {
                Section {
                    SettingsMetadataRow(label: "GUI", value: "\(appInfo.version) · \(revisions.guiCommit)")
                    SettingsMetadataRow(label: "Core", value: revisions.coreVersion)
                    SettingsMetadataRow(label: "Build", value: appInfo.build)
                } header: {
                    Text("Version")
                }

                Section {
                    HStack(spacing: 14) {
                        Link("Docs", destination: URL(string: "https://easytier.cn")!)
                        Link("Releases", destination: URL(string: "https://github.com/socoldkiller/easytier-swift/releases")!)
                        Link("GitHub", destination: URL(string: "https://github.com/socoldkiller/easytier-swift")!)
                        Link("License", destination: URL(string: "https://github.com/socoldkiller/easytier-swift/blob/main/LICENSE")!)
                    }
                    .controlSize(.small)
                    SettingsMetadataRow(label: "License", value: "LGPL-3.0 © 2026 contributors")
                } header: {
                    Text("Resources")
                }

                Section {
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
                } header: {
                    Text("Software Update")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    .frame(width: 220)

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

private struct DisabledField: View {
    var value: String
    var width: CGFloat

    init(_ value: String, width: CGFloat) {
        self.value = value
        self.width = width
    }

    var body: some View {
        TextField(value, text: .constant(value))
            .textFieldStyle(.glassField)
            .frame(width: width)
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
