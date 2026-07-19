import Foundation

package enum NetworkInfoMagicDNSAugmenter {
    package static func augment(
        payloads: [(key: String, value: String)],
        using registry: AppliedMagicDNSRegistry
    ) throws -> [(key: String, value: String)] {
        try payloads.map { pair in
            let instanceID = try instanceID(from: pair.value)
            let configuration = registry.configuration(
                instanceName: pair.key,
                instanceID: instanceID
            )
            return (
                key: pair.key,
                value: try augment(payload: pair.value, with: configuration)
            )
        }
    }

    package static func augment(
        payload: String,
        with configuration: AppliedMagicDNSConfiguration?
    ) throws -> String {
        guard let configuration else { return payload }
        guard let data = payload.data(using: .utf8),
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw EasyTierCoreError.invalidResponse("EasyTier runtime info was not a JSON object.")
        }

        object["applied_magic_dns_enabled"] = configuration.enabled
        if let suffix = configuration.suffix {
            object["applied_magic_dns_suffix"] = suffix
        } else {
            object.removeValue(forKey: "applied_magic_dns_suffix")
        }

        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let output = String(data: encoded, encoding: .utf8) else {
            throw EasyTierCoreError.invalidResponse("Failed to encode augmented runtime info.")
        }
        return output
    }

    private static func instanceID(from payload: String) throws -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw EasyTierCoreError.invalidResponse("EasyTier runtime info was not a JSON object.")
        }
        return object["instance_id"] as? String
    }
}
