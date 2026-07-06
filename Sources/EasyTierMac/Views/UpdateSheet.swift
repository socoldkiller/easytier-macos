import EasyTierShared
import SwiftUI

struct UpdateSheet: View {
    @Environment(SoftwareUpdateController.self) private var updater
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let appInfo = AppVersionInfo.current

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            content
                .frame(maxWidth: .infinity)
                .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: statusKey)

            Divider()
                .opacity(0.5)

            actions
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 460)
        .presentationBackground { FrostedGlass() }
        .presentedSurfaceMotion()
        .hideScrollViewScrollers()
    }

    private var header: some View {
        VStack(spacing: 12) {
            EasyTierMark()
                .frame(width: 72, height: 72)

            Text(headerTitle)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .checking:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text("Checking stable releases…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)

        case .noUpdate(let currentVersion):
            Label {
                Text("EasyTier \(currentVersion) is up to date.")
                    .font(.callout)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)

        case .available(let update, let currentVersion):
            updateDetail(update: update, currentVersion: currentVersion)
            releaseNotesSection

        case .downloading(let update, let progress):
            downloadProgress(update: update, progress: progress)

        case .readyToInstall(let update, _):
            readyToInstallGuidance(update: update)

        case .failed(let message):
            errorGuidance(message: message, kind: .checkFailed)

        case .downloadFailed(let update, let message):
            errorGuidance(message: message, kind: .downloadFailed(update: update))

        case .verificationFailed(let update, let message):
            errorGuidance(message: message, kind: .verificationFailed(update: update))

        case .idle:
            EmptyView()
        }
    }

    private func updateDetail(update: EasyTierAvailableUpdate, currentVersion: String) -> some View {
        VStack(spacing: 6) {
            UpdateMetadataRow(label: "Available", value: update.version)
            UpdateMetadataRow(label: "Current", value: currentVersion)
            UpdateMetadataRow(label: "Size", value: byteFormatted(update.asset.size))
        }
    }

    private func downloadProgress(update: EasyTierAvailableUpdate, progress: Double?) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let progress {
                    ProgressView(value: progress)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Text("EasyTier \(update.version) · \(byteFormatted(update.asset.size))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private func readyToInstallGuidance(update: EasyTierAvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("EasyTier \(update.version) is ready to install.")
                    .font(.callout.weight(.medium))
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
            }

            Text("The update has been downloaded and opened in Finder. Drag EasyTier to your Applications folder to replace the current version, then relaunch the app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func errorGuidance(message: String, kind: ErrorKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(kind.title)
                    .font(.callout.weight(.medium))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)

            if let recovery = kind.recoveryHint {
                Text(recovery)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var releaseNotesSection: some View {
        if let update = updater.state.visibleUpdate {
            ReleaseNotesView(url: update.releaseNotesURL)
                .frame(maxWidth: .infinity, minHeight: 80, idealHeight: 160)
                .padding(8)
                .frostedGlassBackground(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch updater.state {
        case .checking:
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

        case .noUpdate:
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

        case .available:
            HStack {
                Button("Skip This Version") { updater.skipAvailableUpdate() }
                Button("Remind Me Later") { updater.remindLater() }
                Spacer()
                Button("Release Notes") { updater.openReleaseNotes() }
                    .buttonStyle(.link)
                Button("Download") { updater.downloadAvailableUpdate() }
                    .keyboardShortcut(.defaultAction)
            }

        case .downloading:
            HStack {
                Button("Cancel Download") { updater.cancelDownload() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }

        case .readyToInstall:
            HStack {
                Button("Reveal in Finder") { updater.revealDownloadedInFinder() }
                Spacer()
                Button("Quit EasyTier") { updater.quitEasyTier() }
                    .keyboardShortcut(.defaultAction)
            }

        case .failed:
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Retry") { updater.checkForUpdates() }
                    .keyboardShortcut(.defaultAction)
            }

        case .downloadFailed:
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Try Again") { updater.downloadAvailableUpdate() }
                    .keyboardShortcut(.defaultAction)
            }

        case .verificationFailed:
            HStack {
                Button("Report Issue") {
                    if let url = URL(string: "https://github.com/socoldkiller/easytier-macos/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
                Button("Try Again") { updater.downloadAvailableUpdate() }
                    .keyboardShortcut(.defaultAction)
            }

        case .idle:
            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
    }

    private var headerTitle: String {
        switch updater.state {
        case .checking: "Checking for Updates…"
        case .noUpdate: "You're Up to Date"
        case .available(let update, _): "EasyTier \(update.version) is Available"
        case .downloading(let update, _): "Downloading EasyTier \(update.version)"
        case .readyToInstall: "Ready to Install"
        case .failed: "Check Failed"
        case .downloadFailed: "Download Failed"
        case .verificationFailed: "Verification Failed"
        case .idle: "Software Update"
        }
    }

    private var headerSubtitle: String {
        switch updater.state {
        case .checking: "Contacting the update feed…"
        case .noUpdate(let currentVersion): "Version \(currentVersion)"
        case .available(_, let currentVersion): "You have \(currentVersion)"
        case .downloading(let update, _): "\(byteFormatted(update.asset.size))"
        case .readyToInstall: "Download complete"
        case .failed: "We couldn't check for updates right now."
        case .downloadFailed: "The update couldn't be downloaded."
        case .verificationFailed: "The downloaded file didn't match the published checksum."
        case .idle: "Checks stable releases only."
        }
    }

    private var statusKey: String {
        switch updater.state {
        case .idle: "idle"
        case .checking: "checking"
        case .noUpdate: "noUpdate"
        case .available: "available"
        case .downloading: "downloading"
        case .failed: "failed"
        case .downloadFailed: "downloadFailed"
        case .verificationFailed: "verificationFailed"
        case .readyToInstall: "readyToInstall"
        }
    }

    private func byteFormatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private enum ErrorKind {
        case checkFailed
        case downloadFailed(update: EasyTierAvailableUpdate)
        case verificationFailed(update: EasyTierAvailableUpdate)

        var title: String {
            switch self {
            case .checkFailed: "Check Failed"
            case .downloadFailed: "Download Failed"
            case .verificationFailed: "Verification Failed"
            }
        }

        var recoveryHint: String? {
            switch self {
            case .checkFailed:
                "Check your network connection and try again."
            case .downloadFailed:
                "The download was interrupted. Try again, or check your connection."
            case .verificationFailed:
                "The downloaded file may be corrupted or tampered with. Please report this issue."
            }
        }
    }
}

private struct UpdateMetadataRow: View {
    var label: String
    var value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(label)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ReleaseNotesView: View {
    let url: URL

    @State private var content: String?
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        ScrollView {
            if isLoading {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading release notes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            } else if let content, !content.isEmpty {
                Text(content)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if loadFailed {
                VStack(spacing: 6) {
                    Text("Couldn't load release notes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Open in browser", destination: url)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                EmptyView()
            }
        }
        .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
        .hideScrollViewScrollers()
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let raw = String(data: data, encoding: .utf8) ?? ""
            content = Self.truncated(raw, maxCharacters: 4_000)
        } catch {
            loadFailed = true
        }
    }

    private static func truncated(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let prefix = text.prefix(maxCharacters)
        return "\(prefix)\n\n…"
    }
}
