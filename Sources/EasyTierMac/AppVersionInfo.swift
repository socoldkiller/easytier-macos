import Foundation

struct AppVersionInfo: Equatable {
    var version: String
    var build: String
    var rawBuild: String
    var bundleIdentifier: String
    var buildChannel: SoftwareUpdateTrack

    var displayVersion: String {
        buildChannel == .nightly ? "\(version) Nightly" : version
    }

    static var current: AppVersionInfo {
        AppVersionInfo(bundle: .main)
    }

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        let bundleVersion = info["CFBundleVersion"] as? String

        version = info["CFBundleShortVersionString"] as? String ?? "Development"
        rawBuild = bundleVersion ?? "0"
        build = Self.formattedBuildTime(from: info["EasyTierBuildTime"] as? String)
            ?? Self.formattedExecutableModificationDate(bundle: bundle)
            ?? Self.formattedBuildTime(from: bundleVersion)
            ?? "Local"
        bundleIdentifier = bundle.bundleIdentifier ?? "com.kkrainbow.easytier.mac"
        buildChannel = (info["EasyTierBuildChannel"] as? String)
            .flatMap(SoftwareUpdateTrack.init(rawValue:)) ?? .stable
    }

    private static func formattedExecutableModificationDate(bundle: Bundle) -> String? {
        guard let executableURL = bundle.executableURL,
              let values = try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else { return nil }
        return formattedBuildDate(date)
    }

    private static func formattedBuildTime(from rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return nil
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: rawValue) {
            return formattedBuildDate(date)
        }

        let compactFormatter = DateFormatter()
        compactFormatter.locale = Locale(identifier: "en_US_POSIX")
        compactFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        compactFormatter.dateFormat = "yyyyMMddHHmmss"
        if let date = compactFormatter.date(from: rawValue) {
            return formattedBuildDate(date)
        }

        return nil
    }

    private static func formattedBuildDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
