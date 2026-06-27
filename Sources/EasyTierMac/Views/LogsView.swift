import EasyTierShared
import SwiftUI

struct LogsView: View {
    @Environment(EasyTierAppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Runtime Log")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    store.clearLogs()
                }
                .disabled(store.logLines.isEmpty)
                Text("\(store.logLines.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(store.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding()
    }
}
