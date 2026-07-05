import AppKit
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

            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .frostedGlassBackground(in: RoundedRectangle(cornerRadius: 8))

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
        .presentationBackground { FrostedGlass() }
        .presentedSurfaceMotion()
    }

    @ViewBuilder private var editor: some View {
        if mode == .export {
            TOMLPreview(text: text)
        } else {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .textEditorStyle(.plain)
                .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
        }
    }
}

private struct TOMLPreview: NSViewRepresentable {
    var text: String

    func makeNSView(context _: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
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
