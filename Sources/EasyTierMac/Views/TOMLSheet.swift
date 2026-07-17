import AppKit
import EasyTierShared
import SwiftUI

struct TOMLSheet: View {
    enum Mode {
        case `import`
        case export
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var mode: Mode
    @State private var text: String
    @State private var includesNetworkSecret = false
    @State private var isRefreshingExport = false
    @State private var isShowingPlaintextWarning = false
    @State private var exportError: String?
    @State private var exportRefreshTask: Task<Void, Never>?
    var onImport: (String) -> Void
    var onExportSecretInclusionChange: ((Bool) async throws -> String)?

    init(
        mode: Mode,
        initialText: String,
        onImport: @escaping (String) -> Void,
        onExportSecretInclusionChange: ((Bool) async throws -> String)? = nil
    ) {
        self.mode = mode
        _text = State(initialValue: initialText)
        self.onImport = onImport
        self.onExportSecretInclusionChange = onExportSecretInclusionChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .import ? "Import TOML" : "Export TOML")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if mode == .export {
                exportSecurityControls
            }

            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .frostedGlassBackground(in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(mode == .import ? "Import TOML editor" : "Export TOML viewer")
                .accessibilityHint(mode == .import ? "Paste or edit a TOML network config here." : "Read-only preview of the exported TOML.")

            HStack {
                if mode == .export {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .disabled(isRefreshingExport || text.isEmpty)
                    .accessibilityHint("Copies the TOML to the clipboard.")
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Dismisses the TOML sheet without saving.")
                if mode == .import {
                    Button("Import") {
                        onImport(text)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Imports the edited TOML into the selected network.")
                }
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 720, minHeight: 400, idealHeight: 560)
        .presentationBackground { FrostedGlass(role: .sheet) }
        .presentedSurfaceMotion()
        .hideScrollViewScrollers()
        .onChange(of: scenePhase) { _, phase in
            guard mode == .export, phase != .active else { return }
            exportRefreshTask?.cancel()
            exportRefreshTask = nil
            text = ""
            includesNetworkSecret = false
            isRefreshingExport = false
        }
        .onDisappear {
            if mode == .export {
                exportRefreshTask?.cancel()
                exportRefreshTask = nil
                text = ""
                includesNetworkSecret = false
                isRefreshingExport = false
            }
        }
        .alert("Include the plaintext network password?", isPresented: $isShowingPlaintextWarning) {
            Button("Include Password", role: .destructive) {
                refreshExport(includeNetworkSecret: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The exported TOML and anything copied from it will contain the network password in plaintext. Anyone with access to the file or clipboard can read it.")
        }
    }

    private var exportSecurityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Include network password",
                isOn: Binding(
                    get: { includesNetworkSecret },
                    set: { include in
                        if include {
                            isShowingPlaintextWarning = true
                        } else {
                            refreshExport(includeNetworkSecret: false)
                        }
                    }
                )
            )
            .disabled(isRefreshingExport)

            if isRefreshingExport {
                Label("Authenticating and rebuilding export...", systemImage: "lock.rotation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if includesNetworkSecret {
                Label("This preview contains a plaintext password.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                Label("Password omitted. No Keychain access is required.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func refreshExport(includeNetworkSecret: Bool) {
        guard let onExportSecretInclusionChange else {
            includesNetworkSecret = false
            return
        }
        exportRefreshTask?.cancel()
        if !includeNetworkSecret {
            text = ""
            includesNetworkSecret = false
        }
        isRefreshingExport = true
        exportError = nil
        exportRefreshTask = Task {
            do {
                let refreshedText = try await onExportSecretInclusionChange(includeNetworkSecret)
                guard !Task.isCancelled else { return }
                text = refreshedText
                includesNetworkSecret = includeNetworkSecret
            } catch {
                guard !Task.isCancelled else { return }
                includesNetworkSecret = false
                if !EasyTierAppStore.isNetworkSecretAccessCancellation(error) {
                    exportError = error.localizedDescription
                }
            }
            guard !Task.isCancelled else { return }
            isRefreshingExport = false
            exportRefreshTask = nil
        }
    }

    @ViewBuilder private var editor: some View {
        if mode == .export {
            TOMLPreview(text: text)
        } else {
            TOMLEditor(text: $text)
        }
    }
}

private struct TOMLEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = TOMLHighlighter.font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.enabledTextCheckingTypes = 0

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller?.isHidden = true
        scrollView.horizontalScroller?.isHidden = true
        context.coordinator.text = $text

        guard textView.string != text else { return }
        let selectedRanges = textView.selectedRanges
        textView.string = text
        textView.selectedRanges = selectedRanges.compactMap { rangeValue in
            let range = rangeValue.rangeValue
            guard NSMaxRange(range) <= (text as NSString).length else { return nil }
            return rangeValue
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

private struct TOMLPreview: NSViewRepresentable {
    var text: String

    func makeNSView(context _: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = TOMLHighlighter.font
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller?.isHidden = true
        scrollView.horizontalScroller?.isHidden = true
        textView.textStorage?.setAttributedString(TOMLHighlighter.highlighted(text))
    }
}

private enum TOMLHighlighter {
    static var font: NSFont { NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
    private static var boldFont: NSFont { NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold) }

    static func highlighted(_ text: String) -> NSAttributedString {
        assert(selfCheck())

        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])

        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = text[lineRange]
            let commentStart = firstCommentIndex(in: line)
            let codeEnd = commentStart ?? line.endIndex
            let code = line[..<codeEnd]
            let trimmedCode = code.trimmedRange

            if trimmedCode.lowerBound < trimmedCode.upperBound, code[trimmedCode.lowerBound] == "[" {
                result.addAttributes([
                    .font: boldFont,
                    .foregroundColor: NSColor.systemPurple,
                ], range: NSRange(trimmedCode, in: text))
            } else if let equals = code.firstIndex(of: "=") {
                let keyRange = code[..<equals].trimmedRange
                if keyRange.lowerBound < keyRange.upperBound {
                    result.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: NSRange(keyRange, in: text))
                }
            }

            for range in quotedRanges(in: code) {
                result.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: NSRange(range, in: text))
            }

            if let commentStart {
                result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(commentStart..<line.endIndex, in: text))
            }
        }

        return result
    }

    // ponytail: lightweight highlighter, replace with a parser only if multiline strings need exact colors.
    private static func firstCommentIndex(in line: Substring) -> String.Index? {
        var quote: Character?
        var escaped = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]

            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if activeQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "#" {
                return index
            } else if character == "\"" || character == "'" {
                quote = character
            }

            index = line.index(after: index)
        }

        return nil
    }

    private static func quotedRanges(in line: Substring) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var quoteStart: String.Index?
        var quote: Character?
        var escaped = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]

            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if activeQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == activeQuote, let start = quoteStart {
                    ranges.append(start..<line.index(after: index))
                    quote = nil
                    quoteStart = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
                quoteStart = index
            }

            index = line.index(after: index)
        }

        return ranges
    }

    private static func selfCheck() -> Bool {
        let sample = #"name = "value # still string" # comment"#
        let line = sample[...]
        guard let commentStart = firstCommentIndex(in: line) else { return false }
        return String(line[commentStart...]) == "# comment" && quotedRanges(in: line[..<commentStart]).count == 1
    }
}

private extension Substring {
    var trimmedRange: Range<String.Index> {
        var lowerBound = startIndex
        var upperBound = endIndex

        while lowerBound < upperBound, self[lowerBound].isWhitespace {
            formIndex(after: &lowerBound)
        }

        while lowerBound < upperBound {
            let previous = index(before: upperBound)
            guard self[previous].isWhitespace else { break }
            upperBound = previous
        }

        return lowerBound..<upperBound
    }
}
