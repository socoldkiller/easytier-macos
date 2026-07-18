import Testing
@testable import EasyTierShared

@Test func onlyAPersistedEditedSecretTransitionsToSaved() {
    let edited = NetworkSecretInput.edited("typed-secret")

    #expect(edited.applying(.none) == edited)
    #expect(
        edited.applying(NetworkSecretOperationOutcome(didPersistEditedSecret: true))
            == .saved("typed-secret")
    )
    #expect(NetworkSecretInput.saved("saved-secret").applying(.none) == .saved("saved-secret"))
}

@Test func sessionClearingDropsSavedMaterialButPreservesEditedMaterial() {
    #expect(NetworkSecretInput.saved("saved-secret").clearingSavedMaterial == nil)
    #expect(
        NetworkSecretInput.edited("typed-secret").clearingSavedMaterial
            == .edited("typed-secret")
    )
}
