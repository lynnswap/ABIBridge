// A library-evolution module whose types Client.swift stores and extends.
public protocol P {}
extension Int: P {}

// One String keeps an enum that stores it in registers on arm64_32.
@frozen public struct FrozenLabel { public var text: String; public init() { text = "f" } }
public struct OpenLabel { public var text: String; public var n: Int64; public init() { text = "o"; n = 2 } }
@frozen public struct FPair<T> { public var a: T; public var b: T; public init(a: T, b: T) { self.a = a; self.b = b } }
public struct OPair<T> { public var a: T; public var b: T; public init(a: T, b: T) { self.a = a; self.b = b } }
// Static metadata, yet passed by address: it stores a resilient type of its own module.
@frozen public struct FrozenHoldsOpen { public var o: OpenLabel; public var n: Int64; public init() { o = OpenLabel(); n = 1 } }
// Static metadata in a client, yet passed by address: they store an opaque
// type. A String field explains their addressable-for-dependencies bit.
@frozen public struct FrozenOpaque { public var text: String = "o"; public var x: some P = 7; public init() {} }
@frozen public struct Outer { public var inner: FrozenOpaque; public var m: Int64; public init() { inner = FrozenOpaque(); m = 1 } }

@inline(never) public func takeFrozenLabel(_ v: FrozenLabel) -> Int64 { 1 }
@inline(never) public func takeOpenLabel(_ v: OpenLabel) -> Int64 { v.n }
@inline(never) public func takeFrozenHoldsOpen(_ v: FrozenHoldsOpen) -> Int64 { v.n }
@inline(never) public func takeFrozenOpaque(_ v: FrozenOpaque) -> Int64 { 1 }
@inline(never) public func takeOuter(_ v: Outer) -> Int64 { v.m }

@inline(never) public func makeFrozenLabel() -> FrozenLabel { FrozenLabel() }
@inline(never) public func makeOpenLabel() -> OpenLabel { OpenLabel() }
@inline(never) public func makeFrozenHoldsOpen() -> FrozenHoldsOpen { FrozenHoldsOpen() }
@inline(never) public func makeFrozenOpaque() -> FrozenOpaque { FrozenOpaque() }
@inline(never) public func makeOuter() -> Outer { Outer() }
