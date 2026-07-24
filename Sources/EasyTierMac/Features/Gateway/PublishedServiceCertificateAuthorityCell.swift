import EasyTierShared
import SwiftUI

struct PublishedServiceCertificateAuthorityCell: View {
    var provider: PublishedServiceSSLProvider
    var authority: GatewayCertificateAuthority
    var activeAuthority: GatewayCertificateAuthority?
    var challenge: String
    var runtimeAuthority: GatewayCertificateAuthority?
    var runtimeChallenge: String?
    var configurationApplied: Bool

    var body: some View {
        Label {
            Text(authority.label)
                .lineLimit(1)
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(provider.isSecure ? EasyTierColors.statusConnected : .secondary)
        }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text("Certificate: \(authority.label), \(challenge), \(provider.connectionLabel)")
        )
    }

    private var iconName: String {
        switch provider {
        case .unavailable: "exclamationmark.lock"
        case .managedHTTPS: "lock.fill"
        case .requesting: "clock.badge"
        case .httpOnly: "lock.open"
        }
    }

    private var helpText: String {
        if !configurationApplied {
            let configured = "Configured: \(authority.label) / \(challenge)"
            guard let runtimeAuthority, let runtimeChallenge else {
                return "\(configured). This configuration has not been applied to the Gateway runtime."
            }
            return "\(configured). Runtime: \(runtimeAuthority.label) / \(runtimeChallenge). The saved configuration has not been applied yet."
        }
        if let activeAuthority, activeAuthority != authority {
            return "Switching to \(authority.label) with \(challenge). The active certificate is from \(activeAuthority.label)."
        }
        return "\(authority.label) with \(challenge). \(provider.helpText)"
    }
}
