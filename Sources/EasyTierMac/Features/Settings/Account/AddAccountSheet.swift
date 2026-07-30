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

struct AlternateServerAccountPopover: View {
    @Bindable var model: AccountSettingsModel
    @Binding var isPresented: Bool
    @FocusState private var serverFieldIsFocused: Bool

    private var isWaitingForBrowser: Bool {
        model.phase == .waitingForBrowser
    }

    private var serverAddressIsEmpty: Bool {
        model.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Account Using Alternate Server")
                .font(.headline)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                Text("Enter the URL of an alternate EasyTier control server or your self-hosted server.")

                TextField("https://my.custom.server.com", text: $model.serverAddress)
                    .textFieldStyle(.roundedBorder)
                    .focused($serverFieldIsFocused)
                    .disabled(isWaitingForBrowser)
            }

            if isWaitingForBrowser {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for browser…")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 20) {
                Button {
                    if isWaitingForBrowser { model.cancelSignIn() }
                    isPresented = false
                } label: {
                    Text(isWaitingForBrowser ? "Cancel Sign-In" : "Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button {
                    model.beginSignIn()
                } label: {
                    Text("Add Account…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(serverAddressIsEmpty || isWaitingForBrowser)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            serverFieldIsFocused = true
        }
        .onChange(of: model.account?.machineID) { _, machineID in
            if machineID != nil { isPresented = false }
        }
    }
}
