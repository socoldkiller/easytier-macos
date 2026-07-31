import SwiftUI

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
