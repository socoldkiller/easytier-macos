import SwiftUI

enum SettingsTint {
    static let magicDNS = Color.indigo
    static let rpcServer = Color.teal
}

struct SectionIcon: View {
    var systemImage: String
    var tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: systemImage)
            .font(.headline)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedGlassBackground(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct CardSection<Content: View>: View {
    var title: String
    var systemImage: String?
    var tint: Color?
    var footer: String?
    @ViewBuilder var content: Content

    init(
        _ title: String,
        systemImage: String? = nil,
        tint: Color? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 7) {
                if let systemImage, let tint {
                    SectionIcon(systemImage: systemImage, tint: tint)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .center)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }

            SettingsCard { content }

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
    }
}

struct SettingsInlineRow<Content: View>: View {
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

struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .opacity(0.45)
    }
}

struct FieldRow<Content: View>: View {
    var label: String
    var description: String?
    var help: String?
    @ViewBuilder var content: Content

    init(
        _ label: String,
        description: String? = nil,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.description = description
        self.help = help
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            verticalLayout
        }
        .help(help ?? label)
    }

    private var labelContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
            if let description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var horizontalLayout: some View {
        HStack(alignment: .top, spacing: 11) {
            labelContent
            .frame(width: 140, alignment: .leading)
            content
                .frame(maxWidth: 520, alignment: .leading)
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            labelContent
            content
                .frame(maxWidth: 520, alignment: .leading)
        }
    }
}

struct StatusPill: View {
    enum Tone {
        case neutral, positive, warning
        var color: Color {
            switch self {
            case .neutral: .secondary
            case .positive: .green
            case .warning: .orange
            }
        }
    }

    var text: String
    var tone: Tone = .neutral

    init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(tone.color == .secondary ? .secondary : .primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tone.color.opacity(0.12)))
        .overlay(Capsule().stroke(tone.color.opacity(0.25), lineWidth: 0.5))
    }
}

struct StatusDot: View {
    var tone: StatusPill.Tone = .neutral
    var accessibilityLabel: String

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(Text(accessibilityLabel))
    }
}

struct StatusBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    var value: String
    var systemImage: String
    var width: CGFloat? = nil

    init(title: String, value: String, systemImage: String, width: CGFloat? = nil) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.width = width
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value.isEmpty ? "-" : value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(width: width, alignment: .leading)
        .liquidGlassMetricBackground(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: value)
    }
}

struct ExpandableSettingsGroup<Content: View>: View {
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
            DisclosureHeader(
                isExpanded: isExpanded,
                title: title,
                onToggle: {
                    withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
                        isExpanded.toggle()
                    }
                }
            )

            if isExpanded {
                content
                    .padding(.top, 6)
                    .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 6))
            }
        }
    }
}

struct DisclosureHeader<Trailing: View>: View {
    var isExpanded: Bool
    var title: String
    var onToggle: () -> Void
    @ViewBuilder var trailing: Trailing

    init(
        isExpanded: Bool,
        title: String,
        onToggle: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.isExpanded = isExpanded
        self.title = title
        self.onToggle = onToggle
        self.trailing = trailing()
    }

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.medium))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 11)
                Text(title)
                    .font(.body.weight(.medium))
                Spacer(minLength: 10)
                trailing
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

extension DisclosureHeader where Trailing == EmptyView {
    init(isExpanded: Bool, title: String, onToggle: @escaping () -> Void) {
        self.init(isExpanded: isExpanded, title: title, onToggle: onToggle, trailing: { EmptyView() })
    }
}
