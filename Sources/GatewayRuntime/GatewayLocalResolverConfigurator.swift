import Foundation

package enum GatewayLocalResolverConfiguratorError: LocalizedError, Equatable, Sendable {
    case invalidDomain(String)
    case fileOwnedByAnotherProcess(String)
    case transactionFailed(change: String, rollback: String)

    package var errorDescription: String? {
        switch self {
        case let .invalidDomain(domain):
            "Invalid Gateway resolver domain: \(domain)"
        case let .fileOwnedByAnotherProcess(domain):
            "The resolver file for \(domain) already exists and is not managed by Gateway."
        case let .transactionFailed(change, rollback):
            "Gateway resolver update failed: \(change) Rollback failed: \(rollback)"
        }
    }
}

package struct GatewayLocalResolverConfigurator: @unchecked Sendable {
    package static let resolverFileHeader = "# Added by coldkiller gateway\n"

    private let resolverDirectory: URL
    private let nameserver: String
    private let port: UInt16
    private let fileManager: FileManager

    package init(
        resolverDirectory: URL = URL(fileURLWithPath: "/etc/resolver", isDirectory: true),
        nameserver: String = "127.0.0.1",
        port: UInt16 = 53_535,
        fileManager: FileManager = .default
    ) {
        self.resolverDirectory = resolverDirectory
        self.nameserver = nameserver
        self.port = port
        self.fileManager = fileManager
    }

    package func synchronize(domains: [String]) throws {
        let desiredDomains = try Set(domains.map(Self.validatedDomain))
        if desiredDomains.isEmpty,
           !fileManager.fileExists(atPath: resolverDirectory.path)
        {
            return
        }

        let snapshot = try managedFileSnapshot()
        try preflightOwnership(for: desiredDomains)

        do {
            try fileManager.createDirectory(at: resolverDirectory, withIntermediateDirectories: true)
            for domain in desiredDomains.sorted() {
                try writeManagedFile(domain: domain)
            }
            try removeManagedFiles(except: desiredDomains)
        } catch {
            let changeError = error.localizedDescription
            do {
                try restore(snapshot: snapshot)
            } catch {
                throw GatewayLocalResolverConfiguratorError.transactionFailed(
                    change: changeError,
                    rollback: error.localizedDescription
                )
            }
            throw error
        }
    }

    package func removeManagedResolverFiles() throws {
        try synchronize(domains: [])
    }

    private static func validatedDomain(_ rawDomain: String) throws -> String {
        var domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while domain.hasSuffix(".") {
            domain.removeLast()
        }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard !domain.isEmpty,
              domain.utf8.count <= 253,
              labels.count >= 2,
              labels.allSatisfy({ label in
                  guard !label.isEmpty,
                        label.utf8.count <= 63,
                        label.first != "-",
                        label.last != "-"
                  else { return false }
                  return label.utf8.allSatisfy { byte in
                      (byte >= 97 && byte <= 122) ||
                          (byte >= 48 && byte <= 57) ||
                          byte == 45
                  }
              })
        else {
            throw GatewayLocalResolverConfiguratorError.invalidDomain(rawDomain)
        }
        return domain
    }

    private func preflightOwnership(for domains: Set<String>) throws {
        for domain in domains {
            let url = resolverURL(for: domain)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            guard Self.isManaged(data) else {
                throw GatewayLocalResolverConfiguratorError.fileOwnedByAnotherProcess(domain)
            }
        }
    }

    private func managedFileSnapshot() throws -> [String: Data] {
        guard fileManager.fileExists(atPath: resolverDirectory.path) else { return [:] }
        var snapshot: [String: Data] = [:]
        for url in try regularFiles() {
            let data = try Data(contentsOf: url)
            if Self.isManaged(data) {
                snapshot[url.lastPathComponent] = data
            }
        }
        return snapshot
    }

    private func writeManagedFile(domain: String) throws {
        let content = """
        \(Self.resolverFileHeader)domain \(domain)
        nameserver \(nameserver)
        port \(port)
        timeout 1

        """
        let url = resolverURL(for: domain)
        try Data(content.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    private func removeManagedFiles(except keptDomains: Set<String>) throws {
        guard fileManager.fileExists(atPath: resolverDirectory.path) else { return }
        for url in try regularFiles() where !keptDomains.contains(url.lastPathComponent) {
            let data = try Data(contentsOf: url)
            guard Self.isManaged(data) else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private func restore(snapshot: [String: Data]) throws {
        if fileManager.fileExists(atPath: resolverDirectory.path) {
            for url in try regularFiles() {
                let data = try Data(contentsOf: url)
                if Self.isManaged(data) {
                    try fileManager.removeItem(at: url)
                }
            }
        } else if !snapshot.isEmpty {
            try fileManager.createDirectory(at: resolverDirectory, withIntermediateDirectories: true)
        }

        for (name, data) in snapshot {
            let url = resolverDirectory.appending(path: name, directoryHint: .notDirectory)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
    }

    private func regularFiles() throws -> [URL] {
        let entries = try fileManager.contentsOfDirectory(
            at: resolverDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return try entries.filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
    }

    private func resolverURL(for domain: String) -> URL {
        resolverDirectory.appending(path: domain, directoryHint: .notDirectory)
    }

    private static func isManaged(_ data: Data) -> Bool {
        data.starts(with: Data(resolverFileHeader.utf8))
    }
}
