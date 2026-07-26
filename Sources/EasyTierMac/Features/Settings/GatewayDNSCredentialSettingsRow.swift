import EasyTierShared
import SwiftUI

struct GatewayDNSCredentialSettingsRow: View {
    let binding: GatewayDNSZoneBinding
    let provider: GatewayDNSProvider
    let isDefault: Bool
    let isChangingDefault: Bool
    let deletionDisabledReason: String?
    let setDefaultAction: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void

    private var displayDomain: String {
        binding.dnsSuffix.hasSuffix(".")
            ? String(binding.dnsSuffix.dropLast())
            : binding.dnsSuffix
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayDomain)
                Text(provider.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Group {
                if isChangingDefault {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Changing default domain")
                        .transition(.opacity)
                } else if isDefault {
                    Label("Default", systemImage: "checkmark")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: .capsule)
                        .transition(.scale(scale: 0.86).combined(with: .opacity))
                        .accessibilityLabel("Default domain")
                }
            }
            .animation(.snappy(duration: 0.24), value: isChangingDefault)
            .animation(.snappy(duration: 0.24), value: isDefault)

            Menu {
                Button("Make Default", systemImage: "checkmark.circle", action: setDefaultAction)
                    .disabled(isDefault)
                    .help(
                        isDefault
                            ? "This is already the default domain."
                            : "Use \(displayDomain) for Magic DNS and new services."
                    )
                Button("Update Credential…", systemImage: "key", action: editAction)
                Divider()
                Button("Delete Domain…", systemImage: "trash", role: .destructive, action: deleteAction)
                    .disabled(deletionDisabledReason != nil)
                    .help(deletionDisabledReason ?? "Delete \(displayDomain)")
            } label: {
                Label("Actions for \(displayDomain)", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(deletionDisabledReason ?? "Actions for \(displayDomain)")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}
