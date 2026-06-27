import EasyTierShared
import SwiftUI

enum EasyTierSettingsTab: String, CaseIterable, Identifiable {
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
    @State private var selectedTab: EasyTierSettingsTab
    @State private var kind: ModeKind
    @State private var rpcListenEnabled: Bool
    @State private var rpcListenPort: Int
    @State private var rpcPortalWhitelist: [String]
    @State private var configServerURL: String
    @State private var remoteRPCAddress: String
    @State private var listenersExpanded = false
    @State private var listenerURLs = Self.defaultListeners
    @State private var showingDisableRPCListenWarning = false

    var onSave: (AppMode) -> Void

    init(initialTab: EasyTierSettingsTab = .general, mode: AppMode, onSave: @escaping (AppMode) -> Void) {
        self.onSave = onSave
        _selectedTab = State(initialValue: initialTab)

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
        VStack(spacing: 0) {
            header
                .padding(.top, Self.headerTopPadding)
                .padding(.bottom, Self.headerBottomPadding)
                .frame(height: Self.headerHeight)

            Divider()

            MotionSwitch(id: selectedTab, insertionEdge: .trailing, fillsAvailableSpace: false) {
                tabContentContainer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            footer
                .frame(height: Self.footerHeight)
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .glassPresentationBackground()
        .presentedSurfaceMotion()
        .alert("Disable TCP RPC Listen?", isPresented: $showingDisableRPCListenWarning) {
            Button("Keep Enabled", role: .cancel) {}
            Button("Disable", role: .destructive) { rpcListenEnabled = false }
        } message: {
            Text("Remote devices may not be able to fetch this EasyTier instance's current information when TCP RPC listen is off.")
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(EasyTierSettingsTab.allCases) { tab in
                SettingsTabButton(tab: tab, selection: $selectedTab)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var tabContentContainer: some View {
        switch selectedTab {
        case .general:
            generalSettings
                .contentPadding()
        case .easyTier:
            ScrollView(.vertical, showsIndicators: false) {
                easyTierSettings
                    .contentPadding()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .about:
            settingsAbout
                .contentPadding()
        }
    }

    private var generalSettings: some View {
        SettingsPane(width: 430) {
            SettingRow("VPN On Demand") {
                StatusText("Not Enabled")
                Button("Manage...") {}
                    .disabled(true)
            }
        }
    }

    private var easyTierSettings: some View {
        SettingsPane(width: 430) {
            SettingBlock("EasyTier RPC") {
                ControlRow("Mode") {
                    Picker("Mode", selection: kindBinding) {
                        ForEach(ModeKind.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 158)
                    .labelsHidden()
                }

                MotionSwitch(id: kind.id, insertionEdge: kind == .remote ? .trailing : .leading, fillsAvailableSpace: false) {
                    rpcModeFields
                }
            }

            if kind == .normal {
                SettingBlock("Listeners") {
                    listenersEditor
                }

                SettingBlock("VPN Portal") {
                    ControlRow("Enabled") { Toggle("", isOn: .constant(false)).labelsHidden() }
                    ControlRow("Listen Port") { DisabledField("22022", width: 72) }
                    ControlRow("Client CIDR") {
                        HStack(spacing: 5) {
                            DisabledField("10.0.0.0", width: 104)
                            Text("/").foregroundStyle(.secondary)
                            DisabledField("24", width: 38)
                        }
                    }
                }
                .disabled(true)

                SettingBlock("SOCKS5") {
                    ControlRow("Enabled") { Toggle("", isOn: .constant(false)).labelsHidden() }
                    ControlRow("Port") { DisabledField("1080", width: 72) }
                }
                .disabled(true)
            }
        }
    }

    private var listenersEditor: some View {
        DisclosureGroup(isExpanded: $listenersExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ControlRow("URLs") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(listenerURLs.indices, id: \.self) { index in
                            HStack(spacing: 5) {
                                TextField("scheme://host:port", text: $listenerURLs[index])
                                    .textFieldStyle(.glassField)
                                    .font(.system(size: 13, design: .monospaced))
                                    .frame(width: 190)
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
                ControlRow("Mapped") { StatusText("None") }
            }
        } label: {
            HStack(spacing: 8) {
                Text("Default listener set")
                    .font(.system(size: 14.5))
                StatusText("\(listenerURLs.count) listeners")
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var rpcModeFields: some View {
        switch kind {
        case .normal:
            VStack(alignment: .leading, spacing: 6) {
                ControlRow("TCP Listen") { Toggle("", isOn: rpcListenBinding).labelsHidden() }
                ControlRow("Portal") { CodeText(rpcListenEnabled ? "tcp://0.0.0.0:\(rpcListenPort)" : "Off") }
                ControlRow("Listen Port") {
                    HStack(spacing: 6) {
                        TextField("15888", value: $rpcListenPort, format: .number)
                            .textFieldStyle(.glassField)
                            .frame(width: 72)
                        Stepper("", value: $rpcListenPort, in: 1...65_535)
                            .labelsHidden()
                    }
                        .disabled(!rpcListenEnabled)
                }
                ControlRow("Whitelist") {
                    RPCPortalWhitelistEditor(values: $rpcPortalWhitelist)
                        .disabled(!rpcListenEnabled)
                }
                ControlRow("Remote RPC") {
                    TextField(Self.defaultRemoteRPCAddress, text: $remoteRPCAddress)
                        .textFieldStyle(.glassField)
                        .frame(width: 180)
                }
            }
        case .remote:
            VStack(alignment: .leading, spacing: 6) {
                ControlRow("Config Server") {
                    TextField("https://example.com/config", text: $configServerURL)
                        .textFieldStyle(.glassField)
                        .frame(width: 180)
                }
            }
        }
    }

    private var settingsAbout: some View {
        SettingsAboutView()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            if selectedTab == .easyTier {
                Button("Save Mode") {
                    onSave(buildMode())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(selectedTab == .easyTier ? .cancelAction : .defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

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

    private static let windowSize = CGSize(width: 525, height: 620)
    private static let headerTopPadding: CGFloat = 10
    private static let headerBottomPadding: CGFloat = 8
    private static let headerHeight: CGFloat = 64
    private static let footerHeight: CGFloat = 42
}

private extension View {
    func contentPadding() -> some View {
        self
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
    }
}

private struct SettingsTabButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var tab: EasyTierSettingsTab
    @Binding var selection: EasyTierSettingsTab

    private var isSelected: Bool { selection == tab }

    var body: some View {
        Button {
            withAnimation(EasyTierMotion.selection(reduceMotion: reduceMotion)) { selection = tab }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 18, weight: .medium))
                Text(tab.rawValue)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .frame(width: 68, height: 46)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsAboutView: View {
    @Environment(SoftwareUpdateController.self) private var updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let appInfo = AppVersionInfo.current
    private let revisions = SettingsSourceRevisionInfo.current

    var body: some View {
        SettingsPane(width: 430) {
            HStack(alignment: .center, spacing: 18) {
                EasyTierMark()
                    .frame(width: 70, height: 70)

                VStack(alignment: .leading, spacing: 3) {
                    Text("EasyTier for macOS")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Native GUI for managing EasyTier networks.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.bottom, 1)

            SettingBlock("Version") {
                SettingsMetadataRow(label: "GUI", value: "\(appInfo.version) · \(revisions.guiCommit)")
                SettingsMetadataRow(label: "Core", value: revisions.coreVersion)
                SettingsMetadataRow(label: "Build", value: appInfo.build)
            }

            SettingBlock("Resources") {
                HStack(spacing: 14) {
                    Link("Docs", destination: URL(string: "https://easytier.cn")!)
                    Link("Releases", destination: URL(string: "https://github.com/socoldkiller/easytier-swift/releases")!)
                    Link("GitHub", destination: URL(string: "https://github.com/socoldkiller/easytier-swift")!)
                    Link("License", destination: URL(string: "https://github.com/socoldkiller/easytier-swift/blob/main/LICENSE")!)
                }
                .font(.system(size: 13))
                .controlSize(.small)
                .padding(.leading, 6)
            }

            SettingBlock("Software Update") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(updateStatusText)
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        Spacer(minLength: 0)

                        updateAction
                            .font(.system(size: 14))
                            .controlSize(.small)
                    }

                    updateProgress
                }
                .padding(.leading, 6)
                .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: updateStatusText)
            }
        }
    }

    private var updateStatusText: String {
        switch updater.state {
        case .checking:
            "Checking stable releases..."
        case .noUpdate:
            "EasyTier is already the latest version."
        case .available(let update, _):
            "EasyTier \(update.version) is available."
        case .downloading:
            "Downloading update..."
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
            Button("Checking...") {}
                .disabled(true)
        case .available:
            Button("Download") { updater.downloadAvailableUpdate() }
        case .downloading:
            Button("Downloading...") {}
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
                .font(.system(size: 12.5))
        case .downloading(_, let progress):
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading...")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message), .downloadFailed(_, let message), .verificationFailed(_, let message):
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }
}

private struct SettingsMetadataRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            Text(value)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .controlSize(.small)
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

private struct SettingsPane<Content: View>: View {
    var width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            content
        }
        .frame(width: width, alignment: .leading)
    }
}

private struct SettingRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 14.5))
                .foregroundStyle(.primary)
                .frame(width: 130, alignment: .trailing)
            content
                .font(.system(size: 14.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
    }
}

private struct SettingBlock<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)

            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .padding(.vertical, 8)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }
}

private struct ControlRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            content
                .font(.system(size: 14.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
    }
}

private struct RPCPortalWhitelistEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(values.indices, id: \.self) { index in
                HStack(spacing: 5) {
                    TextField("10.126.126.0/24", text: Binding(
                        get: { values.indices.contains(index) ? values[index] : "" },
                        set: { newValue in
                            guard values.indices.contains(index) else { return }
                            values[index] = newValue
                        }
                    ))
                    .textFieldStyle(.glassField)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 190)

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
            .font(.system(size: 14.5))
            .foregroundStyle(.secondary)
    }
}

private struct CodeText: View {
    var value: String

    init(_ value: String) { self.value = value }

    var body: some View {
        Text(value)
            .font(.system(size: 13, design: .monospaced))
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
