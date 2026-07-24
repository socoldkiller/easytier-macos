import Foundation

struct SettingsSourceRevisionInfo: Equatable {
    let guiCommit: String
    let coreVersion: String

    static var current: SettingsSourceRevisionInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundledGUI = normalized(info["EasyTierGUICommit"] as? String)
        let bundledCoreTag = normalized(info["EasyTierCoreTag"] as? String)
        let bundledCore = normalized(info["EasyTierCoreCommit"] as? String)

        return SettingsSourceRevisionInfo(
            guiCommit: abbreviated(bundledGUI) ?? "unknown",
            coreVersion: joinedVersion(tag: bundledCoreTag, commit: bundledCore)
        )
    }

    private static func joinedVersion(tag: String?, commit: String?) -> String {
        let abbreviatedCommit = abbreviated(commit)
        if let tag, let abbreviatedCommit, !tag.contains(abbreviatedCommit) {
            return "\(tag) · \(abbreviatedCommit)"
        }
        return tag ?? abbreviatedCommit ?? "unknown"
    }

    private static func abbreviated(_ value: String?) -> String? {
        guard let value else { return nil }
        let isFullCommit = value.count == 40 && value.allSatisfy(\.isHexDigit)
        return isFullCommit ? String(value.prefix(8)) : value
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "unknown" else { return nil }
        return value
    }
}
