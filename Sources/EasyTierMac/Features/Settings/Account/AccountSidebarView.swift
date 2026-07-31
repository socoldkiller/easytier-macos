import SwiftUI

struct AccountSidebarView: View {
    @Bindable var model: AccountSettingsModel
    let accounts: [SettingsAccount]
    @Binding var selection: SettingsAccount.ID?
    let logOut: () -> Void
    @State private var showsAlternateServer = false

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

            Button {
                model.serverAddress = ""
                showsAlternateServer = true
            } label: {
                HStack(spacing: 6) {
                    Text("Add Account…")
                        .frame(maxWidth: .infinity)
                    Image(systemName: "chevron.down")
                }
            }
            .popover(isPresented: $showsAlternateServer, arrowEdge: .top) {
                AlternateServerAccountPopover(
                    model: model,
                    isPresented: $showsAlternateServer
                )
            }
            .help("Add an account using another server")
            .controlSize(.regular)
            .padding(8)
        }
        .frame(minWidth: 190, idealWidth: 200, maxWidth: 220, maxHeight: .infinity)
        .background(.primary.opacity(0.025))
    }
}
