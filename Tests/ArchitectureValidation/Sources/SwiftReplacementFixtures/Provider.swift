/// Compiler-owned concrete values used only by replacement validation.
public struct ReplacementPayload {
    public let a, b, c, d, e: Int64
    public init(_ value: Int64) { a = value; b = value + 1; c = value + 2; d = value + 3; e = value + 4 }
    public var checksum: Int64 { a + b + c + d + e }
}

@inline(never) public func scalar(_ value: Int64) -> Int64 { value + 1 }
@inline(never) public func opaqueScalar(_ value: Int64) -> some Any { value + 1 }
@inline(never) public func opaqueText(_ value: String) -> some Any { value + " original" }
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

open class InheritedRenderer: ReplacementRenderer {}
open class OverridingRenderer: ReplacementRenderer {
    @inline(never) public override func scalar(_ value: Int64) -> Int64 { value + 4 }
}
@inline(never) public func makeInheritedRenderer() -> ReplacementRenderer { InheritedRenderer() }
@inline(never) public func makeOverridingRenderer() -> ReplacementRenderer { OverridingRenderer() }

// Optimizers may coalesce these bodies. Their declarations still own distinct
// metadata entries, and the final method has no virtual entry at all.
open class CoalescedParent {
    public init() {}
    @inline(never) open func value() -> Int64 { 42 }
    @inline(never) public func replacement() -> Int64 { 100 }
}
open class CoalescedChild: CoalescedParent {
    @inline(never) public func extra() -> Int64 { 42 }
    @inline(never) public final func finalValue() -> Int64 { 42 }
}
@inline(never) public func makeCoalescedChild() -> CoalescedChild { CoalescedChild() }

public struct CallbackMixedResult {
    public var a: Int64
    public var b: Double
    public var c: Int64
    public var d: Double
    public var checksum: Double { Double(a + c) + b + d }
}
public struct CallbackQuartet {
    public var a, b, c, d: Int64
    public var checksum: Int64 { a + b + c + d }
}
open class CallbackRenderer {
    public let seed: Int64
    public init(_ seed: Int64) { self.seed = seed }
    @inline(never) open func mixed(
        _ a0: Int64, _ a1: Int64, _ a2: Int64, _ a3: Int64, _ a4: Int64,
        _ a5: Int64, _ a6: Int64, _ a7: Int64, _ a8: Int64,
        _ d0: Double, _ d1: Double, _ d2: Double, _ d3: Double, _ d4: Double,
        _ d5: Double, _ d6: Double, _ d7: Double, _ d8: Double
    ) -> CallbackMixedResult {
        let integers = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8
        let floating = d0 + d1 + d2 + d3 + d4 + d5 + d6 + d7 + d8
        return .init(a: seed + integers, b: floating, c: seed + integers * 2, d: floating * 2)
    }
    @inline(never) open consuming func consumeSelf(_ value: Int64) -> Int64 { seed + value }
    @inline(never) open func quartet(_ value: Int64) -> CallbackQuartet {
        .init(a: seed + value, b: seed + value + 1, c: seed + value + 2, d: seed + value + 3)
    }
}
@inline(never) public func makeCallbackRenderer(_ seed: Int64) -> CallbackRenderer { CallbackRenderer(seed) }

open class HookRenderer {
    public var count: Int64
    public var text: String = "initial"
    public init(_ count: Int64) { self.count = count }
    @inline(never) open func render(_ value: Int64) -> Int64 { count + value }
    @inline(never) public final func directRender(_ value: Int64) -> Int64 { count + value }
    @inline(never) open consuming func consume(_ value: Int64) -> Int64 { count + value }
}
@inline(never) public func makeHookRenderer(_ count: Int64) -> HookRenderer { HookRenderer(count) }

public struct HookCounter {
    public var count: Int64
    public init(_ count: Int64) { self.count = count }
    @inline(never) public func adding(_ value: Int64) -> Int64 { count + value }
    @inline(never) public mutating func increment(_ value: Int64) -> Int64 { count += value; return count }
    @inline(never) public func stack(_ a: Int64, _ b: Int64, _ c: Int64, _ d: Int64, _ e: Int64, _ f: Int64, _ g: Int64, _ h: Int64, _ i: Int64, _ j: Int64, _ k: Int64, _ l: Int64) -> Int64 { count+a+b+c+d+e+f+g+h+i+j+k+l }
}
public struct HookTextValue {
    public var text: String
    public init(_ text: String) { self.text = text }
    @inline(never) public consuming func consume() -> String { "value:" + text }
    @inline(never) public mutating func append(_ suffix: String) -> String { text += suffix; return text }
}
public struct HookWideValue {
    public var a,b,c,d,e: Int64
    public init(_ seed: Int64) { a=seed; b=seed+1; c=seed+2; d=seed+3; e=seed+4 }
    @inline(never) public func sum(_ value: Int64) -> Int64 { a+b+c+d+e+value }
    @inline(never) public consuming func consume(_ value: Int64) -> Int64 { a+b+c+d+e+value }
}
import Foundation

@inline(never) public func composedHookEcho<Value>(_ value: Value) -> Value { value }
@inline(never) public func composedHookFactory<Value>(_ value: Value) -> () -> Value { { value } }
@inline(never) public func composedHookError(_ value: Int64) throws(NSError) -> Int64 {
    if value < 0 { throw NSError(domain: "native-hook", code: Int(value)) }
    return value + 1
}
