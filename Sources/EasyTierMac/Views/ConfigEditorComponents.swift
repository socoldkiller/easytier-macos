import EasyTierShared
import SwiftUI

enum ConfigControlMetrics {
    static let addressFieldMinWidth: CGFloat = 150
    static let secretFieldMinWidth: CGFloat = 220
    static let portFieldWidth: CGFloat = 104
    static let stepperWidth: CGFloat = 132
}

struct ConfigEditorScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct FlagGroup<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.72))
                    .frame(width: 14, alignment: .center)
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

struct FlagList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FlagRowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, 30)
    }
}

struct FlagToggle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    @Binding var isOn: Bool
    var help: String?
    var showsSeparator: Bool = true

    init(_ title: String, isOn: Binding<Bool>, help: String? = nil, showsSeparator: Bool = true) {
        self.title = title
        self._isOn = isOn
        self.help = help
        self.showsSeparator = showsSeparator
    }

    var body: some View {
        VStack(spacing: 0) {
            Toggle(isOn: animatedBinding) {
                HStack(spacing: 9) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.body.weight(isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 16, alignment: .center)
                        .accessibilityHidden(true)

                    Text(title)
                        .font(.body.weight(isOn ? .medium : .regular))
                        .foregroundStyle(isOn ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .help(help ?? title)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(isOn ? "On" : "Off"))

            if showsSeparator {
                FlagRowSeparator()
            }
        }
    }

    private var animatedBinding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { newValue in
                withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
                    isOn = newValue
                }
            }
        )
    }
}

struct NetworkSecretField: View {
    @Environment(EasyTierAppStore.self) private var store
    @Binding var config: NetworkConfig
    @State private var isRevealed = false
    @State private var autofillAttemptedForInstanceID: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            secretInput
                .textFieldStyle(.glassField)
                .frame(minWidth: ConfigControlMetrics.secretFieldMinWidth, maxWidth: .infinity)
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
        autofillAttemptedForInstanceID = config.instance_id
        Task {
            guard await store.networkSecretCanAutofill(for: config) else { return }
            guard let secret = await store.autofillNetworkSecret(for: config) else { return }
            config.network_secret = secret
        }
    }

    private func fillFromKeychain() {
        Task {
            do {
                guard let secret = try await store.revealNetworkSecret(for: config) else { return }
                config.network_secret = secret
            } catch {
                store.lastError = error.localizedDescription
            }
        }
    }
}

struct StringListEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    var placeholder: String
    @Binding var values: [String]
    var defaultNewValue: ([String]) -> String = { _ in "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.body.weight(.medium))
                Spacer()
                Button {
                    withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
                        values.append(defaultNewValue(values))
                    }
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Add \(title)"))
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
                    .accessibilityLabel(Text("Remove entry \(index + 1)"))
                }
                .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 6))
            }
        }
        .padding(.vertical, 3)
        .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: values.count)
    }
}

struct PortForwardEditor: View {
    @Binding var portForwards: [PortForwardConfig]
    var members: [NetworkMemberStatus]
    var reverseStatus: [UUID: Bool] = [:]
    var reversePending: Set<UUID> = []
    var allowsReverse: Bool = true
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
                .font(.body.weight(.medium))
                Spacer()
                Button {
                    portForwards.append(PortForwardConfig())
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Add port forwarding rule"))
            }

            ForEach($portForwards) { $rule in
                let isReversed = reverseStatus[$rule.wrappedValue.id] == true
                if !isReversed {
                    editableRow(ruleBinding: $rule)
                }
            }

            if !reversedRules.isEmpty {
                Text("Reversed")
                    .font(.caption.weight(.medium))
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
                Picker("Protocol", selection: ruleBinding.proto) {
                    Text("tcp").tag("tcp")
                    Text("udp").tag("udp")
                }
                .labelsHidden()
                PortForwardBindField(address: ruleBinding.bind_ip)
                TextField("Bind port", value: ruleBinding.bind_port, format: .number)
                    .monospacedDigit()
                    .frame(width: ConfigControlMetrics.portFieldWidth, alignment: .leading)
                Text("->")
                    .foregroundStyle(.secondary)
                PortForwardDestinationField(address: ruleBinding.dst_ip, options: destinationOptions)
                TextField("Port", value: ruleBinding.dst_port, format: .number)
                    .monospacedDigit()
                    .frame(width: ConfigControlMetrics.portFieldWidth, alignment: .leading)
                if allowsReverse { reverseButton(for: rule) }
                Button(role: .destructive) {
                    portForwards.removeAll { $0.id == rule.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Remove port forwarding rule"))
            }
        }
    }

    @ViewBuilder
    private func readonlyRow(for rule: PortForwardConfig) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text(rule.proto).font(.body).foregroundStyle(.secondary)
                Text(rule.bind_ip).font(.body).foregroundStyle(.secondary)
                Text("\(rule.bind_port)").font(.body).foregroundStyle(.secondary)
                Text("->").foregroundStyle(.secondary)
                Text(rule.dst_ip).font(.body).foregroundStyle(.secondary)
                Text("\(rule.dst_port)").font(.body).foregroundStyle(.secondary)
                if allowsReverse { reverseButton(for: rule) }
                Button(role: .destructive) {
                    portForwards.removeAll { $0.id == rule.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Remove port forwarding rule"))
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
                .font(.caption.weight(isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? .green : .secondary)
                .opacity(isPending ? 0.4 : (availability.available ? 1.0 : 0.28))
        }
        .buttonStyle(.borderless)
        .disabled(isPending || !availability.available)
        .help(reverseHelpText(isActive: isActive, isPending: isPending, availability: availability, dstIP: rule.dst_ip))
        .accessibilityLabel(Text("Reverse port forward"))
        .accessibilityValue(Text(isActive ? "Active" : "Inactive"))
        .accessibilityHint(Text(reverseAccessibilityHint(isActive: isActive, isPending: isPending, availability: availability, dstIP: rule.dst_ip)))
    }

    private func reverseHelpText(isActive: Bool, isPending: Bool, availability: (available: Bool, reason: String?), dstIP: String) -> String {
        if isPending { return "Sending reverse port forward..." }
        if isActive { return "Reverse is active on remote peer — click to remove" }
        if !availability.available, let reason = availability.reason { return "Reverse unavailable: \(reason)" }
        return "Send reverse port forward to peer at \(dstIP)"
    }

    private func reverseAccessibilityHint(isActive: Bool, isPending: Bool, availability: (available: Bool, reason: String?), dstIP: String) -> String {
        if isPending { return "Sending reverse port forward." }
        if isActive { return "Removes the reverse rule from the remote peer." }
        if !availability.available, let reason = availability.reason { return "Unavailable: \(reason)." }
        return "Sends a reverse port forward rule to \(dstIP)."
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
                .frame(minWidth: ConfigControlMetrics.addressFieldMinWidth)

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
            .accessibilityLabel(Text("Choose bind address"))
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
                .frame(minWidth: ConfigControlMetrics.addressFieldMinWidth)

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
                .accessibilityLabel(Text("Choose destination member"))
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

extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith fallback: String) {
        self.init(
            get: { source.wrappedValue ?? fallback },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    init(_ source: Binding<Int?>) {
        self.init(
            get: { source.wrappedValue.map(String.init) ?? "" },
            set: { source.wrappedValue = Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }
}
