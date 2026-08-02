import Darwin
import Foundation

/// Persists the Config Server bootstrap credential for the root privileged
/// helper.
///
/// Design note: unlike user-facing network secrets (which live in the macOS
/// Keychain via `SystemNetworkSecretStore`), this store uses a root-owned
/// `0600` file. The helper runs as root under `SMAppService`; sharing the
/// user Keychain from that context requires a Keychain access group in both
/// the app and helper entitlements plus signed release-gate coverage. Until
/// that exists, a root-owned directory (`0700`) and file (`0600`) with
/// atomic writes and fsync provides equivalent confidentiality against other
/// local users while keeping the helper self-contained. Revisit if the
/// account token ever needs to survive helper reinstall or be readable by
/// the app outside the helper.
package enum RemoteAccountCredentialStoreError: LocalizedError, Equatable {
    case unsafePath(String)
    case invalidPermissions(String)
    case invalidLibrary(String)
    case posix(Int32)

    package var errorDescription: String? {
        switch self {
        case let .unsafePath(path): "Unsafe remote account credential path: \(path)"
        case let .invalidPermissions(path): "Invalid remote account credential permissions: \(path)"
        case let .invalidLibrary(message): "Invalid remote account credential library: \(message)"
        case let .posix(code): String(cString: strerror(code))
        }
    }
}

package struct RemoteAccountCredentialStore: Sendable {
    package static let defaultDirectory = URL(
        fileURLWithPath: "/Library/Application Support/com.kkrainbow.easytier.mac.helper/RemoteAccount",
        isDirectory: true
    )

    package let baseDirectory: URL
    private let requiresRootOwnership: Bool

    package init(baseDirectory: URL = Self.defaultDirectory, requiresRootOwnership: Bool = true) {
        self.baseDirectory = baseDirectory
        self.requiresRootOwnership = requiresRootOwnership
    }

    package func save(_ library: RemoteAccountCredentialLibrary) throws {
        try validateLibrary(library)
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try atomicWrite(encoder.encode(library), to: credentialURL)
    }

    package func load() throws -> RemoteAccountCredentialLibrary {
        try prepareDirectory()
        guard FileManager.default.fileExists(atPath: credentialURL.path) else {
            return RemoteAccountCredentialLibrary()
        }
        try validateFile(credentialURL)
        let library = try JSONDecoder().decode(
            RemoteAccountCredentialLibrary.self,
            from: Data(contentsOf: credentialURL)
        )
        try validateLibrary(library)
        return library
    }

    package func remove() throws {
        guard FileManager.default.fileExists(atPath: credentialURL.path) else { return }
        try validateFile(credentialURL)
        guard unlink(credentialURL.path) == 0 else { throw RemoteAccountCredentialStoreError.posix(errno) }
        try syncDirectory()
    }

    private var credentialURL: URL { baseDirectory.appending(path: "credential-library.json") }
    private var deprecatedCredentialURL: URL { baseDirectory.appending(path: "credential.json") }

    private func validateLibrary(_ library: RemoteAccountCredentialLibrary) throws {
        guard library.formatVersion == RemoteAccountCredentialLibrary.currentFormatVersion else {
            throw RemoteAccountCredentialStoreError.invalidLibrary(
                "unsupported format version \(library.formatVersion)"
            )
        }
        let ids = library.records.map(\.accountID)
        guard Set(ids).count == ids.count else {
            throw RemoteAccountCredentialStoreError.invalidLibrary("duplicate account identifiers")
        }
        if let activeAccountID = library.activeAccountID,
           !ids.contains(activeAccountID)
        {
            throw RemoteAccountCredentialStoreError.invalidLibrary("active account has no credential")
        }
    }

    private func prepareDirectory() throws {
        var info = stat()
        if lstat(baseDirectory.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw RemoteAccountCredentialStoreError.unsafePath(baseDirectory.path)
            }
            try validate(info, path: baseDirectory.path, maximumPermissions: 0o700)
            try removeDeprecatedCredentialFile()
            return
        }
        guard errno == ENOENT else { throw RemoteAccountCredentialStoreError.posix(errno) }
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        guard chmod(baseDirectory.path, 0o700) == 0 else { throw RemoteAccountCredentialStoreError.posix(errno) }
        if requiresRootOwnership, chown(baseDirectory.path, 0, 0) != 0 {
            throw RemoteAccountCredentialStoreError.posix(errno)
        }
    }

    private func removeDeprecatedCredentialFile() throws {
        guard FileManager.default.fileExists(atPath: deprecatedCredentialURL.path) else { return }
        try validateFile(deprecatedCredentialURL)
        guard unlink(deprecatedCredentialURL.path) == 0 else {
            throw RemoteAccountCredentialStoreError.posix(errno)
        }
        try syncDirectory()
    }

    private func validateFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw RemoteAccountCredentialStoreError.posix(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw RemoteAccountCredentialStoreError.unsafePath(url.path)
        }
        try validate(info, path: url.path, maximumPermissions: 0o600)
    }

    private func validate(_ info: stat, path: String, maximumPermissions: mode_t) throws {
        guard ((info.st_mode & 0o777) & ~maximumPermissions) == 0,
              !requiresRootOwnership || info.st_uid == 0
        else { throw RemoteAccountCredentialStoreError.invalidPermissions(path) }
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = baseDirectory.appending(path: ".credential.\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RemoteAccountCredentialStoreError.posix(errno) }
        var removeTemporary = true
        defer {
            close(descriptor)
            if removeTemporary { unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw RemoteAccountCredentialStoreError.posix(errno) }
                offset += count
            }
        }
        guard fchmod(descriptor, 0o600) == 0,
              !requiresRootOwnership || fchown(descriptor, 0, 0) == 0,
              fsync(descriptor) == 0,
              rename(temporary.path, destination.path) == 0
        else { throw RemoteAccountCredentialStoreError.posix(errno) }
        removeTemporary = false
        try syncDirectory()
    }

    private func syncDirectory() throws {
        let descriptor = open(baseDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RemoteAccountCredentialStoreError.posix(errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw RemoteAccountCredentialStoreError.posix(errno) }
    }
}
