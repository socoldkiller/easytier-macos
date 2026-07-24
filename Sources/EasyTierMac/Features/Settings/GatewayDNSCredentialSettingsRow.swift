import EasyTierShared
import SwiftUI

struct GatewayDNSCredentialSettingsRow: View {
    let credential: GatewayDNSCredentialDescriptor
    let isDefault: Bool
    let isChangingDefault: Bool
    let setDefaultAction: () -> Void
    let clearDefaultAction: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: setDefaultAction) {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .frame(width: 20)
                        .foregroundStyle(isDefault ? Color.accentColor : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(credential.label)
                            .foregroundStyle(.primary)
                        Text(credential.provider.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    if isChangingDefault {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Changing default credential")
                    } else if isDefault {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                            Text("Default")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)

            Menu {
                if isDefault {
                    Button("Clear Default", systemImage: "xmark.circle", action: clearDefaultAction)
                } else {
                    Button("Make Default", systemImage: "checkmark.circle", action: setDefaultAction)
                }
                Divider()
                Button("Edit", systemImage: "pencil", action: editAction)
                Button("Delete", systemImage: "trash", role: .destructive, action: deleteAction)
            } label: {
                Label("Actions for \(credential.label)", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions for \(credential.label)")
        }
        .frame(maxWidth: .infinity)
    }

    private var accessibilityLabel: String {
        if isDefault {
            return "\(credential.label), default credential"
        }
        return "\(credential.label), \(credential.provider.displayName)"
    }

    private var accessibilityHint: String {
        isDefault ? "Current default credential" : "Sets this as the default credential"
    }
}
