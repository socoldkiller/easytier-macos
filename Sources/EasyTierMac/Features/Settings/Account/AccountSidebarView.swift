import SwiftUI

struct AccountSidebarView: View {
    @Bindable var model: AccountSettingsModel
    let accounts: [SettingsAccount]
    @Binding var selection: SettingsAccount.ID?
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
                            if account.hasCredential {
                                Button("Log Out") {
                                    Task { await model.logOut(accountID: account.id) }
                                }
                            }
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
            .disabled(model.isOperationInFlight)
            .padding(8)
        }
        .frame(minWidth: 190, idealWidth: 200, maxWidth: 220, maxHeight: .infinity)
        .background(.primary.opacity(0.025))
    }
}
