// A module without library evolution that stores and extends the types of
// the library-evolution module in Base.swift.
import EvidenceBase

public struct HoldsFrozen { public var f: FrozenLabel = .init(); public init() {} }
public struct HoldsFPair { public var p: FPair<Double> = .init(a: 1, b: 2); public init() {} }
public enum HoldsFrozenCase { case f(FrozenLabel), none }
public struct HoldsFrozenOpaque { public var f: FrozenOpaque = .init(); public init() {} }
public struct HoldsOuter { public var o: Outer = .init(); public init() {} }
public struct HoldsOpen { public var o: OpenLabel = .init(); public init() {} }
public struct HoldsOPair { public var p: OPair<Double> = .init(a: 1, b: 2); public init() {} }
public enum HoldsOpenCase { case o(OpenLabel), none }
// Its trivial property descriptor shares the base module's context.
extension OpenLabel { public struct Builder { public var scale: Int = 1; public init() {} } }

@inline(never) public func takeHoldsFrozen(_ v: HoldsFrozen) -> Int64 { 1 }
@inline(never) public func takeHoldsFPair(_ v: HoldsFPair) -> Double { v.p.a }
@inline(never) public func takeHoldsFrozenCase(_ v: HoldsFrozenCase) -> Int64 { 1 }
@inline(never) public func takeHoldsFrozenOpaque(_ v: HoldsFrozenOpaque) -> Int64 { 1 }
@inline(never) public func takeHoldsOuter(_ v: HoldsOuter) -> Int64 { v.o.m }
@inline(never) public func takeHoldsOpen(_ v: HoldsOpen) -> Int64 { v.o.n }
@inline(never) public func takeHoldsOPair(_ v: HoldsOPair) -> Double { v.p.a }
@inline(never) public func takeHoldsOpenCase(_ v: HoldsOpenCase) -> Int64 { 1 }
@inline(never) public func takeBuilder(_ v: OpenLabel.Builder) -> Int { v.scale }

@inline(never) public func makeHoldsFrozen() -> HoldsFrozen { HoldsFrozen() }
@inline(never) public func makeHoldsFPair() -> HoldsFPair { HoldsFPair() }
@inline(never) public func makeHoldsFrozenCase() -> HoldsFrozenCase { .none }
@inline(never) public func makeHoldsFrozenOpaque() -> HoldsFrozenOpaque { HoldsFrozenOpaque() }
@inline(never) public func makeHoldsOuter() -> HoldsOuter { HoldsOuter() }
@inline(never) public func makeHoldsOpen() -> HoldsOpen { HoldsOpen() }
@inline(never) public func makeHoldsOPair() -> HoldsOPair { HoldsOPair() }
@inline(never) public func makeHoldsOpenCase() -> HoldsOpenCase { .none }
@inline(never) public func makeBuilder() -> OpenLabel.Builder { OpenLabel.Builder() }
