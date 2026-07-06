import AppKit
import EasyTierShared
import SwiftUI
import UniformTypeIdentifiers

struct LogsView: View {
    @Environment(EasyTierAppStore.self) private var store

    @State private var searchText = ""
    @State private var showingExportPanel = false
    @State private var exportError: String?

    private var filteredEntries: [LogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.logLines }
        let lowercased = query.lowercased()
        return store.logLines.filter { $0.text.lowercased().contains(lowercased) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Runtime Log")
                    .font(.headline)
                Spacer()
                TextField("Search", text: $searchText)
                    .textFieldStyle(.glassField)
                    .frame(width: 180)
                    .accessibilityLabel("Search logs")
                    .accessibilityHint("Filters log entries by substring.")
                Button {
                    store.clearLogs()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Clear logs")
                .accessibilityHint("Removes every log entry from the panel.")
                .disabled(store.logLines.isEmpty)
                Button {
                    copyAll()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Copy logs")
                .accessibilityHint("Copies the currently filtered log entries to the clipboard.")
                .disabled(filteredEntries.isEmpty)
                Button {
                    showingExportPanel = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Export logs")
                .accessibilityHint("Saves the currently filtered log entries to a file.")
                .disabled(filteredEntries.isEmpty)
                Text("\(filteredEntries.count)/\(store.logLines.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Filtered entry count")
                    .accessibilityValue("\(filteredEntries.count) of \(store.logLines.count) entries")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredEntries) { entry in
                        Text(entry.text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .hideEnclosingScrollViewScrollers()
            }
            .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
            .hideScrollViewScrollers()
            .frostedGlassBackground(in: RoundedRectangle(cornerRadius: 8))
            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Export error")
            }
        }
        .padding()
        .fileExporter(
            isPresented: $showingExportPanel,
            document: LogDocument(entries: filteredEntries),
            contentType: .plainText,
            defaultFilename: "easytier-logs"
        ) { result in
            switch result {
            case .success:
                exportError = nil
            case .failure(let error):
                exportError = error.localizedDescription
            }
        }
    }

    private func copyAll() {
        let payload = filteredEntries.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }
}

private struct LogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var entries: [LogEntry]

    init(entries: [LogEntry]) {
        self.entries = entries
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        self.entries = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { LogEntry(text: String($0)) }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let payload = entries.map(\.text).joined(separator: "\n")
        let data = Data(payload.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}
