import SwiftUI

enum SensitivePresentationLifecyclePolicy {
    static func shouldClearMaterial(for phase: ScenePhase) -> Bool {
        switch phase {
        case .active, .inactive:
            false
        case .background:
            true
        @unknown default:
            true
        }
    }

    static func shouldConcealMaterial(for phase: ScenePhase) -> Bool {
        switch phase {
        case .active:
            false
        case .inactive, .background:
            true
        @unknown default:
            true
        }
    }
}
