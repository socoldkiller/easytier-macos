import SwiftUI

struct AccountDetailValue: View {
    let value: String

    var body: some View {
        Text(value)
            .textSelection(.enabled)
            .frame(minWidth: 170, alignment: .leading)
    }
}
