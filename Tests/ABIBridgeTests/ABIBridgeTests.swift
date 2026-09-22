import ABIBridge
import Testing

@Test func nativeImageIdentityIsHashable() {
    let first = NativeImageIdentity(headerAddress: 0x1000, slide: 0x2000, loadGeneration: 1)
    let second = NativeImageIdentity(headerAddress: 0x1000, slide: 0x2000, loadGeneration: 1)

    #expect(first == second)
    #expect(Set([first, second]).count == 1)
}

@Test func declarationPreservesSourceLanguageAndKind() {
    let declaration = NativeDeclaration(
        name: "Example::Thing::value()",
        language: .cxx,
        kind: .function
    )

    #expect(declaration.name == "Example::Thing::value()")
    #expect(declaration.language == .cxx)
    #expect(declaration.kind == .function)
}

@Test func callPlanKeepsOwnershipAndReceiverContract() {
    let plan = NativeCallPlan(
        language: .cxx,
        resultOwnership: .owned,
        hasReceiver: true,
        hasIndirectResult: true
    )

    #expect(plan.resultOwnership == .owned)
    #expect(plan.hasReceiver)
    #expect(plan.hasIndirectResult)
}
