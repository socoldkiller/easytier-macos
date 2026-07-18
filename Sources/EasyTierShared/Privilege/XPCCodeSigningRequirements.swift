import Foundation
import Security

package enum EasyTierXPCCodeSigningRequirements {
    package static func requirement(forPeerIdentifier identifier: String) throws -> String {
        let teamIdentifier = try currentTeamIdentifier()
#if DEBUG
        return try requirement(
            peerIdentifier: identifier,
            teamIdentifier: teamIdentifier,
            allowIdentifierOnly: true
        )
#else
        return try requirement(
            peerIdentifier: identifier,
            teamIdentifier: teamIdentifier,
            allowIdentifierOnly: false
        )
#endif
    }

    package static func requirement(
        peerIdentifier: String,
        teamIdentifier: String?,
        allowIdentifierOnly: Bool
    ) throws -> String {
        guard isSafeRequirementValue(peerIdentifier) else {
            throw EasyTierXPCCodeSigningRequirementError.invalidIdentifier(peerIdentifier)
        }
        guard let teamIdentifier = teamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !teamIdentifier.isEmpty
        else {
            guard allowIdentifierOnly else {
                throw EasyTierXPCCodeSigningRequirementError.missingTeamIdentifier
            }
            return "identifier \"\(peerIdentifier)\""
        }
        guard isSafeRequirementValue(teamIdentifier) else {
            throw EasyTierXPCCodeSigningRequirementError.invalidTeamIdentifier(teamIdentifier)
        }
        return "identifier \"\(peerIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    private static func currentTeamIdentifier() throws -> String? {
        var code: SecCode?
        let copySelfStatus = SecCodeCopySelf([], &code)
        guard copySelfStatus == errSecSuccess, let code else {
            throw EasyTierXPCCodeSigningRequirementError.signingInformationUnavailable(copySelfStatus)
        }

        var staticCode: SecStaticCode?
        let copyStaticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard copyStaticStatus == errSecSuccess, let staticCode else {
            throw EasyTierXPCCodeSigningRequirementError.signingInformationUnavailable(copyStaticStatus)
        }

        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard informationStatus == errSecSuccess,
              let values = information as? [CFString: Any]
        else {
            throw EasyTierXPCCodeSigningRequirementError.signingInformationUnavailable(informationStatus)
        }
        return values[kSecCodeInfoTeamIdentifier] as? String
    }

    private static func isSafeRequirementValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            switch byte {
            case 45, 46, 48...57, 65...90, 97...122:
                true
            default:
                false
            }
        }
    }
}

package enum EasyTierXPCCodeSigningRequirementError: LocalizedError, Equatable {
    case signingInformationUnavailable(OSStatus)
    case missingTeamIdentifier
    case invalidIdentifier(String)
    case invalidTeamIdentifier(String)

    package var errorDescription: String? {
        switch self {
        case let .signingInformationUnavailable(status):
            "EasyTier could not read its code-signing identity (OSStatus \(status))."
        case .missingTeamIdentifier:
            "EasyTier requires a signed app and helper with a matching Apple Team ID."
        case let .invalidIdentifier(identifier):
            "EasyTier has an invalid XPC peer identifier: \(identifier)"
        case let .invalidTeamIdentifier(identifier):
            "EasyTier has an invalid code-signing Team ID: \(identifier)"
        }
    }
}
