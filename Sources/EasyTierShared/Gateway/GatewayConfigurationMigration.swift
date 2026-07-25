import Foundation

package enum GatewayConfigurationMigration {
    package static func migrate(
        _ state: GatewayPersistedState,
        magicDNSSuffix: String
    ) throws -> GatewayPersistedState {
        guard state.schemaVersion != GatewaySchema.persistedVersion else { return state }
        guard state.schemaVersion == GatewaySchema.previousPersistedVersion else {
            throw GatewayConfigurationValidationError.invalid(
                "Unsupported Gateway schema version \(state.schemaVersion)."
            )
        }

        let suffix = try MagicDNSSettings.normalizedDNSSuffix(magicDNSSuffix)
        var migrated = state
        migrated.schemaVersion = GatewaySchema.persistedVersion
        migrated.dnsZoneBindings = state.dnsCredentials.map { credential in
            GatewayDNSZoneBinding(
                id: credential.id,
                dnsSuffix: suffix,
                credentialID: credential.id
            )
        }

        if let defaultID = state.defaultDNSZoneBindingID,
           migrated.dnsZoneBindings.contains(where: { $0.id == defaultID })
        {
            migrated.defaultDNSZoneBindingID = defaultID
        } else {
            migrated.defaultDNSZoneBindingID = migrated.dnsZoneBindings.first?.id
        }
        return migrated
    }
}
