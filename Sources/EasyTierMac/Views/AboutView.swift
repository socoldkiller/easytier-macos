import AppKit
import EasyTierShared
import SwiftUI

struct AboutView: View {
    @Environment(EasyTierAppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var automaticUpdates = true
    @State private var unstableUpdates = false
    @State private var runtimeVersion = "Loading"

    private let appInfo = AppVersionInfo.current
    private let revisions = SourceRevisionInfo.current

    private let background = Color(red: 0.19, green: 0.21, blue: 0.21)
    private let markBackground = Color.black.opacity(0.24)
    private let primaryText = Color.white.opacity(0.86)
    private let secondaryText = Color.white.opacity(0.56)
    private let mutedText = Color.white.opacity(0.36)
    private let divider = Color.white.opacity(0.13)
    private let linkBlue = Color(red: 0.10, green: 0.55, blue: 0.95)

    var body: some View {
        VStack(spacing: 0) {
            content

            Divider()
                .overlay(divider)
                .padding(.horizontal, 32)

            maintenance
        }
        .frame(width: 620, height: 400)
        .background(background)
        .foregroundStyle(primaryText)
        .environment(\.colorScheme, .dark)
        .task { await loadRuntimeVersion() }
    }

    private var content: some View {
        VStack(spacing: 24) {
            HStack(alignment: .center, spacing: 34) {
                EasyTierMark(background: markBackground)
                    .frame(width: 118, height: 118)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("EasyTier for macOS")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.90))
                        Text("Native GUI for managing EasyTier networks.")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(secondaryText)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        MetadataRow(label: "GUI", value: "\(appInfo.version) · \(revisions.guiCommit)")
                        MetadataRow(label: "Core", value: revisions.coreVersion)
                        MetadataRow(label: "Runtime", value: runtimeLabel)
                        MetadataRow(label: "Build", value: appInfo.build)
                    }

                    HStack(spacing: 14) {
                        AboutLink("Docs", url: "https://easytier.cn", color: linkBlue)
                        AboutLink("Releases", url: "https://github.com/EasyTier/EasyTier/releases", color: linkBlue)
                        AboutLink("GitHub", url: "https://github.com/EasyTier/EasyTier", color: linkBlue)
                        AboutLink("License", url: "https://github.com/EasyTier/EasyTier/blob/main/LICENSE", color: linkBlue)
                    }
                    .padding(.top, 2)

                    Button("Report an Issue...") {}
                        .font(.system(size: 12, weight: .regular))
                        .disabled(true)
                        .padding(.top, 1)
                }
                .frame(width: 300, alignment: .leading)
            }

            Text("EasyTier is distributed under LGPL-3.0. © 2026 EasyTier contributors.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 18)
    }

    private var maintenance: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 10) {
                DisabledCheckboxRow(title: "Install updates automatically", isOn: $automaticUpdates, textColor: mutedText)
                DisabledCheckboxRow(title: "Include unstable releases", isOn: $unstableUpdates, textColor: primaryText)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 7) {
                Button("Check Now") {}
                    .font(.system(size: 12, weight: .regular))
                    .disabled(true)
                Text("Updater not connected yet.")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(secondaryText)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
    }

    private var runtimeLabel: String {
        switch runtimeVersion {
        case "EasyTier privileged helper":
            "Privileged helper"
        case "EasyTier FFI (static)":
            "Static FFI"
        default:
            runtimeVersion
        }
    }

    private func loadRuntimeVersion() async {
        do {
            let version = try await store.easyTierCoreVersion()
            runtimeVersion = version.isEmpty ? "Unavailable" : version
        } catch {
            runtimeVersion = "Unavailable"
        }
    }
}

private struct EasyTierMark: View {
    var background: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(background)
            .overlay {
                ConnectionGlyph(state: .connected, size: 66, templateMode: true)
                    .foregroundStyle(Color.white.opacity(0.72))
            }
    }
}

private struct MetadataRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.52))
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

private struct AboutLink: View {
    var title: String
    var url: String
    var color: Color

    init(_ title: String, url: String, color: Color) {
        self.title = title
        self.url = url
        self.color = color
    }

    var body: some View {
        Button(action: openURL) {
            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }

    private func openURL() {
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct DisabledCheckboxRow: View {
    var title: String
    @Binding var isOn: Bool
    var textColor: Color

    var body: some View {
        HStack(spacing: 7) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .controlSize(.small)
                .disabled(true)
            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(textColor)
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.42))
        }
    }
}

private struct AppVersionInfo: Equatable {
    var version: String
    var build: String
    var bundleIdentifier: String

    static var current: AppVersionInfo {
        AppVersionInfo(bundle: .main)
    }

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        version = info["CFBundleShortVersionString"] as? String ?? "Development"
        build = info["CFBundleVersion"] as? String ?? "Local"
        bundleIdentifier = bundle.bundleIdentifier ?? "com.kkrainbow.easytier.mac"
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
        let guiRoot = GitRevision.repositoryRoot(from: FileManager.default.currentDirectoryPath)
        let coreRoot = guiRoot.map { ($0 as NSString).appendingPathComponent("Vendor/EasyTier") }

        return SourceRevisionInfo(
            guiCommit: bundledGUI ?? guiRoot.flatMap { GitRevision.revision(at: $0) } ?? "unknown",
            coreVersion: bundledCoreTag ?? coreRoot.flatMap { GitRevision.exactTag(at: $0) } ?? bundledCore ?? coreRoot.flatMap { GitRevision.revision(at: $0) } ?? "unknown"
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "unknown" else { return nil }
        return value
    }
}

private enum GitRevision {
    static func repositoryRoot(from startPath: String) -> String? {
        var url = URL(fileURLWithPath: startPath, isDirectory: true)
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    static func revision(at path: String) -> String? {
        guard let commit = runGit(["-C", path, "rev-parse", "--short", "HEAD"]), !commit.isEmpty else { return nil }
        let status = runGit(["-C", path, "status", "--short", "--untracked-files=no"])
        return status?.isEmpty == false ? "\(commit)-dirty" : commit
    }

    static func exactTag(at path: String) -> String? {
        guard let tag = runGit(["-C", path, "describe", "--tags", "--exact-match", "HEAD"]), !tag.isEmpty else { return nil }
        let status = runGit(["-C", path, "status", "--short", "--untracked-files=no"])
        return status?.isEmpty == false ? "\(tag)-dirty" : tag
    }

    private static func runGit(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
