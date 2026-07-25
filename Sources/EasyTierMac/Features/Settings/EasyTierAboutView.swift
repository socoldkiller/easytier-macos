import SwiftUI

struct EasyTierAboutView: View {
    private let appInfo = AppVersionInfo.current
    private let revisions = SettingsSourceRevisionInfo.current

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 6) {
                EasyTierMark()
                    .frame(width: 64, height: 64)

                Text("EasyTier for macOS")
                    .font(.title2)
                    .bold()

                Text("Version \(appInfo.displayVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text("A native macOS client for EasyTier networks.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            SettingsForm {
                Section("Version Information") {
                    SettingsMetadataRow(label: "GUI Version", value: appInfo.version)
                    SettingsMetadataRow(label: "GUI Revision", value: revisions.guiCommit)
                    SettingsMetadataRow(label: "Core Version", value: revisions.coreVersion)
                    SettingsMetadataRow(label: "Build Time", value: buildTime)
                    SettingsMetadataRow(
                        label: "Release Channel",
                        value: appInfo.buildChannel.buildDisplayName
                    )
                }

                Section {
                    LabeledContent("EasyTier for macOS") {
                        Link("socoldkiller and contributors", destination: Self.guiContributorsURL)
                    }
                    LabeledContent("EasyTier Core") {
                        Link("EasyTier contributors", destination: Self.coreContributorsURL)
                    }
                } header: {
                    Text("Contributors")
                } footer: {
                    Text("EasyTier is built and maintained by its open-source community.")
                }

                Section("Resources") {
                    LabeledContent("Documentation") {
                        Link("easytier.cn", destination: Self.docsURL)
                    }
                    LabeledContent("Source Code") {
                        Link("GitHub", destination: Self.githubURL)
                    }
                    LabeledContent("Releases") {
                        Link("View Releases", destination: Self.releasesURL)
                    }
                    LabeledContent("License") {
                        Link("MIT License", destination: Self.licenseURL)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
    }

    private var buildTime: String {
        let bundledValue = Bundle.main.infoDictionary?["EasyTierBuildTime"] as? String
        return bundledValue == "1970-01-01T00:00:00Z" ? "Local Build" : appInfo.build
    }

    private static let docsURL = URL(string: "https://easytier.cn") ?? URL(filePath: "/")
    private static let releasesURL = URL(
        string: "https://github.com/socoldkiller/easytier-macos/releases"
    ) ?? URL(filePath: "/")
    private static let githubURL = URL(
        string: "https://github.com/socoldkiller/easytier-macos"
    ) ?? URL(filePath: "/")
    private static let licenseURL = URL(
        string: "https://github.com/socoldkiller/easytier-macos/blob/main/LICENSE"
    ) ?? URL(filePath: "/")
    private static let guiContributorsURL = URL(
        string: "https://github.com/socoldkiller/easytier-macos/graphs/contributors"
    ) ?? URL(filePath: "/")
    private static let coreContributorsURL = URL(
        string: "https://github.com/EasyTier/EasyTier/graphs/contributors"
    ) ?? URL(filePath: "/")
}
