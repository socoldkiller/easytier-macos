import EasyTierShared
import SwiftUI

struct AccountSettingsView: View {
    @Bindable var model: AccountSettingsModel
    @State private var selection: SettingsAccount.ID?

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HSplitView {
                AccountSidebarView(
                    model: model,
                    accounts: accounts,
                    selection: $selection,
                    logOut: logOut
                )

                if let account = selectedAccount {
                    AccountDetailView(
                        account: account,
                        errorMessage: model.errorMessage,
                        openConsole: model.openConsole,
                        signInAgain: model.signInAgain,
                        logOut: logOut
                    )
                } else {
                    ContentUnavailableView(
                        "No Account Selected",
                        systemImage: "person.crop.circle",
                        description: Text("Add an EasyTier account to sign in through your browser.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { synchronizeSelection() }
        .onChange(of: model.account?.machineID) { _, _ in synchronizeSelection() }
    }

    private var accounts: [SettingsAccount] {
        guard let account = model.account else { return [] }
        return [
            SettingsAccount(
                id: account.machineID.uuidString.lowercased(),
                displayName: account.username,
                networkName: account.controlOrigin.host() ?? account.controlOrigin.absoluteString,
                username: account.username,
                configEndpoint: account.configEndpoint,
                statusSummary: statusSummary,
                isConnected: model.phase == .connected
            )
        ]
    }

    private var selectedAccount: SettingsAccount? {
        accounts.first { $0.id == selection }
    }

    private var statusSummary: String {
        switch model.phase {
        case .signedOut: "Signed Out"
        case .waitingForBrowser: "Waiting for Browser"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .retrying: "Retrying"
        case .failed: "Connection Failed"
        }
    }

    private func synchronizeSelection() {
        selection = accounts.first?.id
    }

    private func logOut() {
        Task { await model.logOut() }
    }
}
