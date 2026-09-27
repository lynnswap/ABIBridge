/// Compiler-owned concrete values used only by replacement validation.
public struct ReplacementPayload {
    public let a, b, c, d, e: Int64
    public init(_ value: Int64) { a = value; b = value + 1; c = value + 2; d = value + 3; e = value + 4 }
    public var checksum: Int64 { a + b + c + d + e }
}

@inline(never) public func scalar(_ value: Int64) -> Int64 { value + 1 }
@inline(never) public func replacementScalar(_ value: Int64) -> Int64 { value + 100 }
@inline(never) public func text(_ value: String) -> String { "original:" + value }
@inline(never) public func replacementText(_ value: String) -> String { "replacement:" + value }
@inline(never) public func payload(_ value: Int64) -> ReplacementPayload { .init(value) }
@inline(never) public func replacementPayload(_ value: Int64) -> ReplacementPayload { .init(value + 100) }
@inline(never) public func sameImageScalar(_ value: Int64) -> Int64 { scalar(value) }
@inline(never) public dynamic func dynamicScalar(_ value: Int64) -> Int64 { value + 1 }

public struct ReplacementValue {
    public let seed: Int64
    public init(_ seed: Int64) { self.seed = seed }
    @inline(never) public func scalar(_ value: Int64) -> Int64 { seed + value }
    @inline(never) public func replacementScalar(_ value: Int64) -> Int64 { seed + value + 100 }
}

// A nongeneric, nonresilient root class deliberately keeps metadata interpretation
// bounded. Its methods are paired on this same receiver type and native ABI.
open class ReplacementRenderer {
    public init() {}
    @inline(never) open func scalar(_ value: Int64) -> Int64 { value + 2 }
    @inline(never) public func replacementScalar(_ value: Int64) -> Int64 { value + 200 }
    @inline(never) open func text(_ value: String) -> String { "method:" + value }
    @inline(never) public func replacementText(_ value: String) -> String { "replacement-method:" + value }
    @inline(never) open func payload(_ value: Int64) -> ReplacementPayload { .init(value + 2) }
    @inline(never) public func replacementPayload(_ value: Int64) -> ReplacementPayload { .init(value + 200) }
    @inline(never) public final func finalScalar(_ value: Int64) -> Int64 { value + 3 }
}

@inline(never) public func makeRenderer() -> ReplacementRenderer { ReplacementRenderer() }
@inline(never) public func knownClassScalar(_ value: Int64) -> Int64 { ReplacementRenderer().scalar(value) }
