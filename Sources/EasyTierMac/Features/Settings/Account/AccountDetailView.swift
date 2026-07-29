import SwiftUI

struct AccountDetailView: View {
    let account: SettingsAccount
    let errorMessage: String?
    let openConsole: () -> Void
    let signInAgain: () -> Void
    let logOut: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                AccountAvatarView(size: 40, showsStatus: false, isConnected: account.isConnected)

                Text(account.displayName)
                    .font(.title2)
                    .bold()

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        AccountDetailLabel(title: "Server")
                        AccountDetailValue(value: account.networkName)
                    }

                    GridRow {
                        AccountDetailLabel(title: "Username")
                        AccountDetailValue(value: account.username)
                    }

                    GridRow(alignment: .top) {
                        AccountDetailLabel(title: "Status")
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(account.isConnected ? EasyTierColors.statusConnected : .secondary)
                                    .frame(width: 14, height: 14)

                                Text(account.statusSummary)
                            }

                            HStack {
                                Button("Log Out", action: logOut)
                                Button("Admin Console…", action: openConsole)
                            }
                        }
                    }

                    GridRow(alignment: .top) {
                        AccountDetailLabel(title: "Config")
                        VStack(alignment: .leading, spacing: 8) {
                            AccountDetailValue(value: account.configEndpoint)
                            Button("Sign In Again…", action: signInAgain)
                        }
                    }

                    if let errorMessage {
                        GridRow(alignment: .top) {
                            AccountDetailLabel(title: "Error")
                            Text(errorMessage)
                                .foregroundStyle(.red)
                                .frame(minWidth: 170, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.top, 28)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
