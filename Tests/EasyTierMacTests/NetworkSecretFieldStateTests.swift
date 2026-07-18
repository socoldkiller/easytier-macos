import EasyTierShared
import Testing
@testable import EasyTierMac

@Test func keychainLookupSeparatesLockedAndLoadedSecretStates() {
    var state = NetworkSecretFieldState()

    state.resetForLookup(hasValue: false)
    state.completeLookup(saved: true, hasValue: false)

    #expect(state.availability == .present)
    #expect(state.material == .none)
    #expect(!state.isRevealed)

    state.beginUnlock()
    state.completeUnlock(foundSecret: true)

    #expect(state.material == .loaded)
    #expect(!state.isRevealed)
}

@Test func keychainLookupDoesNotOverwriteASecretTypedWhileChecking() {
    var state = NetworkSecretFieldState()

    state.resetForLookup(hasValue: false)
    state.userEdited(hasValue: true)
    state.completeLookup(saved: true, hasValue: true)

    #expect(state.availability == .present)
    #expect(state.material == .draft)
}

@Test func loadedSecretRevealAndEditingTransitionsAreExplicit() {
    var state = NetworkSecretFieldState()
    state.completeUnlock(foundSecret: true)

    state.toggleReveal()
    #expect(state.isRevealed)

    state.userEdited(hasValue: true)
    #expect(state.material == .draft)
    #expect(!state.isRevealed)

    state.beginSave()
    state.completeSave()
    #expect(state.availability == .present)
    #expect(state.material == .loaded)
    #expect(!state.isRevealed)
}

@Test func canceledOperationPreservesTheCurrentMaterial() {
    var state = NetworkSecretFieldState()
    state.completeLookup(saved: true, hasValue: true)
    state.userEdited(hasValue: true)

    state.beginSave()
    state.cancelOperation()

    #expect(state.availability == .present)
    #expect(state.material == .draft)
    #expect(state.errorMessage == nil)
}

@Test func discardAndRemoveClearPlaintextPresentation() {
    var state = NetworkSecretFieldState()
    state.completeLookup(saved: true, hasValue: true)
    state.userEdited(hasValue: true)

    state.discardDraft()
    #expect(state.availability == .present)
    #expect(state.material == .none)

    state.beginRemove()
    state.completeRemove()
    #expect(state.availability == .absent)
    #expect(state.material == .none)
    #expect(!state.isRevealed)
}

@Test func sessionResetDropsLoadedPresentationBeforeCheckingAgain() {
    var state = NetworkSecretFieldState()
    state.completeUnlock(foundSecret: true)
    state.toggleReveal()

    state.resetForLookup(hasValue: false)

    #expect(state.availability == .checking)
    #expect(state.material == .none)
    #expect(state.operation == .checking)
    #expect(!state.isRevealed)
}

@Test func temporaryInactivityConcealsWithoutClearingLoadedMaterial() {
    var state = NetworkSecretFieldState()
    state.completeUnlock(foundSecret: true)
    state.toggleReveal()

    state.hideSecret()

    #expect(state.material == .loaded)
    #expect(!state.isRevealed)
}

@Test func securityBoundaryClearsLoadedMaterialButPreservesDrafts() {
    var loaded = NetworkSecretFieldState()
    loaded.completeUnlock(foundSecret: true)
    loaded.clearLoadedMaterial()
    #expect(loaded.material == .none)

    var draft = NetworkSecretFieldState()
    draft.userEdited(hasValue: true)
    draft.clearLoadedMaterial()
    #expect(draft.material == .draft)
}

@Test func sensitivePresentationLifecyclePreservesInactiveAndClearsBackground() {
    #expect(!SensitivePresentationLifecyclePolicy.shouldClearMaterial(for: .active))
    #expect(!SensitivePresentationLifecyclePolicy.shouldClearMaterial(for: .inactive))
    #expect(SensitivePresentationLifecyclePolicy.shouldClearMaterial(for: .background))
    #expect(SensitivePresentationLifecyclePolicy.shouldConcealMaterial(for: .inactive))
}

@Test func externalSecretPersistenceUpdatesTheFieldMaterialProvenance() {
    var state = NetworkSecretFieldState()
    state.userEdited(hasValue: true)

    state.synchronizeMaterial(with: .saved("typed-secret"))
    #expect(state.material == .loaded)

    state.synchronizeMaterial(with: nil)
    #expect(state.material == .none)
}
