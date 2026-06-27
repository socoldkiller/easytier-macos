import EasyTierShared
import SwiftUI

struct ConfigEditorView: View {
    @Environment(EasyTierAppStore.self) private var store
    @Binding var config: NetworkConfig
    var members: [NetworkMemberStatus] = []
    @State private var reversePortForwardStatus: [UUID: Bool] = [:]
    @State private var reversePortForwardPending: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                CardSection("Basic") {
                    FieldRow("Network name") {
                        TextField("easytier", text: $config.network_name)
                            .textFieldStyle(.glassField)
                    }
                    FieldRow("Network secret") {
                        NetworkSecretField(config: $config)
                    }
                    FieldRow("DHCP virtual IPv4") {
                        Toggle("", isOn: $config.dhcp)
                            .labelsHidden()
                    }
                    FieldRow("Virtual IPv4") {
                        HStack(spacing: 10) {
                            TextField("10.144.144.10", text: $config.virtual_ipv4)
                                .textFieldStyle(.glassField)
                                .disabled(config.dhcp)
                            Stepper("/\(config.network_length)", value: $config.network_length, in: 1...32)
                                .frame(width: 110)
                                .disabled(config.dhcp)
                        }
                    }
                    FieldRow("Hostname") {
                        TextField("Optional hostname", text: Binding($config.hostname, replacingNilWith: ""))
                            .textFieldStyle(.glassField)
                    }
                }

                CardSection("Peers") {
                    StringListEditor(title: "Initial nodes", placeholder: "tcp://host:11010", values: $config.peer_urls)
                }

                CardSection("Advanced") {
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
                        }
                    }

                    Divider()

                    ExpandableSettingsGroup("SOCKS5 and VPN portal") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Enable SOCKS5", isOn: optionalBool($config.enable_socks5, defaultValue: false))
                            FieldRow("SOCKS5 port") {
                                TextField("1080", value: $config.socks5_port, format: .number)
                                    .textFieldStyle(.glassField)
                                    .disabled(config.enable_socks5 != true)
                            }
                            Toggle("VPN portal", isOn: $config.enable_vpn_portal)
                            FieldRow("VPN portal port") {
                                TextField("22022", value: $config.vpn_portal_listen_port, format: .number)
                                    .textFieldStyle(.glassField)
                                    .disabled(!config.enable_vpn_portal)
                            }
                            FieldRow("VPN client network") {
                                TextField("10.0.0.0", text: $config.vpn_portal_client_network_addr)
                                    .textFieldStyle(.glassField)
                                    .disabled(!config.enable_vpn_portal)
                            }
                            FieldRow("VPN client prefix") {
                                Stepper("/\(config.vpn_portal_client_network_len)", value: $config.vpn_portal_client_network_len, in: 1...32)
                                    .disabled(!config.enable_vpn_portal)
                            }
                        }
                    }
                }

                CardSection("Flags") {
                    Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 9) {
                        GridRow {
                            Toggle("Latency first", isOn: $config.latency_first)
                            Toggle("Disable P2P", isOn: optionalBool($config.disable_p2p, defaultValue: false))
                        }
                        GridRow {
                            Toggle("No TUN", isOn: optionalBool($config.no_tun, defaultValue: false))
                            Toggle("Multi thread", isOn: optionalBool($config.multi_thread, defaultValue: true))
                        }
                        GridRow {
                            Toggle("Magic DNS", isOn: optionalBool($config.enable_magic_dns, defaultValue: false))
                            Toggle("Private mode", isOn: optionalBool($config.enable_private_mode, defaultValue: false))
                        }
                        GridRow {
                            Toggle("Disable IPv6", isOn: optionalBool($config.disable_ipv6, defaultValue: false))
                            Toggle("Bind device", isOn: optionalBool($config.bind_device, defaultValue: true))
                        }
                        GridRow {
                            Toggle("Disable encryption", isOn: optionalBool($config.disable_encryption, defaultValue: false))
                            Toggle("Enable exit node", isOn: optionalBool($config.enable_exit_node, defaultValue: false))
                        }
                    }
                }

                CardSection("Port Forwarding") {
                    PortForwardEditor(
                        portForwards: $config.port_forwards,
                        members: members,
                        reverseStatus: reversePortForwardStatus,
                        reversePending: reversePortForwardPending,
                        onToggleReverse: { rule in
                            Task { await toggleReverse(for: rule) }
                        }
                    )
                }
            }
            .padding(18)
        }
        .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
        .textFieldStyle(.glassField)
        .onAppear {
            Task { await refreshReverseStatus() }
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

    private typealias RuleKey = String

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
            if isActive {
                try await EasyTierRemoteRPCClient.patchPortForwardRemove(
                    rpcURL: rpcURL,
                    instanceID: remoteInstanceID,
                    portForward: reverseRule
                )
            } else {
                try await EasyTierRemoteRPCClient.patchPortForwards(
                    rpcURL: rpcURL,
                    instanceID: remoteInstanceID,
                    portForwards: [reverseRule]
                )
            }

            let remoteList = try await EasyTierRemoteRPCClient.listPortForwardsParsed(
                rpcURL: rpcURL,
                instanceID: remoteInstanceID
            )
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
                let remotePortForwards = try await EasyTierRemoteRPCClient.listPortForwardsParsed(
                    rpcURL: rpcURL,
                    instanceID: remoteInstanceID
                )
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

private struct ExpandableSettingsGroup<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    @ViewBuilder var content: Content
    @State private var isExpanded = false

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 12)
                }
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 8))
            }
        }
    }
}

private struct CardSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct FieldRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 152, alignment: .leading)
            content
                .frame(maxWidth: 520, alignment: .leading)
        }
    }
}

private struct NetworkSecretField: View {
    @Environment(EasyTierAppStore.self) private var store
    @Binding var config: NetworkConfig
    @State private var isRevealed = false
    @State private var autofillAttemptedForInstanceID: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            secretInput
                .textFieldStyle(.glassField)
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    guard focused else { return }
                    autofillIfAvailable()
                }

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(isRevealed ? "Hide secret" : "Show secret")
            .accessibilityLabel(Text(isRevealed ? "Hide secret" : "Show secret"))

            Button {
                fillFromKeychain()
            } label: {
                Image(systemName: "key.fill")
            }
            .buttonStyle(.borderless)
            .help("Fill from Keychain")
            .accessibilityLabel(Text("Fill from Keychain"))
        }
    }

    @ViewBuilder
    private var secretInput: some View {
        if isRevealed {
            TextField("Optional shared secret", text: Binding($config.network_secret, replacingNilWith: ""))
        } else {
            SecureField("Optional shared secret", text: Binding($config.network_secret, replacingNilWith: ""))
        }
    }

    private func autofillIfAvailable() {
        guard config.network_secret?.nilIfEmpty == nil else { return }
        guard autofillAttemptedForInstanceID != config.instance_id else { return }
        guard store.networkSecretCanAutofill(for: config) else { return }
        autofillAttemptedForInstanceID = config.instance_id
        guard let secret = store.autofillNetworkSecret(for: config) else { return }
        config.network_secret = secret
    }

    private func fillFromKeychain() {
        do {
            guard let secret = try store.revealNetworkSecret(for: config) else { return }
            config.network_secret = secret
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

private struct StringListEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    var placeholder: String
    @Binding var values: [String]
    var defaultNewValue: ([String]) -> String = { _ in "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                Spacer()
                Button {
                    withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
                        values.append(defaultNewValue(values))
                    }
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
            }
            ForEach(values.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField(placeholder, text: Binding(
                        get: { values.indices.contains(index) ? values[index] : "" },
                        set: { newValue in
                            guard values.indices.contains(index) else { return }
                            values[index] = newValue
                        }
                    ))
                    Button(role: .destructive) {
                        guard values.indices.contains(index) else { return }
                        _ = withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
                            values.remove(at: index)
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 6))
            }
        }
        .padding(.vertical, 3)
        .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: values.count)
    }
}

private struct PortForwardEditor: View {
    @Binding var portForwards: [PortForwardConfig]
    var members: [NetworkMemberStatus]
    var reverseStatus: [UUID: Bool] = [:]
    var reversePending: Set<UUID> = []
    var onToggleReverse: (PortForwardConfig) -> Void = { _ in }

    private var reversedRules: [PortForwardConfig] {
        portForwards.filter { reverseStatus[$0.id] == true }
    }

    private func reverseAvailable(for rule: PortForwardConfig) -> (available: Bool, reason: String?) {
        let localIP = members.first(where: \.isLocal)?.copyableIPv4Address
        guard localIP?.isEmpty == false else { return (false, "No local IP") }
        guard let dstMember = members.first(where: { $0.copyableIPv4Address == rule.dst_ip })
        else { return (false, "Peer \(rule.dst_ip) not in network") }
        guard dstMember.instanceID != nil else { return (false, "Peer has no instance ID") }
        guard dstMember.copyableIPv4Address != nil else { return (false, "Peer has no IP") }
        return (true, nil)
    }

    private var destinationOptions: [PortForwardDestinationOption] {
        var seenAddresses = Set<String>()
        return members.compactMap { member in
            guard let address = member.copyableIPv4Address, seenAddresses.insert(address).inserted else { return nil }
            return PortForwardDestinationOption(member: member, address: address)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rules")
                    .font(.system(size: 13.5, weight: .medium))
                Spacer()
                Button {
                    portForwards.append(PortForwardConfig())
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
            }

            ForEach($portForwards) { $rule in
                let isReversed = reverseStatus[$rule.wrappedValue.id] == true
                if !isReversed {
                    editableRow(ruleBinding: $rule)
                }
            }

            if !reversedRules.isEmpty {
                Text("Reversed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.top, 4)
                ForEach(reversedRules) { rule in
                    readonlyRow(for: rule)
                }
            }
        }
    }

    @ViewBuilder
    private func editableRow(ruleBinding: Binding<PortForwardConfig>) -> some View {
        let rule = ruleBinding.wrappedValue
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Picker("Proto", selection: ruleBinding.proto) {
                    Text("tcp").tag("tcp")
                    Text("udp").tag("udp")
                }
                .labelsHidden()
                PortForwardBindField(address: ruleBinding.bind_ip)
                TextField("Bind port", value: ruleBinding.bind_port, format: .number)
                    .frame(width: 90)
                Text("->")
                    .foregroundStyle(.secondary)
                PortForwardDestinationField(address: ruleBinding.dst_ip, options: destinationOptions)
                TextField("Port", value: ruleBinding.dst_port, format: .number)
                    .frame(width: 90)
                reverseButton(for: rule)
                Button(role: .destructive) {
                    portForwards.removeAll { $0.id == rule.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func readonlyRow(for rule: PortForwardConfig) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text(rule.proto).font(.system(size: 13.5)).foregroundStyle(.secondary)
                Text(rule.bind_ip).font(.system(size: 13.5)).foregroundStyle(.secondary)
                Text("\(rule.bind_port)").font(.system(size: 13.5)).foregroundStyle(.secondary)
                Text("->").foregroundStyle(.secondary)
                Text(rule.dst_ip).font(.system(size: 13.5)).foregroundStyle(.secondary)
                Text("\(rule.dst_port)").font(.system(size: 13.5)).foregroundStyle(.secondary)
                reverseButton(for: rule)
                Button(role: .destructive) {
                    portForwards.removeAll { $0.id == rule.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func reverseButton(for rule: PortForwardConfig) -> some View {
        let isActive = reverseStatus[rule.id] == true
        let isPending = reversePending.contains(rule.id)
        let availability = reverseAvailable(for: rule)

        Button {
            onToggleReverse(rule)
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? .green : .secondary)
                .opacity(isPending ? 0.4 : (availability.available ? 1.0 : 0.28))
        }
        .buttonStyle(.borderless)
        .disabled(isPending || !availability.available)
        .help(reverseHelpText(isActive: isActive, isPending: isPending, availability: availability, dstIP: rule.dst_ip))
    }

    private func reverseHelpText(isActive: Bool, isPending: Bool, availability: (available: Bool, reason: String?), dstIP: String) -> String {
        if isPending { return "Sending reverse port forward..." }
        if isActive { return "Reverse is active on remote peer — click to remove" }
        if !availability.available, let reason = availability.reason { return "Reverse unavailable: \(reason)" }
        return "Send reverse port forward to peer at \(dstIP)"
    }
}

private struct PortForwardBindField: View {
    @Binding var address: String

    private let options = [
        PortForwardBindOption(address: "127.0.0.1", title: "Localhost", systemImage: "desktopcomputer"),
        PortForwardBindOption(address: "0.0.0.0", title: "All interfaces", systemImage: "network"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            TextField("Bind IP", text: $address)

            Menu {
                ForEach(options) { option in
                    Button {
                        address = option.address
                    } label: {
                        Label(option.menuTitle, systemImage: option.systemImage)
                    }
                }
            } label: {
                Image(systemName: "scope")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a common bind address")
        }
    }
}

private struct PortForwardBindOption: Identifiable, Equatable {
    var address: String
    var title: String
    var systemImage: String

    var id: String { address }
    var menuTitle: String { "\(title) - \(address)" }
}

private struct PortForwardDestinationField: View {
    @Binding var address: String
    var options: [PortForwardDestinationOption]

    var body: some View {
        HStack(spacing: 6) {
            TextField("Destination IP", text: $address)

            if !options.isEmpty {
                Menu {
                    ForEach(options) { option in
                        Button {
                            address = option.address
                        } label: {
                            Label(option.menuTitle, systemImage: option.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "person.2")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose from current network members")
            }
        }
    }
}

private struct PortForwardDestinationOption: Identifiable, Equatable {
    var member: NetworkMemberStatus
    var address: String

    var id: String { address }

    var menuTitle: String {
        let hostname = member.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty, hostname != "-" else { return address }
        return "\(hostname) - \(address)"
    }

    var systemImage: String {
        member.isLocal ? "desktopcomputer" : "network"
    }
}

private extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith fallback: String) {
        self.init(
            get: { source.wrappedValue ?? fallback },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
