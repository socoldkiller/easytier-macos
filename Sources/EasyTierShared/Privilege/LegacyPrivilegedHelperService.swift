import Foundation

public enum LegacyPrivilegedHelperService {
    public static let helperPath = "/Library/PrivilegedHelperTools/\(EasyTierPrivilegedHelperConstants.bundleIdentifier)"
    public static let launchDaemonPath = "/Library/LaunchDaemons/\(EasyTierPrivilegedHelperConstants.launchDaemonPlistName)"

    public static var shouldUseLegacyInstaller: Bool {
        guard let helperURL = bundledHelperURL else { return false }
        let appTeam = codeSigningTeamIdentifier(at: Bundle.main.bundleURL)
        let helperTeam = codeSigningTeamIdentifier(at: helperURL)
        return appTeam == nil || helperTeam == nil
    }

    public static var isInstalled: Bool {
        let result = run("/bin/launchctl", ["print", "system/\(EasyTierPrivilegedHelperConstants.bundleIdentifier)"])
        guard result.status == 0 else { return false }
        return result.output.contains(launchDaemonPath)
            || result.output.contains(helperPath)
            || !result.output.contains("managed_by = com.apple.xpc.ServiceManagement")
    }

    public static func installUsingAdministratorPrivileges() throws {
        guard let helperURL = bundledHelperURL else {
            throw LegacyInstallerError.missingBundledHelper
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw LegacyInstallerError.missingBundledHelper
        }

        try runAdministratorShellScript(installScript(helperSourcePath: helperURL.path))
    }

    public static func uninstallUsingAdministratorPrivileges() throws {
        try runAdministratorShellScript(uninstallScript())
    }

    private static var bundledHelperURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("EasyTierPrivilegedHelper", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func codeSigningTeamIdentifier(at url: URL) -> String? {
        let result = run("/usr/bin/codesign", ["-dv", "--verbose=4", url.path])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return value == "not set" || value.isEmpty ? nil : value
        }
        return nil
    }

    private static func installScript(helperSourcePath: String) -> String {
        let label = EasyTierPrivilegedHelperConstants.bundleIdentifier
        let helperSource = shellQuote(helperSourcePath)
        let helperDestination = shellQuote(helperPath)
        let plistDestination = shellQuote(launchDaemonPath)
        let plist = launchDaemonPlist().replacingOccurrences(of: "'", with: "'\\''")

        return """
        set -e
        /bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true
        /bin/rm -f \(plistDestination) \(helperDestination)
        /usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        /usr/bin/install -d -o root -g wheel -m 755 /Library/LaunchDaemons
        /usr/bin/install -o root -g wheel -m 755 \(helperSource) \(helperDestination)
        /bin/cat > \(plistDestination) <<'PLIST'
        \(plist)
        PLIST
        /usr/sbin/chown root:wheel \(plistDestination) \(helperDestination)
        /bin/chmod 644 \(plistDestination)
        /bin/chmod 755 \(helperDestination)
        /bin/launchctl bootstrap system \(plistDestination)
        /bin/launchctl enable system/\(label) >/dev/null 2>&1 || true
        /bin/launchctl kickstart -k system/\(label) >/dev/null 2>&1 || true
        """
    }

    private static func uninstallScript() -> String {
        let label = EasyTierPrivilegedHelperConstants.bundleIdentifier
        return """
        set -e
        /bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true
        /bin/rm -f \(shellQuote(launchDaemonPath)) \(shellQuote(helperPath))
        """
    }

    private static func launchDaemonPlist() -> String {
        let label = EasyTierPrivilegedHelperConstants.bundleIdentifier
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(helperPath)</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>\(EasyTierPrivilegedHelperConstants.machServiceName)</key>
                <true/>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/var/log/easytier-helper.log</string>
            <key>StandardErrorPath</key>
            <string>/var/log/easytier-helper.log</string>
        </dict>
        </plist>
        """
    }

    private static func runAdministratorShellScript(_ script: String) throws {
        let encoded = Data(script.utf8).base64EncodedString()
        let command = "/bin/echo \(shellQuote(encoded)) | /usr/bin/base64 -D | /bin/sh"
        let appleScript = "do shell script \(appleScriptString(command)) with administrator privileges"
        let result = run("/usr/bin/osascript", ["-e", appleScript])
        guard result.status == 0 else {
            throw LegacyInstallerError.administratorCommandFailed(result.output)
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (127, error.localizedDescription)
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

private enum LegacyInstallerError: LocalizedError {
    case missingBundledHelper
    case administratorCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBundledHelper:
            "Bundled privileged helper was not found inside EasyTier.app."
        case let .administratorCommandFailed(output):
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                "Administrator helper installation was cancelled or failed."
            } else {
                output
            }
        }
    }
}
