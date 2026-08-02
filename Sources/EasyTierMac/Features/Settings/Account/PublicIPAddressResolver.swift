import Foundation

enum PublicIPAddressResolver {
    static let loadingPlaceholder = "Loading…"
    static let unavailablePlaceholder = "Unavailable"

    static func resolve() async -> String? {
        guard let url = URL(string: "https://api64.ipify.org") else { return nil }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.timeoutInterval = 5
        request.setValue("text/plain", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  data.count <= 64,
                  let value = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  isPlausibleIPAddress(value)
            else { return nil }
            return value
        } catch {
            return nil
        }
    }

    private static func isPlausibleIPAddress(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 45 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF:.").contains($0)
        }
    }
}
