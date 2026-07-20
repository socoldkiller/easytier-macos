import EasyTierShared
import SwiftUI

struct PublishedServiceEnabledCell: View {
    var row: PublishedServiceTableRow
    var actionsDisabled: Bool
    var onSetEnabled: (Bool, GatewayPublishedService) -> Void

    var body: some View {
        Toggle(
            "\(row.publicHostname) enabled",
            isOn: Binding(
                get: { row.service.desiredEnabled },
                set: { enabled in
                    guard enabled != row.service.desiredEnabled else { return }
                    onSetEnabled(enabled, row.service)
                }
            )
        )
        .labelsHidden()
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .disabled(actionsDisabled || !row.presentation.canToggleEnabled)
        .help(row.service.desiredEnabled ? "Disable this service" : "Enable this service")
        .accessibilityLabel(
            Text(
                row.service.desiredEnabled
                    ? "Disable \(row.publicHostname)"
                    : "Enable \(row.publicHostname)"
            )
        )
    }
}
