import SwiftUI

struct AccountSidebarView: View {
    let accounts: [SettingsAccount]
    @Binding var selection: SettingsAccount.ID?
    let addAccount: () -> Void
    let logOut: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(accounts) { account in
                        AccountSidebarRow(
                            account: account,
                            isSelected: selection == account.id,
                            action: { selection = account.id }
                        )
                        .contextMenu {
                            Button("Log Out", action: logOut)
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)

            Divider()

            HStack(spacing: 8) {
                Button(action: addAccount) {
                    Text("Add Account…")
                        .frame(maxWidth: .infinity)
                }

                Menu {
                    Button("Add Account…", action: addAccount)
                    Divider()
                    Button("Log Out", role: .destructive, action: logOut)
                        .disabled(accounts.isEmpty)
                } label: {
                    Label("Account Actions", systemImage: "chevron.down")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .controlSize(.regular)
            .padding(8)
        }
        .frame(minWidth: 190, idealWidth: 200, maxWidth: 220, maxHeight: .infinity)
        .background(.primary.opacity(0.025))
    }
}
