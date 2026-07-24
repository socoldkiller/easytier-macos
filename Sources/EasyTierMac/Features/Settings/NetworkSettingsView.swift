import EasyTierShared
import SwiftUI

struct NetworkSettingsView: View {
    @Binding var dnsSuffix: String
    let managedDNSSuffix: String?
    let commit: (MagicDNSSettings) -> Void

    @FocusState private var isDNSSuffixFocused: Bool
    @State private var validationMessage: String?

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("DNS Suffix") {
                    if let managedDNSSuffix {
                        Text(managedDNSSuffix)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .trailing, spacing: 4) {
                            TextField("et.net.", text: $dnsSuffix)
                                .labelsHidden()
                                .font(.body.monospaced())
                                .frame(width: 180)
                                .focused($isDNSSuffixFocused)
                                .onSubmit(commitDNSSuffix)

                            if let validationMessage {
                                Text(validationMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                LabeledContent("DNS Routing", value: "Split DNS")
            } header: {
                Text("Magic DNS")
            } footer: {
                Text(footerText)
            }
        }
        .onChange(of: isDNSSuffixFocused) { wasFocused, isFocused in
            if wasFocused, !isFocused {
                commitDNSSuffix()
            }
        }
    }

    private func commitDNSSuffix() {
        guard managedDNSSuffix == nil else { return }
        do {
            let settings = try MagicDNSSettings(dnsSuffix: dnsSuffix)
            validationMessage = nil
            dnsSuffix = settings.dnsSuffix
            commit(settings)
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private var footerText: String {
        if managedDNSSuffix != nil {
            return "Managed by the default domain in Gateway settings."
        }
        return "Only names under this suffix are resolved by EasyTier. Running networks need a restart after the suffix changes."
    }
}
