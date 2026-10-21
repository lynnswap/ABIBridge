// Declarations whose native class types differ from the types callers request.

open class CompatibilityBase {
    public init() {}
    open func name() -> String { "base" }
    @inline(never) open func makeDerived() -> CompatibilityDerived { CompatibilityDerived() }
    open var derived: CompatibilityDerived { CompatibilityDerived() }
    @inline(never) public final func opaqueCount() -> some Equatable { Int64(42) }
}

public final class CompatibilityDerived: CompatibilityBase {
    public override init() { super.init() }
    public override func name() -> String { "derived" }
}

@inline(never) public func compatibilityMakeDerived() -> CompatibilityDerived { CompatibilityDerived() }

@inline(never) public func compatibilityOpaqueCount() -> some Equatable { Int64(41) }

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

@inline(never) public func compatibilityReplace(_ value: inout CompatibilityBase) {
    value = CompatibilityBase()
}

@inline(never) public func compatibilityPair() -> (CompatibilityBase, Int64) { (CompatibilityBase(), 1) }

@inline(never) public func compatibilityApply(
    _ body: (CompatibilityBase) -> CompatibilityDerived
) -> String {
    body(CompatibilityBase()).name()
}

extension CompatibilityBase {
    @inline(never) public func describe(_ value: CompatibilityBase) -> String { value.name() }
}

public protocol CompatibilityNamed { func compatibilityLabel() -> String }

extension CompatibilityNamed {
    @inline(never) public func compatibilityGreeting() -> String { "hello " + compatibilityLabel() }
}

extension CompatibilityBase: CompatibilityNamed {
    @inline(never) public func compatibilityLabel() -> String { name() }
}

// A value type that hosts represent with their own adapter.
@frozen public struct CompatibilityCount {
    public var value: Int64
    @inline(never) public init(_ value: Int64) { self.value = value }
    public var doubled: CompatibilityCount { CompatibilityCount(value * 2) }
}

public protocol CompatibilityLabeled: AnyObject { var compatibilityTag: String { get set } }

extension CompatibilityLabeled {
    public var compatibilityTag: String {
        get { "default" }
        set {}
    }
}

public final class CompatibilityTagged: CompatibilityLabeled {
    public var compatibilityTag = "initial"
    public init() {}
}
