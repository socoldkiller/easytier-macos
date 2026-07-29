import SwiftUI

struct AccountSettingsView: View {
    private let accounts = [SettingsAccount.placeholder]
    @State private var selection: SettingsAccount.ID? = SettingsAccount.placeholder.id

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HSplitView {
                AccountSidebarView(accounts: accounts, selection: $selection)

                if let account = selectedAccount {
                    AccountDetailView(account: account)
                } else {
                    ContentUnavailableView(
                        "No Account Selected",
                        systemImage: "person.crop.circle",
                        description: Text("Select an account from the account list.")
                    )
                }
            }
        }
    }

    private var selectedAccount: SettingsAccount? {
        accounts.first { $0.id == selection }
    }
}
