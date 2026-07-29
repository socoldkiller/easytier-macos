import SwiftUI

struct AccountSidebarView: View {
    let accounts: [SettingsAccount]
    @Binding var selection: SettingsAccount.ID?

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
                            Button("Log Out", action: {})
                            Divider()
                            Button("Remove Account", role: .destructive, action: {})
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)

            Divider()

            HStack(spacing: 8) {
                Button(action: {}) {
                    Text("Add Account…")
                        .frame(maxWidth: .infinity)
                }

                Menu {
                    Button("Add Account…", action: {})
                    Divider()
                    Button("Remove Account", role: .destructive, action: {})
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
        .frame(minWidth: 190, idealWidth: 200, maxWidth: 220)
        .background(.primary.opacity(0.025))
    }
}
