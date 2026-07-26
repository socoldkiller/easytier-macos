import SwiftUI

struct AccountDetailLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .bold()
            .frame(width: 72, alignment: .trailing)
    }
}
