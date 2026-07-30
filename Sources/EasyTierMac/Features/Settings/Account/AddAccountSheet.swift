import SwiftUI

struct AddAccountSheet: View {
    @Bindable var model: AccountSettingsModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(model.account == nil ? "Add EasyTier Account" : "Sign In Again")
                .font(.title2)
                .bold()
            Text("Enter the HTTPS address of your EasyTier control server.")
                .foregroundStyle(.secondary)

            TextField("https://iw.example.com", text: $model.serverAddress)
                .textFieldStyle(.roundedBorder)
                .disabled(model.phase == .waitingForBrowser)

            if model.phase == .waitingForBrowser {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for browser…")
                }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(model.phase == .waitingForBrowser ? "Cancel Sign-In" : "Cancel") {
                    if model.phase == .waitingForBrowser { model.cancelSignIn() }
                    model.showsAddAccount = false
                }
                Button("Continue in Browser") { model.beginSignIn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || model.phase == .waitingForBrowser
                    )
            }
        }
        .padding()
        .frame(width: 420)
    }
}
