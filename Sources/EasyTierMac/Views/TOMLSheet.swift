import SwiftUI

struct TOMLSheet: View {
    enum Mode {
        case `import`
        case export
    }

    @Environment(\.dismiss) private var dismiss
    var mode: Mode
    @State private var text: String
    var onImport: (String) -> Void

    init(mode: Mode, initialText: String, onImport: @escaping (String) -> Void) {
        self.mode = mode
        _text = State(initialValue: initialText)
        self.onImport = onImport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .import ? "Import TOML" : "Export TOML")
                .font(.title2.weight(.semibold))

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .textEditorStyle(.plain)
                .hiddenScrollIndicators()
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                if mode == .export {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
                if mode == .import {
                    Button("Import") {
                        onImport(text)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 720, height: 560)
        .presentedSurfaceMotion()
    }
}
