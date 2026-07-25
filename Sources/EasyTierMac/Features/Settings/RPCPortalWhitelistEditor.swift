import SwiftUI

struct RPCPortalWhitelistEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var values: [String]
    @FocusState private var focusedIndex: Int?
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Allowed Networks")

                Spacer()

                Button("Add CIDR", systemImage: "plus", action: addValue)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }

            ForEach(values.indices, id: \.self) { index in
                HStack {
                    TextField("CIDR range", text: valueBinding(at: index))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .focused($focusedIndex, equals: index)
                        .onSubmit {
                            focusedIndex = nil
                        }

                    Button(role: .destructive) {
                        removeValue(at: index)
                    } label: {
                        Label("Remove CIDR", systemImage: "minus.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
                    .accessibilityLabel(Text(removeAccessibilityLabel(at: index)))
                    .help(removeAccessibilityLabel(at: index))
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .easyTierSlideFade(edge: .top, distance: 6)
                )
            }
        }
        .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: values.count)
        .onChange(of: focusedIndex) { oldValue, newValue in
            guard oldValue != nil, oldValue != newValue else { return }
            onCommit()
        }
    }

    private func valueBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { values.indices.contains(index) ? values[index] : "" },
            set: { newValue in
                guard values.indices.contains(index) else { return }
                values[index] = newValue
            }
        )
    }

    private func removeAccessibilityLabel(at index: Int) -> String {
        guard values.indices.contains(index), !values[index].isEmpty else {
            return "Remove empty CIDR"
        }
        return "Remove CIDR \(values[index])"
    }

    private func addValue() {
        withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
            values.append("")
        }
    }

    private func removeValue(at index: Int) {
        guard values.indices.contains(index) else { return }
        let hadFocusedField = focusedIndex != nil
        focusedIndex = nil
        _ = withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
            values.remove(at: index)
        }
        if !hadFocusedField {
            onCommit()
        }
    }
}
