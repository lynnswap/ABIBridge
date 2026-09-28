import ManagedSwiftFixtures

@inline(never) public func probeVector(
    _ body: (ManagedVector) -> ManagedVector, _ value: ManagedVector
) -> ManagedVector { body(value) }

@inline(never) public func probeChoice(
    _ body: (ManagedChoice) -> ManagedChoice, _ value: ManagedChoice
) -> ManagedChoice { body(value) }

@inline(never) public func probeLarge(
    _ body: (LargeManagedValue) -> LargeManagedValue, _ value: LargeManagedValue
) -> LargeManagedValue { body(value) }
