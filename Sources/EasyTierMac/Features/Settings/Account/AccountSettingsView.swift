import EasyTierShared
import SwiftUI

struct AccountSettingsView: View {
    @Environment(AppContext.self) private var appContext
    @Bindable var model: AccountSettingsModel
    @State private var selection: SettingsAccount.ID?
    @State private var publicIPAddress = PublicIPAddressResolver.loadingPlaceholder

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HSplitView {
                AccountSidebarView(
                    model: model,
                    accounts: accounts,
                    selection: $selection
                )

                if let account = selectedAccount {
                    AccountDetailView(
                        account: account,
                        errorMessage: model.errorMessage,
                        isBusy: model.isOperationInFlight,
                        openConsole: { model.openConsole(accountID: account.id) },
                        useAccount: { Task { await model.activate(accountID: account.id) } },
                        signInAgain: { model.signInAgain(accountID: account.id) },
                        logOut: { Task { await model.logOut(accountID: account.id) } },
                        forgetAccount: { Task { await model.forgetAccount(accountID: account.id) } }
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
        .task {
            guard publicIPAddress == PublicIPAddressResolver.loadingPlaceholder else { return }
            publicIPAddress = await PublicIPAddressResolver.resolve()
                ?? PublicIPAddressResolver.unavailablePlaceholder
        }
        .onChange(of: model.accounts.map(\.id)) { _, _ in synchronizeSelection() }
        .onChange(of: model.activeAccountID) { _, activeID in
            if let activeID { selection = activeID }
        }
    }

    private var accounts: [SettingsAccount] {
        model.sortedAccounts.map { account in
            let status = model.status(for: account.id)
            return SettingsAccount(
                id: account.id,
                displayName: account.profile.username,
                serverName: account.profile.controlOrigin.host() ?? account.profile.controlOrigin.absoluteString,
                username: account.profile.username,
                version: easyTierVersion,
                publicIPAddress: publicIPAddress,
                hostname: NetworkConfig.defaultHostname,
                statusSummary: status.summary,
                isConnected: status == .connected,
                isActive: model.activeAccountID == account.id,
                hasCredential: model.credentialAccountIDs.contains(account.id)
            )
        }
    }

    private var selectedAccount: SettingsAccount? {
        accounts.first { $0.id == selection }
    }

    private var easyTierVersion: String {
        let store = appContext.workspace.store
        let runtimeVersion = store.selectedRuntimeDetail?.my_node_info?.version
            ?? store.runtimeDetails.values.lazy.compactMap { $0.my_node_info?.version }.first
            ?? store.instances.lazy.compactMap { $0.detail?.my_node_info?.version }.first
        return runtimeVersion?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? SettingsSourceRevisionInfo.current.coreVersion
    }

    private func synchronizeSelection() {
        if let selection, accounts.contains(where: { $0.id == selection }) { return }
        selection = model.activeAccountID ?? accounts.first?.id
    }
}
