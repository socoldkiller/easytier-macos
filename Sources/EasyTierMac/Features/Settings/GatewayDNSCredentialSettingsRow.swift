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
                .foregroundStyle(isDefault ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayDomain)
                Text(provider.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if isChangingDefault {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Changing default domain")
            } else if isDefault {
                Label("Default", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.secondary, Color.accentColor)
            }

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
