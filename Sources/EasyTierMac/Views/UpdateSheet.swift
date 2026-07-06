import AppKit
import EasyTierShared
import SwiftUI

struct UpdateSheet: View {
    @Environment(SoftwareUpdateController.self) private var updater
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var iconBounce = false
    @State private var breathe = false

    private var needsPulse: Bool {
        switch updater.state {
        case .checking, .downloading: true
        default: false
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            UpdateSheetAppIcon()
                .frame(width: 48, height: 48)
                .scaleEffect(iconBounce ? 1.1 : 1.0)
                .opacity(breathe ? 0.7 : 1.0)
                .accessibilityHidden(true)
                .onChange(of: statusKey) { _, _ in
                    triggerBounce()
                    updatePulse()
                }
                .onAppear {
                    triggerBounce()
                    updatePulse()
                }

            rightColumn
        }
        .padding(.top, 16)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(width: 440, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .presentationBackground { FrostedGlass() }
        .presentedSurfaceMotion()
        .hideScrollViewScrollers()
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if !headerSubtitle.isEmpty {
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
                .frame(maxWidth: .infinity)
                .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: statusKey)

            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

        case .available(let update, _):
            HStack(spacing: 8) {
                Text("\(ByteCountFormatter.string(fromByteCount: update.asset.size, countStyle: .file)) · \(update.architecture)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("View Release Notes") { updater.openReleaseNotes() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

        case .downloading(let update, let progress):
            downloadProgress(update: update, progress: progress)

        case .readyToInstall:
            EmptyView()

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

    private func downloadProgress(update: EasyTierAvailableUpdate, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing download…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") { updater.cancelDownload() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }

            if let progress {
                Text("\(downloadedSizeText(update: update, progress: progress)) · \(Int((progress * 100).rounded()))%")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    private func errorGuidance(message: String, kind: ErrorKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            } icon: {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(.orange)
            }

            if let recovery = kind.recoveryHint {
                Text(recovery)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
            }
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
                if let lastCheck = updater.lastCheckFormatted {
                    Text("Last check: \(lastCheck)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

        case .available:
            HStack(spacing: 4) {
                Button("Skip This Version") { updater.skipAvailableUpdate() }
                    .buttonStyle(.link)
                    .font(.caption)
                Button("Remind Me Later") { updater.remindLater() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Download") { updater.downloadAvailableUpdate() }
                    .keyboardShortcut(.defaultAction)
            }

        case .downloading:
            EmptyView()

        case .readyToInstall:
            HStack {
                Button("Close") { dismiss() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Quit EasyTier") { updater.quitEasyTier() }
                    .keyboardShortcut(.defaultAction)
            }

        case .failed:
            HStack {
                Spacer()
                Button("Retry") { updater.checkForUpdates() }
                    .keyboardShortcut(.defaultAction)
            }

        case .downloadFailed:
            HStack {
                Spacer()
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
                .buttonStyle(.link)
                .font(.caption)
                Spacer()
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
        case .available: "Update Available"
        case .downloading: "Downloading Update"
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
        case .available(let update, let currentVersion): "Version \(currentVersion) → \(update.version)"
        case .downloading(let update, _): "Version \(update.version)"
        case .readyToInstall(let update, _): "Version \(update.version) has been downloaded."
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

    private func triggerBounce() {
        guard !reduceMotion else { return }
        iconBounce = true
        withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) {
            iconBounce = false
        }
    }

    private func updatePulse() {
        if needsPulse, !reduceMotion {
            breathe = false
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                breathe = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                breathe = false
            }
        }
    }

    private func byteFormatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func downloadedSizeText(update: EasyTierAvailableUpdate, progress: Double) -> String {
        let downloadedBytes = Int64((Double(update.asset.size) * min(max(progress, 0), 1)).rounded())
        return "\(byteFormatted(downloadedBytes)) of \(byteFormatted(update.asset.size))"
    }

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

private struct UpdateSheetAppIcon: View {
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
