import EasyTierShared
import Observation

@MainActor
@Observable
final class WindowPresentationModel {
    var activity: RuntimePresentationActivity = .interactive
}
