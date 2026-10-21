// Declarations whose native class types differ from the types callers request.

open class CompatibilityBase {
    public init() {}
    open func name() -> String { "base" }
    @inline(never) open func makeDerived() -> CompatibilityDerived { CompatibilityDerived() }
}

public final class CompatibilityDerived: CompatibilityBase {
    public override init() { super.init() }
    public override func name() -> String { "derived" }
}

@inline(never) public func compatibilityMakeDerived() -> CompatibilityDerived { CompatibilityDerived() }

@inline(never) public func compatibilityMakeOptional(_ present: Bool) -> CompatibilityDerived? {
    present ? CompatibilityDerived() : nil
}

@inline(never) public func compatibilityName(_ value: CompatibilityBase) -> String { value.name() }

@inline(never) public func compatibilityOptionalName(_ value: CompatibilityBase?) -> String {
    value?.name() ?? "nil"
}

@inline(never) public func compatibilityDerivedName(_ value: CompatibilityDerived) -> String {
    value.name()
}
