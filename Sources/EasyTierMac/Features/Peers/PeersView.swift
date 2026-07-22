import EasyTierShared
import SwiftUI

struct PeersView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppContext.self) private var appContext

    @State private var showingAddSheet = false
    @State private var subscriptionURLText = ""
    @State private var pasteJSONText = ""
    @State private var pasteJSONError: String?
    @State private var inputMode: PeerInputMode = .url
    @State private var transientNotice: PeerNotice?
    @State private var noticeToken = 0
    @State private var appliedCardID: String?
    @State private var appliedState: PeerAppliedState = .none
    @State private var appliedFeedbackToken = 0

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var subscriptions: [PeerSubscription] { store.peerSubscriptions }

    private var allCards: [(subscription: PeerSubscription, card: PeerCard)] {
        subscriptions.flatMap { sub in sub.cards.map { (sub, $0) } }
    }

    var body: some View {
        let cards = allCards

        GeometryReader { proxy in
            ScrollView {
                if cards.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(cards, id: \.card.id) { entry in
                            PeerCardView(
                                subscription: entry.subscription,
                                card: entry.card,
                                latencyMs: store.peerCardLatency(for: entry.card),
                                targetNetworkName: store.selectedConfig?.network_name,
                                appliedState: appliedCardID == entry.card.id ? appliedState : .none,
                                onAddToCurrentConfig: { addToCurrentConfig(entry.card) }
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .hideScrollViewScrollers()
        .easyTierSafeAreaBar(edge: .top, spacing: 0) {
            peerActionBar
        }
        .overlay(alignment: .top) {
            if let notice = transientNotice {
                PeerNoticeBanner(text: notice.text, severity: notice.severity)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 44)
            }
        }
        .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: cards.count)
        .sheet(isPresented: $showingAddSheet) {
            AddPeerSubscriptionSheet(
                mode: inputMode,
                urlText: $subscriptionURLText,
                jsonText: $pasteJSONText,
                jsonError: $pasteJSONError,
                onCancel: { resetAddSheet() },
                onSubmit: { submitAddSheet() }
            )
        }
        .task {
            if !subscriptions.isEmpty, subscriptions.contains(where: { $0.subscriptionURL != nil }) {
                await store.refreshPeerSubscriptions()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            ContentUnavailableView(
                "No Peer Subscriptions",
                systemImage: "wifi",
                description: Text("Add a subscription URL to import EasyTier node addresses.")
            )
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420, alignment: .center)
            Button("Add Subscription") { inputMode = .url; openAddSheet() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func openAddSheet() {
        pasteJSONError = nil
        showingAddSheet = true
    }

    private func resetAddSheet() {
        showingAddSheet = false
        subscriptionURLText = ""
        pasteJSONText = ""
        pasteJSONError = nil
    }

    private func submitAddSheet() {
        switch inputMode {
        case .url:
            let trimmed = subscriptionURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
                pasteJSONError = "Enter a valid URL."
                return
            }
            resetAddSheet()
            Task {
                await store.addPeerSubscription(url: url)
                showTransientNotice("Fetched subscription from \(url.absoluteString)")
            }

        case .paste:
            let trimmed = pasteJSONText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                pasteJSONError = "Paste subscription JSON first."
                return
            }
            do {
                try store.addPeerSubscription(json: trimmed)
                resetAddSheet()
                showTransientNotice("Added subscription from pasted JSON.")
            } catch {
                pasteJSONError = error.localizedDescription
            }
        }
    }

    private var peerActionBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Menu {
                Button("Add Subscription URL...") { inputMode = .url; openAddSheet() }
                Button("Paste Subscription JSON...") { inputMode = .paste; openAddSheet() }
            } label: {
                Label("Add Subscription", systemImage: "plus")
            }
            .help("Add a node subscription")
            .accessibilityLabel(Text("Add Subscription"))

            Button {
                Task { await store.refreshPeerSubscriptions() }
            } label: {
                Label("Refresh", systemImage: store.isRefreshingPeerSubscriptions ? "hourglass" : "arrow.clockwise")
            }
            .disabled(subscriptions.isEmpty || store.isRefreshingPeerSubscriptions)
            .help("Refresh all subscriptions from their source URLs")
            .accessibilityLabel(Text("Refresh Subscriptions"))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func addToCurrentConfig(_ card: PeerCard) {
        let result = store.previewPeerCardMerge(card)

        let state: PeerAppliedState
        var noticeMessage: String? = nil

        switch result {
        case .added(let count):
            state = .added(count: count)
        case .alreadyPresent:
            state = .alreadyPresent
            noticeMessage = "Already in current network"
        case .noSelectedConfig:
            state = .noSelectedConfig
            noticeMessage = "Select a network config first"
        }

        appliedFeedbackToken += 1
        let token = appliedFeedbackToken

        withAnimation(EasyTierMotion.selection(reduceMotion: reduceMotion)) {
            appliedCardID = card.id
            appliedState = state
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard token == appliedFeedbackToken else { return }
            withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
                appliedCardID = nil
                appliedState = .none
            }
        }

        if case .added = result {
            store.pendingPeerCardMerge = card
        } else if let message = noticeMessage {
            showTransientNotice(message, severity: .warning)
        }
    }

    private func showTransientNotice(_ text: String, severity: PeerNotice.Severity = .info) {
        noticeToken += 1
        let token = noticeToken
        withAnimation(EasyTierMotion.quick(reduceMotion: reduceMotion)) {
            transientNotice = PeerNotice(text: text, severity: severity)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            guard token == noticeToken else { return }
            withAnimation(EasyTierMotion.quick(reduceMotion: reduceMotion)) {
                transientNotice = nil
            }
        }
    }
}

private enum PeerInputMode: Hashable {
    case url
    case paste
}

private enum PeerAppliedState: Equatable {
    case none
    case added(count: Int)
    case alreadyPresent
    case noSelectedConfig
}

private struct PeerNotice: Equatable {
    var text: String
    var severity: Severity

    enum Severity {
        case info, warning
    }
}

private struct AddPeerSubscriptionSheet: View {
    var mode: PeerInputMode
    @Binding var urlText: String
    @Binding var jsonText: String
    @Binding var jsonError: String?
    var onCancel: () -> Void
    var onSubmit: () -> Void

    private let sampleJSON = """
    {
      "outbounds": [
        {
          "type": "quic",
          "tag": "Tokyo",
          "server": "tokyo.example.com",
          "server_port": 11012
        },
        {
          "type": "tcp",
          "tag": "San Francisco",
          "server": "sf.example.com",
          "server_port": 11010
        }
      ]
    }
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Peer Subscription")
                .font(.headline)

            Picker("Input", selection: Binding(get: { mode }, set: { _ in })) {
                Text("Subscription URL").tag(PeerInputMode.url)
                Text("Paste JSON").tag(PeerInputMode.paste)
            }
            .pickerStyle(.segmented)
            .disabled(true)
            .labelsHidden()

            Group {
                switch mode {
                case .url:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Subscription URL")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("https://example.com/subscription.json", text: $urlText)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        Text("The app will fetch subscription JSON from this URL and refresh it on demand.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                case .paste:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Subscription JSON")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $jsonText)
                            .font(.system(.body, design: .monospaced))
                            .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
                            .hideScrollViewScrollers()
                            .frame(minHeight: 160)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                            )
                        Text("Example:\n\(sampleJSON)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }

            if let jsonError {
                Label(jsonError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(mode == .url ? "Fetch" : "Add", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 460)
        .hideScrollViewScrollers()
    }
}

private struct PeerCardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var subscription: PeerSubscription
    var card: PeerCard
    var latencyMs: Int?
    var targetNetworkName: String?
    var appliedState: PeerAppliedState
    var onAddToCurrentConfig: () -> Void

    @State private var isHovering = false
    @State private var showingURLsPopover = false

    var body: some View {
        Button {
            onAddToCurrentConfig()
        } label: {
            cardContent
        }
        .buttonStyle(QuietPressButtonStyle(pressedScale: 0.98, pressedOpacity: 0.88))
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "network")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .symbolRenderingMode(.hierarchical)

                VStack(alignment: .leading, spacing: 1) {
                    Text(card.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(subscription.name != card.name && !subscription.name.isEmpty ? subscription.name : " ")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !card.proto.isEmpty {
                    Text(card.proto.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.secondary.opacity(0.15))
                        )
                }

                feedbackIcon
                    .transition(.scale.combined(with: .opacity))
            }

            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: "link")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(card.urls.count) peer\(card.urls.count == 1 ? "" : "s")")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Divider()
                    .frame(height: 12)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(latencyColor)
                        .symbolRenderingMode(.hierarchical)
                    Text(latencyText)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .contentTransition(.opacity)
                    if latencyMs != nil {
                        Text("ms")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 0)

                if let fetchedAt = subscription.lastFetchedAt {
                    Text(fetchedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !card.urls.isEmpty {
                    Button {
                        showingURLsPopover.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showingURLsPopover, arrowEdge: .bottom) {
                        PeerURLsPopover(urls: card.urls)
                    }
                    .help("Show peer URLs")
                    .highPriorityGesture(DragGesture(minimumDistance: 0))
                }
            }

            Text(card.note?.nilIfEmpty ?? " ")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .frame(height: 100, alignment: .top)
        .liquidGlassMetricBackground(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(feedbackBorderColor, lineWidth: 1)
        )
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(feedbackFillColor)
        )
        .onHover { hovering in
            withAnimation(EasyTierMotion.quick(reduceMotion: reduceMotion)) {
                isHovering = hovering
            }
        }
        .animation(EasyTierMotion.selection(reduceMotion: reduceMotion), value: appliedState)
    }

    @ViewBuilder
    private var feedbackIcon: some View {
        switch appliedState {
        case .none:
            EmptyView()
        case .added:
            Image(systemName: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(EasyTierColors.statusConnected)
                .symbolEffect(.bounce, value: appliedState)
                .transition(.scale.combined(with: .opacity))
        case .alreadyPresent:
            Image(systemName: "checkmark.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .transition(.scale.combined(with: .opacity))
        case .noSelectedConfig:
            Image(systemName: "exclamationmark.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(EasyTierColors.statusConnecting)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var feedbackBorderColor: Color {
        switch appliedState {
        case .none:
            return isHovering ? Color.accentColor.opacity(0.35) : Color.clear
        case .added:
            return EasyTierColors.statusConnected.opacity(0.6)
        case .alreadyPresent:
            return Color.secondary.opacity(0.4)
        case .noSelectedConfig:
            return EasyTierColors.statusConnecting.opacity(0.5)
        }
    }

    private var feedbackFillColor: Color {
        switch appliedState {
        case .added:
            return EasyTierColors.statusConnected.opacity(0.06)
        case .noSelectedConfig:
            return EasyTierColors.statusConnecting.opacity(0.06)
        default:
            return Color.clear
        }
    }

    private var latencyColor: Color {
        guard let latencyMs else { return .secondary }
        if latencyMs < 50 { return EasyTierColors.statusConnected }
        if latencyMs < 150 { return EasyTierColors.statusConnecting }
        return EasyTierColors.statusError
    }

    private var latencyText: String {
        guard let latencyMs else { return "—" }
        return "\(latencyMs)"
    }

    private var helpText: String {
        if let targetNetworkName {
            return "Add \(card.urls.count) peer URL(s) from \(card.name) to \(targetNetworkName)"
        }
        return "Add \(card.urls.count) peer URL(s) from \(card.name) to the current network"
    }

    private var accessibilityLabel: Text {
        Text("\(card.name), protocol \(card.proto.isEmpty ? "unknown" : card.proto), latency \(latencyText) ms, \(card.urls.count) peers. Add to current network.")
    }
}

private struct PeerURLsPopover: View {
    var urls: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Peer URLs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(urls, id: \.self) { url in
                Text(url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: 280, alignment: .leading)
    }
}

private struct PeerNoticeBanner: View {
    var text: String
    var severity: PeerNotice.Severity

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        .padding(.horizontal, 16)
    }

    private var iconName: String {
        switch severity {
        case .info: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch severity {
        case .info: .secondary
        case .warning: .orange
        }
    }

    private var borderColor: Color {
        switch severity {
        case .info: .primary.opacity(0.08)
        case .warning: .orange.opacity(0.3)
        }
    }
}
