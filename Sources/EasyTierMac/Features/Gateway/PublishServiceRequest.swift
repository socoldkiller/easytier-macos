import Foundation

struct PublishServiceRequest: Identifiable {
    let id = UUID()
    var preferredTargetPeerID: String?
}
