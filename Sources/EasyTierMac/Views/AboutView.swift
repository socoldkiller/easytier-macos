import SwiftUI

struct AboutView: View {
    @Environment(SoftwareUpdateController.self) private var updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let appInfo = AppVersionInfo.current
    private let revisions = SourceRevisionInfo.current

    var body: some View {
        VStack(spacing: 0) {
            content

            Divider()
                .padding(.horizontal, 32)

            maintenance
        }
        .frame(width: 620, height: 400)
        .foregroundStyle(.primary)
        .presentedSurfaceMotion()
    }

    private var content: some View {
        VStack(spacing: 24) {
            HStack(alignment: .center, spacing: 34) {
                EasyTierMark()
                    .frame(width: 118, height: 118)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("EasyTier for macOS")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Native GUI for managing EasyTier networks.")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        MetadataRow(label: "GUI", value: "\(appInfo.version) · \(revisions.guiCommit)")
                        MetadataRow(label: "Core", value: revisions.coreVersion)
                        MetadataRow(label: "Build", value: appInfo.build)
                    }

                    HStack(spacing: 14) {
                        Link("Docs", destination: URL(string: "https://easytier.cn")!)
                        Link("Releases", destination: URL(string: "https://github.com/socoldkiller/easytier-swift/releases")!)
                        Link("GitHub", destination: URL(string: "https://github.com/socoldkiller/easytier-swift")!)
                        Link("License", destination: URL(string: "https://github.com/socoldkiller/easytier-swift/blob/main/LICENSE")!)
                    }
                    .font(.system(size: 11, weight: .regular))
                    .controlSize(.small)
                    .padding(.top, 2)

                    Link("Report an Issue...", destination: URL(string: "https://github.com/socoldkiller/easytier-swift/issues")!)
                        .font(.system(size: 12, weight: .regular))
                        .controlSize(.small)
                        .padding(.top, 1)
                }
                .frame(width: 300, alignment: .leading)
            }

            Text("EasyTier is distributed under LGPL-3.0. © 2026 EasyTier contributors.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 18)
    }

    private var maintenance: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Software Update")
                    .font(.system(size: 12, weight: .semibold))
                Text("Manual stable release checks from GitHub.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 7) {
                Button(updater.isChecking ? "Checking..." : "Check Now") { updater.checkForUpdates(presentsWindow: false) }
                    .font(.system(size: 12, weight: .regular))
                    .controlSize(.small)
                    .disabled(updater.isChecking)
                updateStatusLine
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
    }

    private var updateStatusLine: some View {
        HStack(spacing: 5) {
            if isUpToDate {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.green.opacity(0.82))
            }
            Text(updateStatusText)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 13, alignment: .trailing)
        .contentTransition(.opacity)
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: updateStatusText)
    }

    private var updateStatusText: String {
        switch updater.state {
        case .checking:
            return "Checking stable releases..."
        case .noUpdate:
            return "EasyTier is already the latest version."
        case .available(let update, _):
            return "EasyTier \(update.version) is available."
        case .downloading:
            return "Downloading update..."
        case .readyToInstall:
            return "DMG opened. Quit before replacing EasyTier."
        case .failed, .downloadFailed, .verificationFailed:
            return "Updater needs attention."
        case .idle:
            return "Checks stable releases only."
        }
    }

    private var isUpToDate: Bool {
        if case .noUpdate = updater.state { return true }
        return false
    }
}

struct EasyTierMark: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("easytier-icon")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 10, x: 0, y: 5)
            .accessibilityLabel(Text("EasyTier app icon"))
    }
}

private struct MetadataRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

private struct SourceRevisionInfo: Equatable {
    var guiCommit: String
    var coreVersion: String

    static var current: SourceRevisionInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundledGUI = normalized(info["EasyTierGUICommit"] as? String)
        let bundledCoreTag = normalized(info["EasyTierCoreTag"] as? String)
        let bundledCore = normalized(info["EasyTierCoreCommit"] as? String)

        return SourceRevisionInfo(
            guiCommit: bundledGUI ?? "unknown",
            coreVersion: bundledCoreTag ?? bundledCore ?? "unknown"
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "unknown" else { return nil }
        return value
    }
}
