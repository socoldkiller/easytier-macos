import Testing
@testable import EasyTierShared

@Test func valueNormalizationDistinguishesEmptyAndWhitespaceStrings() {
    #expect("".nilIfEmpty == nil)
    #expect("   ".nilIfEmpty == "   ")
    #expect(" \n\t ".trimmedNilIfEmpty == nil)
    #expect("  EasyTier  ".trimmedNilIfEmpty == "EasyTier")
}

@Test func valueNormalizationOmitsOnlyEmptyArrays() {
    #expect([Int]().nilIfEmpty == nil)
    #expect([1, 2].nilIfEmpty == [1, 2])
}
