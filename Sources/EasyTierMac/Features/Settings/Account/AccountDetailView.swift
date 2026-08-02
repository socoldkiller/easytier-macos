import SwiftUI

struct AccountDetailView: View {
    let account: SettingsAccount
    let errorMessage: String?
    let isBusy: Bool
    let openConsole: () -> Void
    let useAccount: () -> Void
    let signInAgain: () -> Void
    let logOut: () -> Void
    let forgetAccount: () -> Void
    @State private var confirmsForget = false

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
                        AccountDetailValue(value: account.serverName)
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
                                if account.isActive, account.hasCredential {
                                    Button("Log Out", action: logOut)
                                } else if account.hasCredential {
                                    Button("Use This Account", action: useAccount)
                                        .buttonStyle(.borderedProminent)
                                } else {
                                    Button("Sign In Again…", action: signInAgain)
                                        .buttonStyle(.borderedProminent)
                                }
                                Button("Admin Console…", action: openConsole)
                            }
                            .disabled(isBusy)

                            if account.hasCredential {
                                Button("Sign In Again…", action: signInAgain)
                                    .disabled(isBusy)
                            }
                        }
                    }

                    GridRow {
                        AccountDetailLabel(title: "Version")
                        AccountDetailValue(value: account.version)
                    }

                    GridRow {
                        AccountDetailLabel(title: "Public IP")
                        AccountDetailValue(value: account.publicIPAddress)
                    }

                    GridRow {
                        AccountDetailLabel(title: "Hostname")
                        AccountDetailValue(value: account.hostname)
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

                Divider()
                    .padding(.top, 8)

                Button("Forget Account…", role: .destructive) {
                    confirmsForget = true
                }
                .disabled(isBusy)
            }
            .padding(.top, 28)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "Forget \(account.displayName)?",
            isPresented: $confirmsForget,
            titleVisibility: .visible
        ) {
            Button("Forget Account", role: .destructive, action: forgetAccount)
        } message: {
            Text("This removes the saved sign-in and account details from this Mac.")
        }
    }
}
