import AppKit
import EasyTierShared
import SwiftUI

struct SoftwareUpdateView: View {
    @Environment(SoftwareUpdateController.self) private var updater
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SoftwareUpdateAppIcon()
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(headerTitle)
                                .font(.title3.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)

                            if !headerSubtitle.isEmpty {
                                Text(headerSubtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        content
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: statusKey)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden, axes: .vertical)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: Self.maximumScrollableContentHeight)
                .fixedSize(horizontal: false, vertical: true)

                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(minWidth: 460, idealWidth: 500, maxWidth: 620, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .hideScrollViewScrollers()
        .onAppear { updater.setSoftwareUpdateWindowVisible(true) }
        .onDisappear { updater.setSoftwareUpdateWindowVisible(false) }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking stable releases…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .noUpdate(let currentVersion):
            Label {
                Text("EasyTier \(currentVersion) is up to date.")
                    .font(.callout)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

        case .available(let update, _, let wasPreviouslySkipped):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(byteFormatted(update.asset.size)) · \(architectureLabel(update.architecture))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button("View Release Notes") { updater.openReleaseNotes() }
                        .buttonStyle(.link)
                }

                if wasPreviouslySkipped {
                    Label("You previously skipped this version.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        case .downloading(let update, let progress):
            downloadProgress(update: update, progress: progress)

        case .downloadComplete:
            Label {
                Text("The disk image is open. Drag EasyTier to Applications. If Finder asks to replace the existing app, quit EasyTier first.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "externaldrive.badge.checkmark")
                    .foregroundStyle(.green)
            }

        case .failed(let message):
            errorGuidance(message: message, kind: .checkFailed)

        case .downloadFailed(let update, let message):
            errorGuidance(message: message, kind: .downloadFailed(update: update))

        case .verificationFailed(let update, let message):
            errorGuidance(message: message, kind: .verificationFailed(update: update))

        case .idle:
            Text("Check for the latest stable version of EasyTier.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func downloadProgress(update: EasyTierAvailableUpdate, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing download…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel Download") { updater.cancelDownload() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }

            if let progress {
                Text("\(downloadedSizeText(update: update, progress: progress)) · \(Int((progress * 100).rounded()))%")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func errorGuidance(message: String, kind: ErrorKind) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(.orange)
            }

            Text(kind.recoveryHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 22)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch updater.state {
        case .checking:
            HStack {
                Spacer()
                Button("Cancel") {
                    updater.cancelCheck()
                    closeWindow()
                }
                .keyboardShortcut(.cancelAction)
            }

        case .noUpdate:
            HStack {
                if let lastCheck = updater.lastCheckFormatted {
                    Text("Last check: \(lastCheck)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: closeWindow)
                    .keyboardShortcut(.defaultAction)
            }

        case .available:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Button("Skip This Version") {
                        updater.skipAvailableUpdate()
                        closeWindow()
                    }
                    Spacer()
                    Button("Remind Me Later") {
                        updater.remindLater()
                        closeWindow()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Download Update") { updater.downloadAvailableUpdate() }
                        .keyboardShortcut(.defaultAction)
                }

                VStack(alignment: .trailing, spacing: 8) {
                    Button("Skip This Version") {
                        updater.skipAvailableUpdate()
                        closeWindow()
                    }
                    Button("Remind Me Later") {
                        updater.remindLater()
                        closeWindow()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Download Update") { updater.downloadAvailableUpdate() }
                        .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

        case .downloading:
            EmptyView()

        case .downloadComplete:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Button("Show in Finder") { updater.revealDownloadedInFinder() }
                    Spacer()
                    Button("Close", action: closeWindow)
                        .keyboardShortcut(.cancelAction)
                    Button("Quit EasyTier") { updater.quitEasyTier() }
                        .keyboardShortcut(.defaultAction)
                }

                VStack(alignment: .trailing, spacing: 8) {
                    Button("Show in Finder") { updater.revealDownloadedInFinder() }
                    Button("Close", action: closeWindow)
                        .keyboardShortcut(.cancelAction)
                    Button("Quit EasyTier") { updater.quitEasyTier() }
                        .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

        case .failed:
            HStack(spacing: 8) {
                Spacer()
                Button("Close", action: closeWindow)
                    .keyboardShortcut(.cancelAction)
                Button("Retry") { updater.checkForUpdates(origin: .manual) }
                    .keyboardShortcut(.defaultAction)
            }

        case .downloadFailed:
            retryDownloadActions

        case .verificationFailed:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Button("Report Issue") { updater.openIssueTracker() }
                        .buttonStyle(.link)
                    Spacer()
                    Button("Close", action: closeWindow)
                        .keyboardShortcut(.cancelAction)
                    Button("Try Again") { updater.downloadAvailableUpdate() }
                        .keyboardShortcut(.defaultAction)
                }

                VStack(alignment: .trailing, spacing: 8) {
                    Button("Report Issue") { updater.openIssueTracker() }
                        .buttonStyle(.link)
                    Button("Close", action: closeWindow)
                        .keyboardShortcut(.cancelAction)
                    Button("Try Again") { updater.downloadAvailableUpdate() }
                        .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

        case .idle:
            HStack(spacing: 8) {
                Spacer()
                Button("Close", action: closeWindow)
                    .keyboardShortcut(.cancelAction)
                Button("Check for Updates") { updater.checkForUpdates(origin: .manual) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var retryDownloadActions: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Close", action: closeWindow)
                .keyboardShortcut(.cancelAction)
            Button("Try Again") { updater.downloadAvailableUpdate() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var headerTitle: String {
        switch updater.state {
        case .checking: "Checking for Updates…"
        case .noUpdate: "You're Up to Date"
        case .available(let update, _, _): "EasyTier \(update.version) is available"
        case .downloading: "Downloading Update"
        case .downloadComplete: "Download Complete"
        case .failed: "Check Failed"
        case .downloadFailed: "Download Failed"
        case .verificationFailed: "Verification Failed"
        case .idle: "Software Update"
        }
    }

    private var headerSubtitle: String {
        switch updater.state {
        case .checking: "Contacting the update service…"
        case .noUpdate(let currentVersion): "Version \(currentVersion)"
        case .available(_, let currentVersion, _): "You have EasyTier \(currentVersion)."
        case .downloading(let update, _): "Version \(update.version)"
        case .downloadComplete(let update, _): "EasyTier \(update.version) is ready for manual installation."
        case .failed: "We couldn't check for updates right now."
        case .downloadFailed: "The update couldn't be downloaded."
        case .verificationFailed: "The downloaded file didn't match the published checksum."
        case .idle: "Stable releases only."
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
        case .downloadComplete: "downloadComplete"
        }
    }

    private func closeWindow() {
        dismissWindow(id: EasyTierWindowID.softwareUpdate)
    }

    private func byteFormatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func downloadedSizeText(update: EasyTierAvailableUpdate, progress: Double) -> String {
        let downloadedBytes = Int64((Double(update.asset.size) * min(max(progress, 0), 1)).rounded())
        return "\(byteFormatted(downloadedBytes)) of \(byteFormatted(update.asset.size))"
    }

    private func architectureLabel(_ architecture: String) -> String {
        switch architecture {
        case "arm64": "Apple silicon"
        case "x86_64": "Intel"
        default: architecture
        }
    }

    private static let maximumScrollableContentHeight: CGFloat = 360

    private enum ErrorKind {
        case checkFailed
        case downloadFailed(update: EasyTierAvailableUpdate)
        case verificationFailed(update: EasyTierAvailableUpdate)

        var systemImage: String {
            switch self {
            case .checkFailed: "wifi.exclamationmark"
            case .downloadFailed: "arrow.down.circle"
            case .verificationFailed: "shield.lefthalf.filled"
            }
        }

        var recoveryHint: String {
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

private struct SoftwareUpdateAppIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(iconBackground)
            .overlay {
                if let image = EasyTierIconResource.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(5)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.14), radius: 6, x: 0, y: 3)
            .accessibilityLabel(Text("EasyTier app icon"))
    }

    private var iconBackground: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(nsColor: .controlBackgroundColor).opacity(0.86), Color(nsColor: .underPageBackgroundColor).opacity(0.72)]
                : [Color.white.opacity(0.96), Color(nsColor: .controlBackgroundColor).opacity(0.88)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
