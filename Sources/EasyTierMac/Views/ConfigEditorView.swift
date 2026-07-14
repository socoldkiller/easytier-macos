import EasyTierShared
import SwiftUI

struct ConfigEditorView: View {
    @Environment(EasyTierAppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Binding var config: NetworkConfig
    @Binding private var networkSecretDraft: String?
    var members: [NetworkMemberStatus] = []
    var remoteSession: RemoteConfigSession? = nil
    var onScrolledPastTopChange: (Bool) -> Void = { _ in }
    @State private var reversePortForwardStatus: [UUID: Bool] = [:]
    @State private var reversePortForwardPending: Set<UUID> = []

    @State private var displayAdvanced: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRemote: Bool { remoteSession != nil }

    init(
        config: Binding<NetworkConfig>,
        networkSecretDraft: Binding<String?>? = nil,
        members: [NetworkMemberStatus] = [],
        remoteSession: RemoteConfigSession? = nil,
        onScrolledPastTopChange: @escaping (Bool) -> Void = { _ in }
    ) {
        _config = config
        _networkSecretDraft = networkSecretDraft ?? config.network_secret
        self.members = members
        self.remoteSession = remoteSession
        self.onScrolledPastTopChange = onScrolledPastTopChange
    }

    private static let scrollSpaceName = "ConfigEditorScroll"
    private static let toolbarHideThreshold: CGFloat = 18

    var body: some View {
        ScrollView {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: ConfigEditorScrollOffsetKey.self,
                        value: proxy.frame(in: .named(Self.scrollSpaceName)).minY
                    )
            }
            .frame(height: 0)

            LazyVStack(alignment: .leading, spacing: 14) {
                CardSection("Network") {
                    networkNameRow
                    FieldRow("Network secret") {
                        NetworkSecretField(
                            config: config,
                            secret: $networkSecretDraft,
                            keychainEnabled: !isRemote
                        )
                    }
                }
                .disabled(isRemote)
                .help(isRemote ? "Network identity cannot be changed remotely because doing so can disconnect this device." : "")

                CardSection("Peers") {
                    StringListEditor(title: "Initial nodes", placeholder: "tcp://host:11010", values: $config.peer_urls)
                }

                advancedDisclosure
            }
            .padding(18)
        }
        .coordinateSpace(name: Self.scrollSpaceName)
        .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
        .hideScrollViewScrollers()
        .textFieldStyle(.glassField)
        .onScrollPhaseChange { _, phase in
            store.isAnyViewScrolling = phase.isScrolling
        }
        .onDisappear { store.isAnyViewScrolling = false }
        .onAppear {
            syncDisplayMode()
            if !isRemote {
                Task { await refreshReverseStatus() }
            }
        }
        .onChange(of: config.instance_id) { _, _ in
            syncDisplayMode()
        }
        .onPreferenceChange(ConfigEditorScrollOffsetKey.self) { minY in
            onScrolledPastTopChange(minY < -Self.toolbarHideThreshold)
        }
        .onChange(of: portForwardKeys) { oldKeys, newKeys in
            for (id, key) in oldKeys {
                if newKeys[id] == nil || newKeys[id] != key {
                    reversePortForwardStatus[id] = nil
                    if let oldFP = oldKeys[id] {
                        store.reversedPortForwardFingerprints[config.instance_id]?.remove(oldFP)
                        if store.reversedPortForwardFingerprints[config.instance_id]?.isEmpty == true {
                            store.reversedPortForwardFingerprints.removeValue(forKey: config.instance_id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var networkNameRow: some View {
        FieldRow("Network name") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("easytier", text: $config.network_name)
                    .textFieldStyle(.glassField)
                if networkNameHasDuplicate {
                    Label(
                        "Another network already uses this name. Letting it persist will reuse that network's saved secret.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var advancedDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureHeader(
                isExpanded: displayAdvanced,
                title: "Advanced",
                onToggle: {
                    withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
                        displayAdvanced.toggle()
                    }
                },
                trailing: {
                    if !displayAdvanced && hasActiveAdvancedSettings {
                        Text("Some advanced settings are active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            )

            if displayAdvanced {
                advancedSections
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 8))
            }
        }
    }

    @ViewBuilder
    private var advancedSections: some View {
        CardSection("IP & Hostname") {
            FieldRow("DHCP virtual IPv4") {
                Toggle("DHCP virtual IPv4", isOn: $config.dhcp)
                    .labelsHidden()
            }
            FieldRow("Virtual IPv4") {
                HStack(spacing: 10) {
                    TextField("10.144.144.10", text: $config.virtual_ipv4)
                        .textFieldStyle(.glassField)
                        .frame(minWidth: ConfigControlMetrics.addressFieldMinWidth)
                        .disabled(config.dhcp)
                    Stepper("/\(config.network_length)", value: $config.network_length, in: 1...32)
                        .monospacedDigit()
                        .frame(minWidth: ConfigControlMetrics.stepperWidth, alignment: .leading)
                        .disabled(config.dhcp)
                }
            }
            FieldRow("Hostname") {
                TextField(NetworkConfig.defaultHostname, text: Binding($config.hostname, replacingNilWith: ""))
                    .textFieldStyle(.glassField)
            }
            magicDNSRow
            FieldRow("Device name") {
                TextField("Auto", text: $config.dev_name)
                    .textFieldStyle(.glassField)
            }
            FieldRow("MTU") {
                TextField(String(NetworkConfig.defaultMTU), text: Binding($config.mtu))
                    .textFieldStyle(.glassField)
            }
            FieldRow("Recv limit") {
                TextField("Unlimited bytes/s", text: Binding($config.instance_recv_bps_limit))
                    .textFieldStyle(.glassField)
            }
        }

        CardSection("Routing & Portal") {
            ExpandableSettingsGroup("Network routing") {
                VStack(alignment: .leading, spacing: 12) {
                    StringListEditor(
                        title: "Listeners",
                        placeholder: "tcp://0.0.0.0:11010",
                        values: $config.listener_urls,
                        defaultNewValue: ListenerURLDefaults.next
                    )
                    StringListEditor(
                        title: "Proxy CIDRs",
                        placeholder: "10.0.0.0/24",
                        values: $config.proxy_cidrs,
                        defaultNewValue: { HostProxyCIDR.first(excluding: $0) }
                    )
                    Toggle("Manual routes", isOn: $config.enable_manual_routes)
                    StringListEditor(title: "Routes", placeholder: "192.168.0.0/16", values: $config.routes)
                        .disabled(!config.enable_manual_routes)
                    StringListEditor(title: "Exit nodes", placeholder: "10.144.144.1", values: $config.exit_nodes)
                    StringListEditor(title: "Mapped listeners", placeholder: "tcp://0.0.0.0:8080", values: $config.mapped_listeners)
                    Toggle("Relay whitelist", isOn: optionalBool($config.enable_relay_network_whitelist, defaultValue: false))
                    StringListEditor(title: "Allowed networks", placeholder: "*", values: $config.relay_network_whitelist)
                        .disabled(config.enable_relay_network_whitelist != true)
                }
            }

            Divider()

            ExpandableSettingsGroup("SOCKS5 and VPN portal") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable SOCKS5", isOn: optionalBool($config.enable_socks5, defaultValue: false))
                    FieldRow("SOCKS5 port") {
                        TextField("1080", value: $config.socks5_port, format: .number)
                            .textFieldStyle(.glassField)
                            .monospacedDigit()
                            .frame(width: ConfigControlMetrics.portFieldWidth, alignment: .leading)
                            .disabled(config.enable_socks5 != true)
                    }
                    Toggle("VPN portal", isOn: $config.enable_vpn_portal)
                    FieldRow("VPN portal port") {
                        TextField("22022", value: $config.vpn_portal_listen_port, format: .number)
                            .textFieldStyle(.glassField)
                            .monospacedDigit()
                            .frame(width: ConfigControlMetrics.portFieldWidth, alignment: .leading)
                            .disabled(!config.enable_vpn_portal)
                    }
                    FieldRow("VPN client network") {
                        TextField("10.0.0.0", text: $config.vpn_portal_client_network_addr)
                            .textFieldStyle(.glassField)
                            .frame(minWidth: ConfigControlMetrics.addressFieldMinWidth)
                            .disabled(!config.enable_vpn_portal)
                    }
                    FieldRow("VPN client prefix") {
                        Stepper("/\(config.vpn_portal_client_network_len)", value: $config.vpn_portal_client_network_len, in: 1...32)
                            .monospacedDigit()
                            .frame(minWidth: ConfigControlMetrics.stepperWidth, alignment: .leading)
                            .disabled(!config.enable_vpn_portal)
                    }
                }
            }
        }

        CardSection("Flags") {
            VStack(spacing: 8) {
                FlagGroup("Core", systemImage: "cube") {
                    FlagList {
                        FlagToggle("Latency first", isOn: $config.latency_first)
                        FlagToggle("Multi thread", isOn: optionalBool($config.multi_thread, defaultValue: true))
                        FlagToggle("No TUN", isOn: optionalBool($config.no_tun, defaultValue: false), help: "Off uses TUN and needs helper/root permission.")
                        FlagToggle("Bind device", isOn: optionalBool($config.bind_device, defaultValue: true), showsSeparator: false)
                    }
                }

                FlagGroup("Transport", systemImage: "network") {
                    FlagList {
                        FlagToggle("Use smoltcp", isOn: optionalBool($config.use_smoltcp, defaultValue: false))
                        FlagToggle("Auto public IPv6", isOn: optionalBool($config.ipv6_public_addr_auto, defaultValue: false))
                        FlagToggle("KCP proxy", isOn: optionalBool($config.enable_kcp_proxy, defaultValue: false))
                        FlagToggle("Disable KCP input", isOn: optionalBool($config.disable_kcp_input, defaultValue: false))
                        FlagToggle("QUIC proxy", isOn: optionalBool($config.enable_quic_proxy, defaultValue: false))
                        FlagToggle("Disable QUIC input", isOn: optionalBool($config.disable_quic_input, defaultValue: false), showsSeparator: false)
                    }
                }

                FlagGroup("P2P & NAT", systemImage: "arrow.triangle.merge") {
                    FlagList {
                        FlagToggle("Disable P2P", isOn: optionalBool($config.disable_p2p, defaultValue: false))
                        FlagToggle("P2P only", isOn: optionalBool($config.p2p_only, defaultValue: false))
                        FlagToggle("Lazy P2P", isOn: optionalBool($config.lazy_p2p, defaultValue: false))
                        FlagToggle("Need P2P", isOn: optionalBool($config.need_p2p, defaultValue: false))
                        FlagToggle("Disable TCP punching", isOn: optionalBool($config.disable_tcp_hole_punching, defaultValue: false))
                        FlagToggle("Disable UDP punching", isOn: optionalBool($config.disable_udp_hole_punching, defaultValue: false))
                        FlagToggle("Disable sym punching", isOn: optionalBool($config.disable_sym_hole_punching, defaultValue: false))
                        FlagToggle("Disable UPnP", isOn: optionalBool($config.disable_upnp, defaultValue: false), showsSeparator: false)
                    }
                }

                FlagGroup("Routing", systemImage: "route") {
                    FlagList {
                        FlagToggle("Enable exit node", isOn: optionalBool($config.enable_exit_node, defaultValue: false))
                        FlagToggle("Relay all peer RPC", isOn: optionalBool($config.relay_all_peer_rpc, defaultValue: false))
                        FlagToggle("System forward", isOn: optionalBool($config.proxy_forward_by_system, defaultValue: false))
                        FlagToggle("UDP broadcast relay", isOn: optionalBool($config.enable_udp_broadcast_relay, defaultValue: false), showsSeparator: false)
                    }
                }

                FlagGroup("Security & DNS", systemImage: "lock.shield") {
                    FlagList {
                        FlagToggle("Private mode", isOn: optionalBool($config.enable_private_mode, defaultValue: false))
                        FlagToggle("Disable IPv6", isOn: optionalBool($config.disable_ipv6, defaultValue: false))
                        FlagToggle("Disable encryption", isOn: optionalBool($config.disable_encryption, defaultValue: false), showsSeparator: false)
                    }
                }
            }
            .padding(.bottom, 2)
        }

        CardSection("Port Forwarding") {
            PortForwardEditor(
                portForwards: $config.port_forwards,
                members: members,
                reverseStatus: reversePortForwardStatus,
                reversePending: reversePortForwardPending,
                allowsReverse: !isRemote,
                onToggleReverse: { rule in
                    Task { await toggleReverse(for: rule) }
                }
            )
        }
    }

    @ViewBuilder
    private var magicDNSRow: some View {
        FieldRow("Magic DNS") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Magic DNS", isOn: optionalBool($config.enable_magic_dns, defaultValue: false))
                    .labelsHidden()
                if config.enable_magic_dns == true {
                    HStack(spacing: 8) {
                        Text(magicDNSPreview)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !isRemote {
                            Button("Change in Settings") {
                                EasyTierSettingsTabRequest.set(.easyTier)
                                openWindow(id: EasyTierWindowID.settings)
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var magicDNSPreview: String {
        let hostname = config.hostname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isRemote {
            return hostname.isEmpty
                ? "Uses the remote runtime hostname and DNS zone"
                : "\(hostname) in the remote runtime's DNS zone"
        }
        guard !hostname.isEmpty else {
            return "Uses this Mac's system hostname at runtime"
        }
        return "\(hostname).\(magicDNSDisplaySuffix)"
    }

    private var magicDNSDisplaySuffix: String {
        let suffix = store.magicDNSSettings.dnsSuffix
        return suffix.hasSuffix(".") ? String(suffix.dropLast()) : suffix
    }

    private typealias RuleKey = String

    private func syncDisplayMode() {
        displayAdvanced = hasActiveAdvancedSettings || config.advanced_settings
    }

    private var hasActiveAdvancedSettings: Bool {
        if !config.dhcp { return true }
        if !config.virtual_ipv4.isEmpty { return true }
        if config.network_length != 24 { return true }
        if config.listener_urls != Self.defaultListenerURLs { return true }
        if !config.dev_name.isEmpty { return true }
        if !config.proxy_cidrs.isEmpty { return true }
        if config.enable_manual_routes || !config.routes.isEmpty { return true }
        if !config.exit_nodes.isEmpty { return true }
        if !config.mapped_listeners.isEmpty { return true }
        if config.enable_vpn_portal { return true }
        if config.enable_socks5 == true { return true }
        if config.latency_first { return true }
        if config.use_smoltcp == true { return true }
        if config.ipv6_public_addr_auto == true { return true }
        if config.enable_kcp_proxy == true { return true }
        if config.disable_kcp_input == true { return true }
        if config.enable_quic_proxy == true { return true }
        if config.disable_quic_input == true { return true }
        if config.disable_p2p == true { return true }
        if config.p2p_only == true { return true }
        if config.lazy_p2p == true { return true }
        if config.no_tun == true { return true }
        if config.multi_thread == false { return true }
        if config.enable_magic_dns == true { return true }
        if config.enable_private_mode == true { return true }
        if config.disable_ipv6 == true { return true }
        if config.bind_device == false { return true }
        if config.disable_encryption == true { return true }
        if config.enable_exit_node == true { return true }
        if config.relay_all_peer_rpc == true { return true }
        if config.need_p2p == true { return true }
        if config.proxy_forward_by_system == true { return true }
        if config.disable_tcp_hole_punching == true { return true }
        if config.disable_udp_hole_punching == true { return true }
        if config.disable_upnp == true { return true }
        if config.enable_udp_broadcast_relay == true { return true }
        if config.disable_sym_hole_punching == true { return true }
        if let mtu = config.mtu, mtu != NetworkConfig.defaultMTU { return true }
        if config.instance_recv_bps_limit != nil { return true }
        if config.enable_relay_network_whitelist == true || !config.relay_network_whitelist.isEmpty { return true }
        if !config.port_forwards.isEmpty { return true }
        return false
    }

    private static let defaultListenerURLs = NetworkConfig().listener_urls

    private var networkNameHasDuplicate: Bool {
        guard !isRemote else { return false }
        let name = config.network_name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return store.configs.contains { other in
            other.id != config.instance_id && other.network_name == name
        }
    }

    private var portForwardKeys: [UUID: RuleKey] {
        Dictionary(uniqueKeysWithValues: config.port_forwards.map { rule in
            (rule.id, "\(rule.bind_ip):\(rule.bind_port)-\(rule.dst_ip):\(rule.dst_port)-\(rule.proto)")
        })
    }

    private var localVirtualIP: String {
        members.first(where: \.isLocal)?.copyableIPv4Address ?? ""
    }

    private func toggleReverse(for rule: PortForwardConfig) async {
        reversePortForwardPending.insert(rule.id)
        defer { reversePortForwardPending.remove(rule.id) }

        let isActive = reversePortForwardStatus[rule.id] == true

        guard !localVirtualIP.isEmpty else {
            store.lastError = "Reverse port forward unavailable: no local virtual IP."
            return
        }

        guard let dstMember = members.first(where: { $0.copyableIPv4Address == rule.dst_ip }) else {
            store.lastError = "Reverse port forward unavailable: no peer at \(rule.dst_ip)."
            return
        }

        guard let remoteInstanceID = dstMember.instanceID else {
            store.lastError = "Reverse port forward unavailable: peer at \(rule.dst_ip) has no instance ID."
            return
        }

        guard let remoteIP = dstMember.copyableIPv4Address,
              let rpcURL = URL(string: "tcp://\(remoteIP):\(AppMode.defaultRPCListenPort)")
        else {
            store.lastError = "Reverse port forward unavailable: cannot build RPC URL for \(rule.dst_ip)."
            return
        }

        let reverseRule = PortForwardConfig(
            bind_ip: rule.bind_ip,
            bind_port: rule.bind_port,
            dst_ip: localVirtualIP,
            dst_port: rule.bind_port,
            proto: rule.proto
        )

        do {
            let rpcClient = EasyTierRemoteRPCClient(rpcURL: rpcURL)
            if isActive {
                try await rpcClient.patchPortForwardRemove(
                    instanceID: remoteInstanceID,
                    portForward: reverseRule
                )
            } else {
                try await rpcClient.patchPortForwards(
                    instanceID: remoteInstanceID,
                    portForwards: [reverseRule]
                )
            }

            let remoteList = try await rpcClient.listPortForwardsParsed(instanceID: remoteInstanceID)
            let found = remoteList.contains { existing in
                existing.bind_ip == reverseRule.bind_ip
                    && existing.bind_port == reverseRule.bind_port
                    && existing.dst_ip == reverseRule.dst_ip
                    && existing.dst_port == reverseRule.dst_port
                    && existing.proto == reverseRule.proto
            }
            let success = isActive ? !found : found
            reversePortForwardStatus[rule.id] = found
            let fp = EasyTierAppStore.portForwardFingerprint(for: rule)
            if found {
                store.reversedPortForwardFingerprints[config.instance_id, default: []].insert(fp)
            } else {
                store.reversedPortForwardFingerprints[config.instance_id]?.remove(fp)
                if store.reversedPortForwardFingerprints[config.instance_id]?.isEmpty == true {
                    store.reversedPortForwardFingerprints.removeValue(forKey: config.instance_id)
                }
            }
            if success {
                store.recordNotice(found
                    ? "Reverse OK: \(rule.bind_ip):\(rule.bind_port) on \(rule.dst_ip)"
                    : "Reverse removed on \(rule.dst_ip)")
            } else {
                store.lastError = found
                    ? "Reverse remove failed: rule still present on \(rule.dst_ip)."
                    : "Reverse add failed: rule not found on \(rule.dst_ip)."
            }
        } catch {
            store.lastError = "Reverse port forward failed: \(error.localizedDescription)"
        }
    }

    private func refreshReverseStatus() async {
        guard !members.isEmpty, !localVirtualIP.isEmpty else { return }

        for rule in config.port_forwards {
            guard let dstMember = members.first(where: { $0.copyableIPv4Address == rule.dst_ip }),
                  let remoteInstanceID = dstMember.instanceID,
                  let remoteIP = dstMember.copyableIPv4Address,
                  let rpcURL = URL(string: "tcp://\(remoteIP):\(AppMode.defaultRPCListenPort)")
            else { continue }

            let expectedReverse = PortForwardConfig(
                bind_ip: rule.bind_ip,
                bind_port: rule.bind_port,
                dst_ip: localVirtualIP,
                dst_port: rule.bind_port,
                proto: rule.proto
            )

            do {
                let remotePortForwards = try await EasyTierRemoteRPCClient(rpcURL: rpcURL)
                    .listPortForwardsParsed(instanceID: remoteInstanceID)
                let isActive = remotePortForwards.contains { existing in
                    existing.bind_ip == expectedReverse.bind_ip
                        && existing.bind_port == expectedReverse.bind_port
                        && existing.dst_ip == expectedReverse.dst_ip
                        && existing.dst_port == expectedReverse.dst_port
                        && existing.proto == expectedReverse.proto
                }
                reversePortForwardStatus[rule.id] = isActive
                let fp = EasyTierAppStore.portForwardFingerprint(for: rule)
                if isActive {
                    store.reversedPortForwardFingerprints[config.instance_id, default: []].insert(fp)
                } else {
                    store.reversedPortForwardFingerprints[config.instance_id]?.remove(fp)
                    if store.reversedPortForwardFingerprints[config.instance_id]?.isEmpty == true {
                        store.reversedPortForwardFingerprints.removeValue(forKey: config.instance_id)
                    }
                }
            } catch {
                reversePortForwardStatus[rule.id] = false
            }
        }
    }

    private func optionalBool(_ binding: Binding<Bool?>, defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue ?? defaultValue },
            set: { binding.wrappedValue = $0 }
        )
    }
}
