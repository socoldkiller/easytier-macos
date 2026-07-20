import AppKit
import SwiftUI

struct CopyableIPv4AddressCell<AdditionalContextMenu: View>: View {
    let ipv4Address: String
    private let additionalContextMenu: () -> AdditionalContextMenu

    @State private var isHovering = false
    @State private var didCopy = false
    @State private var copyFeedbackToken = 0

    init(
        ipv4Address: String,
        @ViewBuilder additionalContextMenu: @escaping () -> AdditionalContextMenu
    ) {
        self.ipv4Address = ipv4Address
        self.additionalContextMenu = additionalContextMenu
    }

    var body: some View {
        Button {
            copy(ipv4Address)
        } label: {
            Text(ipv4Address)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.trailing, IPv4CellMetrics.trailingReservation)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, IPv4CellMetrics.horizontalPadding)
                .padding(.vertical, IPv4CellMetrics.verticalPadding)
                .frame(minWidth: IPv4CellMetrics.width(for: ipv4Address), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(cellBackground)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(cellBorder, lineWidth: isHovering || didCopy ? 1 : 0)
                }
                .overlay(alignment: .trailing) {
                    trailingIndicator
                        .padding(.trailing, IPv4CellMetrics.horizontalPadding)
                }
        }
        .buttonStyle(CopyFeedbackButtonStyle())
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.18), value: didCopy)
        .help(didCopy ? "Copied \(ipv4Address)" : "Copy IP \(ipv4Address)")
        .contextMenu {
            Button("Copy IP") {
                copy(ipv4Address)
            }
            additionalContextMenu()
        }
        .accessibilityLabel(Text(didCopy ? "Copied IP \(ipv4Address)" : "Copy IP \(ipv4Address)"))
        .accessibilityHint(Text("Copies the IPv4 address to the clipboard."))
    }

    private var trailingIndicator: some View {
        ZStack(alignment: .trailing) {
            if didCopy {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                Image(systemName: isHovering ? "doc.on.doc.fill" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
                    .opacity(isHovering ? 1 : 0.64)
                    .transition(.opacity)
            }
        }
        .frame(width: 16, alignment: .trailing)
    }

    private var cellBackground: Color {
        if didCopy { return EasyTierColors.statusConnected.opacity(0.16) }
        if isHovering { return Color.accentColor.opacity(0.12) }
        return Color.secondary.opacity(0.06)
    }

    private var cellBorder: Color {
        if didCopy { return EasyTierColors.statusConnected.opacity(0.72) }
        if isHovering { return Color.accentColor.opacity(0.5) }
        return Color.clear
    }

    private func copy(_ ipAddress: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ipAddress, forType: .string)
        copyFeedbackToken &+= 1
        let token = copyFeedbackToken

        withAnimation(.spring(response: 0.22, dampingFraction: 0.74)) {
            didCopy = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.35))
            guard copyFeedbackToken == token else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                didCopy = false
            }
        }
    }
}

extension CopyableIPv4AddressCell where AdditionalContextMenu == EmptyView {
    init(ipv4Address: String) {
        self.init(ipv4Address: ipv4Address) {
            EmptyView()
        }
    }
}
