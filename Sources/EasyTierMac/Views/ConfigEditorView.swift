import EasyTierShared
import SwiftUI

struct ConfigEditorView: View {
    @Binding var config: NetworkConfig

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                CardSection("Basic") {
                    FieldRow("Network name") {
                        TextField("easytier", text: $config.network_name)
                            .textFieldStyle(.roundedBorder)
                    }
                    FieldRow("Network secret") {
                        SecureField("Optional shared secret", text: Binding($config.network_secret, replacingNilWith: ""))
                            .textFieldStyle(.roundedBorder)
                    }
                    FieldRow("DHCP virtual IPv4") {
                        Toggle("", isOn: $config.dhcp)
                            .labelsHidden()
                    }
                    FieldRow("Virtual IPv4") {
                        HStack(spacing: 10) {
                            TextField("10.144.144.10", text: $config.virtual_ipv4)
                                .textFieldStyle(.roundedBorder)
                                .disabled(config.dhcp)
                            Stepper("/\(config.network_length)", value: $config.network_length, in: 1...32)
                                .frame(width: 110)
                                .disabled(config.dhcp)
                        }
                    }
                    FieldRow("Hostname") {
                        TextField("Optional hostname", text: Binding($config.hostname, replacingNilWith: ""))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                CardSection("Peers") {
                    StringListEditor(title: "Initial nodes", placeholder: "tcp://host:11010", values: $config.peer_urls)
                }

                CardSection("Advanced") {
                    ExpandableSettingsGroup("Network routing") {
                        VStack(alignment: .leading, spacing: 12) {
                            StringListEditor(title: "Listeners", placeholder: "tcp://0.0.0.0:11010", values: $config.listener_urls)
                            StringListEditor(title: "Proxy CIDRs", placeholder: "10.0.0.0/24", values: $config.proxy_cidrs)
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
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(config.enable_socks5 != true)
                            }
                            Toggle("VPN portal", isOn: $config.enable_vpn_portal)
                            FieldRow("VPN portal port") {
                                TextField("22022", value: $config.vpn_portal_listen_port, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(!config.enable_vpn_portal)
                            }
                            FieldRow("VPN client network") {
                                TextField("10.0.0.0", text: $config.vpn_portal_client_network_addr)
                                    .textFieldStyle(.roundedBorder)
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
                    PortForwardEditor(portForwards: $config.port_forwards)
                }
            }
            .padding(18)
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
                withAnimation(.easeInOut(duration: 0.16)) {
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.primary.opacity(0.045), lineWidth: 1)
            }
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

private struct StringListEditor: View {
    var title: String
    var placeholder: String
    @Binding var values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                Spacer()
                Button { values.append("") } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
            }
            ForEach(values.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField(placeholder, text: Binding(
                        get: { values[index] },
                        set: { values[index] = $0 }
                    ))
                    Button(role: .destructive) { values.remove(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct PortForwardEditor: View {
    @Binding var portForwards: [PortForwardConfig]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rules")
                    .font(.system(size: 13.5, weight: .medium))
                Spacer()
                Button { portForwards.append(PortForwardConfig()) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
            }

            ForEach($portForwards) { $rule in
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Picker("Proto", selection: $rule.proto) {
                            Text("tcp").tag("tcp")
                            Text("udp").tag("udp")
                        }
                        .labelsHidden()
                        TextField("Bind IP", text: $rule.bind_ip)
                        TextField("Bind port", value: $rule.bind_port, format: .number)
                            .frame(width: 90)
                        Text("->")
                            .foregroundStyle(.secondary)
                        TextField("Destination IP", text: $rule.dst_ip)
                        TextField("Port", value: $rule.dst_port, format: .number)
                            .frame(width: 90)
                        Button(role: .destructive) {
                            portForwards.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
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
