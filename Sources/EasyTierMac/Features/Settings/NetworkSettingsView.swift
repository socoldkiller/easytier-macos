import EasyTierShared
import SwiftUI

struct NetworkSettingsView: View {
    @Binding var dnsSuffix: String
    let commit: (MagicDNSSettings) -> Void

    @FocusState private var isDNSSuffixFocused: Bool
    @State private var validationMessage: String?

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("DNS Suffix") {
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
                LabeledContent("DNS Routing", value: "Split DNS")
            } header: {
                Text("Magic DNS")
            } footer: {
                Text("Only names under this suffix are resolved by EasyTier. Running networks need a restart after the suffix changes.")
            }
        }
        .onChange(of: isDNSSuffixFocused) { wasFocused, isFocused in
            if wasFocused, !isFocused {
                commitDNSSuffix()
            }
        }
    }

    private func commitDNSSuffix() {
        do {
            let settings = try MagicDNSSettings(dnsSuffix: dnsSuffix)
            validationMessage = nil
            dnsSuffix = settings.dnsSuffix
            commit(settings)
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
