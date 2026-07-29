import EasyTierShared
import SwiftUI

struct AccountSettingsView: View {
    @Bindable var model: AccountSettingsModel

    var body: some View {
        Group {
            if let account = model.account {
                AccountSignedInView(model: model, account: account)
            } else {
                ContentUnavailableView {
                    Label("No Account", systemImage: "person.crop.circle")
                } description: {
                    Text("Sign in with your EasyTier control server to manage networks from this Mac.")
                } actions: {
                    Button("Add Account…") { model.showsAddAccount = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $model.showsAddAccount) {
            AddAccountSheet(model: model)
        }
    }
}

private struct AccountSignedInView: View {
    @Bindable var model: AccountSettingsModel
    let account: RemoteAccountProfile

    var body: some View {
        Form {
            Section {
                HStack {
                    AccountAvatarView(
                        size: 44,
                        showsStatus: true,
                        isConnected: model.phase == .connected
                    )
                    VStack(alignment: .leading) {
                        Text(account.username).font(.title2).bold()
                        Text(account.controlOrigin.host() ?? account.controlOrigin.absoluteString)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Connection") {
                LabeledContent("Status", value: statusText)
                LabeledContent("Config Server", value: account.configEndpoint)
                LabeledContent("Machine ID", value: account.machineID.uuidString.lowercased())
            }

            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                HStack {
                    Button("Admin Console…") { model.openConsole() }
                    Button("Sign In Again…") { model.signInAgain() }
                    Spacer()
                    Button("Log Out", role: .destructive) {
                        Task { await model.logOut() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch model.phase {
        case .signedOut: "Signed Out"
        case .waitingForBrowser: "Waiting for Browser"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .retrying: "Retrying"
        case .failed: "Connection Failed"
        }
    }
}

private struct AddAccountSheet: View {
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

            if let error = model.errorMessage {
                Text(error)
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
