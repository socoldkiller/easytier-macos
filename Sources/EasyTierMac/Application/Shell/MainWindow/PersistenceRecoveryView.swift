@preconcurrency import AppKit
import EasyTierShared
import SwiftUI

struct PersistenceRecoveryView: View {
    @Environment(AppContext.self) private var appContext
    @State private var isWorking = false
    @State private var showingRebuildConfirmation = false

    var failure: PersistenceFailure

    var body: some View {
        VStack(alignment: .leading) {
            Label("Database Unavailable", systemImage: "externaldrive.badge.exclamationmark")
                .bold()

            Text(failure.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                Button("Retry", systemImage: "arrow.clockwise") {
                    performRecovery { await appContext.retryPersistence() }
                }
                .buttonStyle(.borderedProminent)

                Button("Show Data Folder", systemImage: "folder") {
                    revealDatabase()
                }

                Button("Create New Database", systemImage: "externaldrive.badge.plus") {
                    showingRebuildConfirmation = true
                }

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .disabled(isWorking)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08))
        .alert("Create a New Database?", isPresented: $showingRebuildConfirmation) {
            Button("Create New Database", role: .destructive) {
                performRecovery { await appContext.rebuildPersistence() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The current database and its SQLite sidecar files will be moved to a recovery folder. "
                    + "Legacy files will remain untouched, and EasyTier will start with an empty database."
            )
        }
    }

    private func performRecovery(_ operation: @escaping @MainActor () async -> Bool) {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            _ = await operation()
            isWorking = false
        }
    }

    private func revealDatabase() {
        let fileManager = FileManager.default
        let target = fileManager.fileExists(atPath: failure.databaseURL.path)
            ? failure.databaseURL
            : failure.databaseURL.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}
