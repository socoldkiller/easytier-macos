import Foundation

public struct SystemMagicDNSCacheRefresher: MagicDNSCacheRefreshing {
    public init() {}

    public func refresh() throws {
        var firstError: (any Error)?

        do {
            try Self.run(executable: "/usr/bin/dscacheutil", arguments: ["-flushcache"])
        } catch {
            firstError = error
        }

        do {
            try Self.run(executable: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
        } catch {
            if firstError == nil {
                firstError = error
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private static func run(executable: String, arguments: [String]) throws {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw MagicDNSCacheRefreshError.launchFailed(
                executable: executable,
                message: error.localizedDescription
            )
        }

        process.waitUntilExit()
        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == EXIT_SUCCESS else {
            throw MagicDNSCacheRefreshError.commandFailed(
                executable: executable,
                status: process.terminationStatus,
                output: output
            )
        }
    }
}
