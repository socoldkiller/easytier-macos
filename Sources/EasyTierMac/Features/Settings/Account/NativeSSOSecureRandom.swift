import Foundation
import Security

enum NativeSSOSecureRandom {
    static func state() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BrowserSSOError.callbackUnavailable
        }
        return Data(bytes).base64EncodedString()
            .replacing("+", with: "-")
            .replacing("/", with: "_")
            .replacing("=", with: "")
    }
}
