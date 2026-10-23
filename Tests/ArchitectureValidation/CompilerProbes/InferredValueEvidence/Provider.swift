// Compiled with and without library evolution by
// scripts/check-inferred-swift-value-evidence-codegen.py, which reads the
// records below and compares its decisions with the signatures of the
// functions that take, make, or borrow the values.
import Foundation

public protocol P {}
public protocol CP: AnyObject {}
extension Int: P {}
extension String: P {}
public final class NC: CP { public init() {} }
public class OC: NSObject {}

// Structs whose addressable-for-dependencies bit a field explains.
public struct Label { public var text: String = "l"; public var n: Int64 = 1; public init() {} }
@frozen public struct FrozenLabel { public var text: String; public var n: Int64; public init() { text = "f"; n = 1 } }
public struct DataBox { public var data: Data = Data(); public var n: Int64 = 1; public init() {} }
public struct Mixed { public var text: String = "m"; var count: Int64 = 2; public init() {} }
public struct Unspelled { public var text: String; var count: Int64; public init() { text = "u"; count = 2 } }
public struct Plain { public var x: Double = 1; public var y: Double = 2; public init() {} }

// Stored properties of opaque types, which field records describe by their
// underlying types.
public struct OpaqueLabel { public var text: String = "o"; public var x: some P = 7; public init() {} }
public struct OpaqueString { public var x: some P = "s"; public var n: Int64 = 3; public init() {} }
public struct StructuralOpaque { public var text: String = "t"; public var x: (some P)? = 7; public init() {} }
public struct HiddenOpaque { public var text: String = "h"; var x: some P = 7; public init() {} }
public struct PrivateOpaque { public var text: String = "p"; private var x: some P = 7; public init() {} }
public struct OwnedOpaque { public var text: String = "c"; public var x: some CP = NC(); public init() {} }

// Attributes that only value witnesses show.
@sensitive public struct Secret { public var a: Int64 = 1; public var b: Int64 = 2; public init() {} }
@_addressableForDependencies public struct SelfAddressable { public var a: Int64 = 1; public var b: Int64 = 2; public init() {} }

// Property descriptor kinds. Library evolution gives some `let`s and
// computed properties trivial descriptors, never a stored `var`.
public struct Kinds {
    public var v: Int64 = 0
    public let l: Int64 = 0
    public var f: () -> Void = {}
    public let lf: () -> Void = {}
    public var m: Int.Type = Int.self
    public let lm: Int.Type = Int.self
    public unowned var u: NC
    public unowned let lu: NC
    public weak var w: NC?
    public var t: (Int, (Int) -> Int) = (0, { $0 })
    public let lt: (Int, (Int) -> Int) = (0, { $0 })
    public var of: (() -> Int)? = nil
    public private(set) var ps: Int64 = 0
    public var observed: Int64 = 0 { didSet {} }
    nonisolated(unsafe) public static var sv: Int64 = 0
    public var computed: Int64 { get { 0 } set {} }
    public var getOnly: Int64 { 0 }
    @usableFromInline internal var ufi: Int64 = 0
    package var pk: Int64 = 0
    public var op: some P = 7
    public init(_ c: NC) { u = c; lu = c }
}
public final class Klass { public var v: Int64 = 0; public let l: Int64 = 0; public var s: String = ""; public init() {} }

// Enums whose addressable-for-dependencies bit a payload explains.
public enum Tagged { case text(String), none }
@frozen public enum FrozenTagged { case text(String), none }
public enum Shape { case circle(Double), none }

// Generic declarations, compared through their instances.
@frozen public struct Pair<T> { public var a: T; public var b: T; public init(a: T, b: T) { self.a = a; self.b = b } }
public struct OpenPair<T> { public var a: T; public var b: T; public init(a: T, b: T) { self.a = a; self.b = b } }
public struct Holder<T: AnyObject> { public unowned var t: T; public var x: Int64; public init(t: T, x: Int64) { self.t = t; self.x = x } }
public struct GOpaque<T> { public var x: some P = 7; public var t: T; public init(t: T) { self.t = t } }
public struct GInternal<T> { public var t: T; var extra: Int64 = 0; public init(t: T) { self.t = t } }
public enum Either<L, R> { case left(L), right(R) }

@inline(never) public func takeLabel(_ v: Label) -> Int64 { v.n }
@inline(never) public func takeFrozenLabel(_ v: FrozenLabel) -> Int64 { v.n }
@inline(never) public func takeDataBox(_ v: DataBox) -> Int64 { v.n }
@inline(never) public func takeMixed(_ v: Mixed) -> Int64 { v.count }
@inline(never) public func takeUnspelled(_ v: Unspelled) -> Int64 { v.count }
@inline(never) public func takePlain(_ v: Plain) -> Double { v.x }
@inline(never) public func takeOpaqueLabel(_ v: OpaqueLabel) -> Int64 { 1 }
@inline(never) public func takeOpaqueString(_ v: OpaqueString) -> Int64 { v.n }
@inline(never) public func takeStructuralOpaque(_ v: StructuralOpaque) -> Int64 { 1 }
@inline(never) public func takeHiddenOpaque(_ v: HiddenOpaque) -> Int64 { 1 }
@inline(never) public func takePrivateOpaque(_ v: PrivateOpaque) -> Int64 { 1 }
@inline(never) public func takeOwnedOpaque(_ v: OwnedOpaque) -> Int64 { 1 }
@inline(never) public func takeSecret(_ v: Secret) -> Int64 { v.a }
@inline(never) public func takeSelfAddressable(_ v: SelfAddressable) -> Int64 { v.a }
@inline(never) public func takeTagged(_ v: Tagged) -> Int64 { 1 }
@inline(never) public func takeFrozenTagged(_ v: FrozenTagged) -> Int64 { 1 }
@inline(never) public func takeShape(_ v: Shape) -> Int64 { 1 }
@inline(never) public func takePairDouble(_ v: Pair<Double>) -> Double { v.a }
@inline(never) public func takeOpenPairDouble(_ v: OpenPair<Double>) -> Double { v.a }
@inline(never) public func takeGInternalDouble(_ v: GInternal<Double>) -> Double { v.t }
@inline(never) public func takeGOpaqueDouble(_ v: GOpaque<Double>) -> Double { v.t }
@inline(never) public func takeHolderNC(_ v: Holder<NC>) -> Int64 { v.x }
@inline(never) public func takeHolderOC(_ v: Holder<OC>) -> Int64 { v.x }
@inline(never) public func takeHolderAnyObject(_ v: Holder<AnyObject>) -> Int64 { v.x }
@inline(never) public func takeEitherIntString(_ v: Either<Int64, String>) -> Int64 { 1 }
@inline(never) public func takeEitherIntDouble(_ v: Either<Int64, Double>) -> Int64 { 1 }

@inline(never) public func makeLabel() -> Label { Label() }
@inline(never) public func makeFrozenLabel() -> FrozenLabel { FrozenLabel() }
@inline(never) public func makeDataBox() -> DataBox { DataBox() }
@inline(never) public func makeMixed() -> Mixed { Mixed() }
@inline(never) public func makeUnspelled() -> Unspelled { Unspelled() }
@inline(never) public func makePlain() -> Plain { Plain() }
@inline(never) public func makeOpaqueLabel() -> OpaqueLabel { OpaqueLabel() }
@inline(never) public func makeOpaqueString() -> OpaqueString { OpaqueString() }
@inline(never) public func makeStructuralOpaque() -> StructuralOpaque { StructuralOpaque() }
@inline(never) public func makeHiddenOpaque() -> HiddenOpaque { HiddenOpaque() }
@inline(never) public func makePrivateOpaque() -> PrivateOpaque { PrivateOpaque() }
@inline(never) public func makeOwnedOpaque() -> OwnedOpaque { OwnedOpaque() }
@inline(never) public func makeSecret() -> Secret { Secret() }
@inline(never) public func makeSelfAddressable() -> SelfAddressable { SelfAddressable() }
@inline(never) public func makeTagged() -> Tagged { .none }
@inline(never) public func makeFrozenTagged() -> FrozenTagged { .none }
@inline(never) public func makeShape() -> Shape { .none }
@inline(never) public func makePairDouble() -> Pair<Double> { Pair(a: 1, b: 2) }
@inline(never) public func makeOpenPairDouble() -> OpenPair<Double> { OpenPair(a: 1, b: 2) }
@inline(never) public func makeGInternalDouble() -> GInternal<Double> { GInternal(t: 1) }
@inline(never) public func makeGOpaqueDouble() -> GOpaque<Double> { GOpaque(t: 1) }
@inline(never) public func makeHolderNC(_ t: NC) -> Holder<NC> { Holder(t: t, x: 1) }
@inline(never) public func makeHolderOC(_ t: OC) -> Holder<OC> { Holder(t: t, x: 1) }
@inline(never) public func makeHolderAnyObject(_ t: AnyObject) -> Holder<AnyObject> { Holder(t: t, x: 1) }
@inline(never) public func makeEitherIntString() -> Either<Int64, String> { .left(1) }
@inline(never) public func makeEitherIntDouble() -> Either<Int64, Double> { .left(1) }

// Inputs that a result borrows from.
public struct View: ~Escapable {
    let n: Int64
    @_lifetime(immortal) public init(_ n: Int64) { self.n = n }
}
extension Label {
    @_lifetime(borrow self) @inline(never) public func scoped() -> View { View(n) }
}
extension Plain {
    @_lifetime(borrow self) @inline(never) public func scoped() -> View { View(Int64(x)) }
}
@_lifetime(borrow v) @inline(never) public func borrowLabel(_ v: Label) -> View { View(v.n) }
@_lifetime(borrow v) @inline(never) public func borrowPlain(_ v: Plain) -> View { View(Int64(v.x)) }
