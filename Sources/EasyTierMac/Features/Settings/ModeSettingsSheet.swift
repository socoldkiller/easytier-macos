import EasyTierShared
@preconcurrency import AppKit
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
    case magicDNS = "Magic DNS"
    case rpcServer = "RPC Server"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .magicDNS: "globe"
        case .rpcServer: "server.rack"
        }
    }

    var tint: Color {
        switch self {
        case .magicDNS: SettingsTint.magicDNS
        case .rpcServer: SettingsTint.rpcServer
        }
    }

    var subtitle: String {
        switch self {
        case .magicDNS: "Resolve EasyTier network names through the built-in DNS."
        case .rpcServer: "Local control plane exposing EasyTier state to the GUI and peers."
        }
    }
}

enum SettingsSelection: Hashable {
    case general
    case easyTier(EasyTierSection)
    case about
}

struct EasyTierSettingsSheet: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppContext.self) private var appContext
    @State private var selection: SettingsSelection
    @State private var rpcListenEnabled: Bool
    @State private var rpcListenPort: Int
    @State private var rpcPortalWhitelist: [String]
    @State private var magicDNSSuffix: String
    @State private var settingsError: String?
    @State private var showingDisableRPCListenWarning = false
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
        switch initialTab {
        case .general: _selection = State(initialValue: .general)
        case .easyTier: _selection = State(initialValue: .easyTier(.magicDNS))
        case .about: _selection = State(initialValue: .about)
        }
        _magicDNSSuffix = State(initialValue: magicDNSSettings.dnsSuffix)

        _rpcListenEnabled = State(initialValue: mode.rpcListenEnabled)
        _rpcListenPort = State(initialValue: mode.rpcListenPort)
        _rpcPortalWhitelist = State(initialValue: Self.initialRPCPortalWhitelist(from: mode.rpcPortalWhitelist))
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: effectiveSelectionBinding, visibleEasyTierSections: visibleEasyTierSections)
                .navigationSplitViewColumnWidth(min: 200, ideal: Self.sidebarWidth, max: 240)
                .easyTierSidebarBackground(
                    glassEffectsEnabled: appearance.glassEffectsEnabled,
                    renderCoordinator: appContext.presentation.glassRenderCoordinator
                )
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: appContext.settings.requestedTab) { _, tab in
            selectSettingsTab(tab)
        }
        .onChange(of: selection) { _, newSelection in
            let tab: EasyTierSettingsTab
            switch newSelection {
            case .general: tab = .general
            case .easyTier: tab = .easyTier
            case .about: tab = .about
            }
            appContext.settings.request(tab)
        }
        .onChange(of: rpcListenEnabled) { _, _ in
            applySettings()
        }
        .onChange(of: rpcListenPort) { _, _ in
            applySettings()
        }
        .onChange(of: rpcPortalWhitelist) { _, _ in
            applySettings()
        }
        .onChange(of: magicDNSSuffix) { _, _ in
            applySettings()
        }
        .hideScrollViewScrollers()
        .background(
            SettingsEscapeKeyBridge(isEnabled: settingsEscapeKeyHandlingEnabled) {
                dismissWindow()
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                paneHeader(title: "General", subtitle: "Appearance, launch, updates, and quit behavior for the EasyTier GUI.")

                CardSection(
                    "Appearance",
                    footer: "Panel backgrounds apply only while frosted glass is enabled. Traditional mode keeps solid panels for readability."
                ) {
                    Toggle(isOn: appearance.glassEffectsEnabledBinding) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Frosted Glass")
                            Text("Beta")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.13), in: Capsule(style: .continuous))
                                .accessibilityLabel(Text("Beta"))
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityLabel(Text("Frosted Glass, Beta"))
                    SettingsRowDivider()
                    Toggle("Panel Backgrounds", isOn: appearance.glassPanelBackgroundsEnabledBinding)
                        .disabled(!appearance.glassEffectsEnabled)
                }

                CardSection(
                    "General",
                    footer: "When hidden from the Dock, EasyTier remains available from the menu bar."
                ) {
                    Toggle("Show in Dock", isOn: appearance.showsDockIconBinding)
                    SettingsRowDivider()
                    Toggle("Launch at Login", isOn: loginItemBinding)
                        .onChange(of: loginItem.isEnabled) { _, _ in loginItem.apply() }
                }

                CardSection(
                    "Software Update",
                    footer: softwareUpdateFooterText
                ) {
                    Toggle("Check for Updates Automatically", isOn: autoCheckUpdatesBinding)
                    SettingsRowDivider()
                    SettingsInlineRow("Update To") {
                        Picker("Update To", selection: updateTrackBinding) {
                            ForEach(SoftwareUpdateTrack.allCases) { track in
                                Text(track.displayName).tag(track)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(minWidth: 156, alignment: .trailing)
                        .disabled(updater.sessionInProgress)
                    }
                    SettingsRowDivider()
                    SettingsInlineRow("Status") {
                        Text(generalUpdateSummaryText)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SettingsRowDivider()
                    SettingsInlineRow("Updates") {
                        Button("Check for Updates…", action: performUpdateAction)
                            .controlSize(.small)
                            .disabled(!updater.canCheckForUpdates)
                    }
                }

                CardSection(
                    "Quit Behavior",
                    footer: "All running networks are helper-managed and can remain active after the EasyTier window and menu bar app quit."
                ) {
                    Toggle("Keep Networks Running After Quit", isOn: vpnOnDemandBinding)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollIndicators(.hidden, axes: .vertical)
        .hideScrollViewScrollers()
        .task {
            await Task.yield()
            loginItem.refresh()
        }
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                paneHeader(title: section.rawValue, subtitle: section.subtitle)

                switch section {
                case .magicDNS: magicDNSSection
                case .rpcServer: rpcServerSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollIndicators(.hidden, axes: .vertical)
        .hideScrollViewScrollers()
    }

    private var magicDNSSection: some View {
        CardSection(
            "Resolver",
            footer: "Only names under this suffix are resolved by EasyTier. Other domains keep using system DNS. Running networks need a restart after it changes."
        ) {
            SettingsInlineRow("DNS Suffix") {
                TextField("", text: $magicDNSSuffix)
                    .textFieldStyle(.glassField)
                    .font(.body.monospaced())
                    .frame(width: 160)
            }
            SettingsRowDivider()
            SettingsInlineRow("DNS Routing") {
                Text("Split DNS")
                    .foregroundStyle(.secondary)
            }
            SettingsRowDivider()
            SettingsInlineRow("Resolver") {
                HStack(spacing: 8) {
                    Text(MagicDNSDisplay.resolverIP)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                    StatusDot(
                        tone: store.isMagicDNSResolverActive ? .positive : .neutral,
                        accessibilityLabel: store.isMagicDNSResolverActive ? "Active" : "Inactive"
                    )
                }
            }
        }
    }

    private var rpcServerSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            CardSection("Status") {
                SettingsInlineRow("Status") {
                    Text(rpcListenEnabled ? "Listening" : "Off")
                        .foregroundStyle(.secondary)
                }
                SettingsRowDivider()
                SettingsInlineRow("Port") {
                    Text(rpcListenEnabled ? "\(rpcListenPort)" : "-")
                        .foregroundStyle(.secondary)
                }
                SettingsRowDivider()
                SettingsInlineRow("Whitelist") {
                    Text("\(rpcPortalWhitelist.count)")
                        .foregroundStyle(.secondary)
                }
            }

            CardSection("Server", footer: "Address the GUI uses to reach EasyTier.") {
                Toggle("TCP Listen", isOn: rpcListenBinding)
                SettingsRowDivider()
                SettingsInlineRow("Portal") {
                    if rpcListenEnabled {
                        Text(verbatim: "tcp://0.0.0.0:\(rpcListenPort)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        StatusPill("Off", tone: .neutral)
                    }
                }
                SettingsRowDivider()
                SettingsInlineRow("Listen Port") {
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
                SettingsRowDivider()
                SettingsInlineRow("Whitelist", alignment: .top) {
                    RPCPortalWhitelistEditor(values: $rpcPortalWhitelist)
                        .disabled(!rpcListenEnabled)
                        .frame(maxWidth: 340, alignment: .leading)
                }
            }
        }
    }

    // MARK: Footer

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

    private var generalUpdateSummaryText: String {
        if updater.sessionInProgress { return "Update session in progress" }
        guard updater.automaticallyChecksForUpdates else { return "Automatic checks are off" }
        return updater.updateTrack == .nightly
            ? "Checks signed Stable and Nightly builds daily"
            : "Checks signed Stable releases daily"
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

    private func applySettings() {
        do {
            let settings = try MagicDNSSettings(dnsSuffix: magicDNSSuffix)
            settingsError = nil
            onChange(buildMode(), settings)
        } catch {
            settingsError = error.localizedDescription
        }
    }

    private var settingsEscapeKeyHandlingEnabled: Bool {
        settingsError == nil && !showingDisableRPCListenWarning
    }

    private func buildMode() -> AppMode {
        AppMode(
            rpcListenEnabled: rpcListenEnabled,
            rpcListenPort: rpcListenPort,
            rpcPortalWhitelist: normalizedRPCPortalWhitelist
        )
    }

    private func selectSettingsTab(_ tab: EasyTierSettingsTab) {
        let target: SettingsSelection
        switch tab {
        case .general:
            target = .general
        case .easyTier:
            if case .easyTier(let current) = selection {
                target = sanitizedSelection(.easyTier(current))
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
            .easyTier(.magicDNS)
        default:
            candidate
        }
    }

    private var visibleEasyTierSections: [EasyTierSection] {
        [.magicDNS, .rpcServer]
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

    private static let sidebarWidth: CGFloat = 220
    fileprivate static let sidebarTopClearance: CGFloat = 8
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

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSelection
    var visibleEasyTierSections: [EasyTierSection]

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsSelection.general)

                ForEach(visibleEasyTierSections) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(SettingsSelection.easyTier(section))
                }

                Label("About", systemImage: "info.circle")
                    .tag(SettingsSelection.about)
            } header: {
                Color.clear
                    .frame(height: EasyTierSettingsSheet.sidebarTopClearance)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .accessibilityHidden(true)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .hideScrollViewScrollers()
    }
}

private struct SettingsAboutView: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let appInfo = AppVersionInfo.current
    private let revisions = SettingsSourceRevisionInfo.current

    private var updater: SoftwareUpdateController { appContext.softwareUpdate.controller }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 10) {
                EasyTierMark()
                    .frame(width: 96, height: 96)

                Text("EasyTier for macOS")
                    .font(.largeTitle.weight(.semibold))

                Text("Version \(appInfo.displayVersion)")
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
                Section("Software Update") {
                    LabeledContent {
                        HStack(spacing: 10) {
                            Spacer(minLength: 0)
                            Button("Check for Updates…", action: performUpdateAction)
                                .controlSize(.small)
                                .disabled(!updater.canCheckForUpdates)
                        }
                    } label: {
                        Text(updateSummaryText)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent("Update track", value: updater.updateTrack.displayName)
                    if let lastCheck = updater.lastUpdateCheckDate {
                        LabeledContent("Last check", value: lastCheck.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                Section("Version") {
                    SettingsMetadataRow(label: "GUI", value: "\(appInfo.version) · \(revisions.guiCommit)")
                    SettingsMetadataRow(label: "Core", value: revisions.coreVersion)
                    SettingsMetadataRow(label: "Build channel", value: appInfo.buildChannel.buildDisplayName)
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
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
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

private struct SettingsInlineRow<Content: View>: View {
    var label: String
    var alignment: VerticalAlignment
    @ViewBuilder var content: Content

    init(
        _ label: String,
        alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 16) {
            Text(label)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .frame(minWidth: 110, alignment: .leading)

            Spacer(minLength: 12)

            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .opacity(0.45)
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

    var showsDockIconBinding: Binding<Bool> {
        Binding(
            get: { self.showsDockIcon },
            set: { self.showsDockIcon = $0 }
        )
    }
}
