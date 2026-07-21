import Foundation

struct PublishedServiceCertificateFailure: Identifiable, Equatable, Sendable {
    let id: String
    let hostname: String
    let message: String
}
