import Foundation

enum BrowserSSOError: LocalizedError, Equatable {
    case invalidServerAddress
    case serverDoesNotSupportAccountLogin
    case unsupportedProtocolVersion
    case invalidBootstrap
    case insecureRedirect
    case invalidResponse
    case callbackUnavailable
    case callbackTimedOut
    case callbackRejected
    case browserCouldNotOpen
    case signInRejected

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            "Enter a secure server address such as https://iw.example.com."
        case .serverDoesNotSupportAccountLogin:
            "This server does not support EasyTier Account Login."
        case .unsupportedProtocolVersion:
            "This server uses an unsupported EasyTier Account Login protocol."
        case .invalidBootstrap, .invalidResponse:
            "The server returned an invalid EasyTier Account Login response."
        case .insecureRedirect:
            "The server attempted to redirect account login to another origin."
        case .callbackUnavailable:
            "EasyTier could not start the local sign-in callback."
        case .callbackTimedOut:
            "Browser sign-in timed out. Try again."
        case .callbackRejected:
            "EasyTier rejected an invalid browser callback."
        case .browserCouldNotOpen:
            "The default browser could not be opened."
        case .signInRejected:
            "The server rejected or expired this sign-in attempt."
        }
    }
}
