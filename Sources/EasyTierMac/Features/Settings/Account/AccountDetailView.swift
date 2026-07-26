import SwiftUI

struct AccountDetailView: View {
    let account: SettingsAccount

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                AccountAvatarView(size: 40, showsStatus: false, isConnected: account.isConnected)

                Text(account.displayName)
                    .font(.title2)
                    .bold()

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        AccountDetailLabel(title: "Network")
                        AccountDetailValue(value: account.networkName)
                    }

                    GridRow {
                        AccountDetailLabel(title: "Email")
                        AccountDetailValue(value: account.email)
                    }

                    GridRow(alignment: .top) {
                        AccountDetailLabel(title: "Status")
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(account.isConnected ? EasyTierColors.statusConnected : .secondary)
                                    .frame(width: 14, height: 14)

                                Text(account.isConnected ? "Logged In" : "Logged Out")
                            }

                            HStack {
                                Button("Log Out", action: {})
                                Button("Admin Console…", action: {})
                            }
                        }
                    }

                    GridRow(alignment: .top) {
                        AccountDetailLabel(title: "Expiry")
                        VStack(alignment: .leading, spacing: 8) {
                            AccountDetailValue(value: account.expirationSummary)
                            Button("Renew…", action: {})
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
    }
}
