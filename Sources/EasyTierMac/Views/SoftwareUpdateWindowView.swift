import EasyTierShared
import SwiftUI

struct SoftwareUpdateWindowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var controller: SoftwareUpdateController

    private let background = Color(red: 0.19, green: 0.21, blue: 0.21)
    private let primaryText = Color.white.opacity(0.88)
    private let secondaryText = Color.white.opacity(0.62)
    private let mutedText = Color.white.opacity(0.42)

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                EasyTierMark()
                    .frame(width: 82, height: 82)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 14) {
                    MotionSwitch(id: controller.state.titleMotionID, insertionEdge: .trailing, fillsAvailableSpace: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            titleBlock
                        }
                    }

                    MotionSwitch(id: controller.state.progressMotionID, insertionEdge: .bottom, fillsAvailableSpace: false) {
                        progressBlock
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 50)
            .padding(.top, 34)
            .padding(.bottom, 24)

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                MotionSwitch(id: controller.state.leadingActionMotionID, insertionEdge: .leading, fillsAvailableSpace: false) {
                    leadingButtons
                }
                Spacer(minLength: 0)
                MotionSwitch(id: controller.state.trailingActionMotionID, insertionEdge: .trailing, fillsAvailableSpace: false) {
                    trailingButtons
                }
            }
            .padding(.horizontal, 38)
            .padding(.bottom, 28)
        }
        .frame(width: 620, height: 292)
        .background(background)
        .foregroundStyle(primaryText)
        .environment(\.colorScheme, .dark)
        .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: controller.state.titleMotionID)
        .presentedSurfaceMotion()
    }

    @ViewBuilder
    private var titleBlock: some View {
        switch controller.state {
        case .idle, .checking:
            Text("Checking for updates...")
                .font(.system(size: 24, weight: .bold))
            Text("EasyTier is checking the stable release feed.")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(secondaryText)
        case .noUpdate(let currentVersion):
            Text("EasyTier is up to date.")
                .font(.system(size: 24, weight: .bold))
            Text("EasyTier \(currentVersion) is the newest stable version available.")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(secondaryText)
        case .available(let update, let currentVersion):
            Text("A new version of EasyTier is available.")
                .font(.system(size: 24, weight: .bold))
            Text("EasyTier \(update.version) is now available—you have \(currentVersion).")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(secondaryText)
        case .downloading(let update, _):
            Text("Downloading EasyTier \(update.version)...")
                .font(.system(size: 24, weight: .bold))
            Text("The DMG will be saved to Downloads and opened after verification.")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(secondaryText)
        case .failed:
            Text("Unable to check for updates.")
                .font(.system(size: 24, weight: .bold))
            errorText
        case .downloadFailed(let update, _):
            Text("Unable to download EasyTier \(update.version).")
                .font(.system(size: 24, weight: .bold))
            errorText
        case .verificationFailed(let update, _):
            Text("Unable to verify EasyTier \(update.version).")
                .font(.system(size: 24, weight: .bold))
            errorText
        case .readyToInstall(let update, _):
            Text("EasyTier \(update.version) is ready to install.")
                .font(.system(size: 24, weight: .bold))
            Text("The old helper registration was removed. Drag EasyTier.app to Applications, quit this copy, then install the helper from the new app.")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(secondaryText)
        }
    }

    @ViewBuilder
    private var progressBlock: some View {
        switch controller.state {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .downloading(_, let progress):
            if let progress {
                ProgressView(value: progress)
                    .frame(maxWidth: 330)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(mutedText)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .available, .downloadFailed, .verificationFailed:
            if controller.state.visibleUpdate != nil {
                Button("Release Notes") { controller.openReleaseNotes() }
                    .buttonStyle(.link)
                    .font(.system(size: 13, weight: .regular))
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let message = controller.state.errorMessage {
            Text(message)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var leadingButtons: some View {
        switch controller.state {
        case .available:
            Button("Skip This Version") { controller.skipAvailableUpdate() }
                .controlSize(.large)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailingButtons: some View {
        switch controller.state {
        case .checking, .idle:
            Button("Close") { controller.remindLater() }
                .controlSize(.large)
        case .noUpdate, .failed:
            Button("OK") { controller.remindLater() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .available:
            Button("Remind Me Later") { controller.remindLater() }
                .controlSize(.large)
            Button("Download Update") { controller.downloadAvailableUpdate() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .downloading:
            Button("Downloading...") {}
                .controlSize(.large)
                .disabled(true)
        case .downloadFailed, .verificationFailed:
            Button("Remind Me Later") { controller.remindLater() }
                .controlSize(.large)
            Button("Try Again") { controller.downloadAvailableUpdate() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .readyToInstall:
            Button("Remind Me Later") { controller.remindLater() }
                .controlSize(.large)
            Button("Quit EasyTier") { controller.quitEasyTier() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private extension SoftwareUpdateState {
    var errorMessage: String? {
        switch self {
        case .failed(let message), .downloadFailed(_, let message), .verificationFailed(_, let message):
            return message
        default:
            return nil
        }
    }

    var titleMotionID: String {
        switch self {
        case .idle:
            "idle"
        case .checking:
            "checking"
        case .noUpdate(let currentVersion):
            "no-update-\(currentVersion)"
        case .available(let update, let currentVersion):
            "available-\(update.version)-\(currentVersion)"
        case .downloading(let update, _):
            "downloading-\(update.version)"
        case .failed:
            "failed"
        case .downloadFailed(let update, _):
            "download-failed-\(update.version)"
        case .verificationFailed(let update, _):
            "verification-failed-\(update.version)"
        case .readyToInstall(let update, _):
            "ready-\(update.version)"
        }
    }

    var progressMotionID: String {
        switch self {
        case .checking:
            "checking-progress"
        case .downloading(_, let progress):
            progress == nil ? "download-indeterminate" : "download-progress"
        case .available, .downloadFailed, .verificationFailed:
            "release-notes"
        default:
            "empty-progress"
        }
    }

    var leadingActionMotionID: String {
        switch self {
        case .available:
            "skip"
        default:
            "empty-leading"
        }
    }

    var trailingActionMotionID: String {
        switch self {
        case .checking, .idle:
            "close"
        case .noUpdate, .failed:
            "ok"
        case .available:
            "download"
        case .downloading:
            "downloading"
        case .downloadFailed, .verificationFailed:
            "retry"
        case .readyToInstall:
            "quit"
        }
    }
}

#Preview("Available") {
    let controller = SoftwareUpdateController()
    controller.state = .available(SoftwareUpdatePreviewData.sampleUpdate, currentVersion: "0.1.0")
    return SoftwareUpdateWindowView(controller: controller)
}

#Preview("Downloading") {
    let controller = SoftwareUpdateController()
    controller.state = .downloading(SoftwareUpdatePreviewData.sampleUpdate, progress: 0.42)
    return SoftwareUpdateWindowView(controller: controller)
}

#Preview("Ready") {
    let controller = SoftwareUpdateController()
    controller.state = .readyToInstall(SoftwareUpdatePreviewData.sampleUpdate, fileURL: URL(fileURLWithPath: "/tmp/EasyTier.dmg"))
    return SoftwareUpdateWindowView(controller: controller)
}

private enum SoftwareUpdatePreviewData {
    static var sampleUpdate: EasyTierAvailableUpdate {
        EasyTierAvailableUpdate(
            version: "0.2.0",
            build: "20260615123000",
            tag: "v0.2.0",
            releaseNotesURL: URL(string: "https://github.com/socoldkiller/easytier-swift/releases/tag/v0.2.0")!,
            architecture: "arm64",
            asset: EasyTierUpdateAsset(
                url: URL(string: "https://github.com/socoldkiller/easytier-swift/releases/download/v0.2.0/EasyTier-macOS-ARM64.dmg")!,
                sha256: String(repeating: "a", count: 64),
                size: 123_456
            )
        )
    }
}
