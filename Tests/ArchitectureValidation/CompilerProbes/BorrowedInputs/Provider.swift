// Compiled by scripts/check-swift-borrowed-input-codegen.py, which compares
// ABIBridge's decisions for inputs that a result can borrow from with the
// compiled signatures below. Each `borrow<Case>` takes one input that its
// result borrows from, and `take<Case>` the same input without a lifetime
// dependency.
import CoreFoundation
import Darwin

public protocol P {}
public final class NC {
    public init() {}
    @_lifetime(borrow self) @inline(never) public func scoped() -> View { View(1) }
    @inline(never) public func unscoped() -> Int64 { 1 }
}
public struct View: ~Escapable {
    let n: Int64
    @_lifetime(immortal) public init(_ n: Int64) { self.n = n }
}
public struct Label {
    public var text: String = "l"
    public var n: Int64 = 1
    public init() {}
    @_lifetime(borrow self) @inline(never) public func scoped() -> View { View(n) }
    @inline(never) public func unscoped() -> Int64 { n }
}
public struct Plain {
    public var x: Int64 = 1
    public var y: Int64 = 2
    public init() {}
    @_lifetime(borrow self) @inline(never) public func scoped() -> View { View(x) }
    @inline(never) public func unscoped() -> Int64 { x }
}
// Too large for registers, so passed by address either way.
public struct Wide {
    public var text: String = "w"
    public var a: Int64 = 1
    public var b: Int64 = 2
    public var c: Int64 = 3
    public init() {}
}
public struct Pair<T> {
    public var a: T
    public var b: T
    public init(a: T, b: T) { self.a = a; self.b = b }
}
extension String {
    @_lifetime(borrow self) @inline(never) public func scoped() -> View { View(1) }
    @inline(never) public func unscoped() -> Int64 { 1 }
}

@_lifetime(borrow v) @inline(never) public func borrowString(_ v: String) -> View { View(1) }
@inline(never) public func takeString(_ v: String) -> Int64 { 1 }
@_lifetime(borrow v) @inline(never) public func borrowOptionalString(_ v: String?) -> View { View(1) }
@inline(never) public func takeOptionalString(_ v: String?) -> Int64 { 1 }
@_lifetime(borrow v) @inline(never) public func borrowLabel(_ v: Label) -> View { View(v.n) }
@inline(never) public func takeLabel(_ v: Label) -> Int64 { v.n }
@_lifetime(borrow v) @inline(never) public func borrowPlain(_ v: Plain) -> View { View(v.x) }
@inline(never) public func takePlain(_ v: Plain) -> Int64 { v.x }
@_lifetime(borrow v) @inline(never) public func borrowWide(_ v: Wide) -> View { View(v.a) }
@inline(never) public func takeWide(_ v: Wide) -> Int64 { v.a }
@_lifetime(borrow v) @inline(never) public func borrowInt64(_ v: Int64) -> View { View(v) }
@inline(never) public func takeInt64(_ v: Int64) -> Int64 { v }
@_lifetime(borrow v) @inline(never) public func borrowClass(_ v: NC) -> View { View(1) }
@inline(never) public func takeClass(_ v: NC) -> Int64 { 1 }
@_lifetime(borrow v) @inline(never) public func borrowOptionalClass(_ v: NC?) -> View { View(1) }
@inline(never) public func takeOptionalClass(_ v: NC?) -> Int64 { 1 }
@_lifetime(borrow v) @inline(never) public func borrowExistential(_ v: any P) -> View { View(1) }
@inline(never) public func takeExistential(_ v: any P) -> Int64 { 1 }
@_lifetime(borrow v) @inline(never) public func borrowClosure(_ v: @escaping () -> Void) -> View { View(1) }
@inline(never) public func takeClosure(_ v: @escaping () -> Void) -> Int64 { 1 }
@_lifetime(borrow v) @inline(never) public func borrowArray(_ v: [String]) -> View { View(1) }
@inline(never) public func takeArray(_ v: [String]) -> Int64 { 1 }
@_lifetime(borrow v) @inline(never) public func borrowMetatype(_ v: NC.Type) -> View { View(1) }
@inline(never) public func takeMetatype(_ v: NC.Type) -> Int64 { 1 }
@_lifetime(borrow v) @inline(never) public func borrowPointer(_ v: UnsafeRawPointer) -> View { View(1) }
@inline(never) public func takePointer(_ v: UnsafeRawPointer) -> Int64 { 1 }
// Imported C types: a C struct sets the bit, while neither a C enum nor an
// option set, which the importer makes a struct, does.
@_lifetime(borrow v) @inline(never) public func borrowCStruct(_ v: timespec) -> View { View(1) }
@inline(never) public func takeCStruct(_ v: timespec) -> Int64 { 1 }
@_lifetime(borrow v) @inline(never) public func borrowCEnum(_ v: CFComparisonResult) -> View { View(1) }
@inline(never) public func takeCEnum(_ v: CFComparisonResult) -> Int64 { 1 }
@_lifetime(borrow v) @inline(never) public func borrowCOptions(_ v: CFStringCompareFlags) -> View { View(1) }
@inline(never) public func takeCOptions(_ v: CFStringCompareFlags) -> Int64 { 1 }
// Keeps the imported types' metadata, which ABIBridge reads, in the IR.
public let importedTypes: [Any.Type] = [timespec.self, CFComparisonResult.self, CFStringCompareFlags.self]
@_lifetime(borrow v) @inline(never) public func borrowStringTuple(_ v: (String, Int64)) -> View { View(v.1) }
@inline(never) public func takeStringTuple(_ v: (String, Int64)) -> Int64 { v.1 }
@_lifetime(borrow v) @inline(never) public func borrowIntTuple(_ v: (Int64, Int64)) -> View { View(v.1) }
@inline(never) public func takeIntTuple(_ v: (Int64, Int64)) -> Int64 { v.1 }
// Too large for registers, but a tuple's elements pass separately.
@_lifetime(borrow v) @inline(never) public func borrowWideTuple(_ v: (String, Int64, Int64, Int64)) -> View { View(v.1) }
@inline(never) public func takeWideTuple(_ v: (String, Int64, Int64, Int64)) -> Int64 { v.1 }
@_lifetime(borrow v) @inline(never) public func borrowPairInt64(_ v: Pair<Int64>) -> View { View(v.a) }
@inline(never) public func takePairInt64(_ v: Pair<Int64>) -> Int64 { v.a }
@_lifetime(borrow v) @inline(never) public func borrowPairString(_ v: Pair<String>) -> View { View(1) }
@inline(never) public func takePairString(_ v: Pair<String>) -> Int64 { 1 }
// The declaration's abstraction decides: an element of a type parameter that
// is not class-bound sets the bit whatever its argument.
@_lifetime(borrow v) @inline(never) public func borrowGenericTuple<T>(_ v: (T, Int64)) -> View { View(v.1) }
@inline(never) public func takeGenericTuple<T>(_ v: (T, Int64)) -> Int64 { v.1 }
@_lifetime(borrow v) @inline(never) public func borrowClassBound<T: AnyObject>(_ v: T) -> View { View(1) }
@inline(never) public func takeClassBound<T: AnyObject>(_ v: T) -> Int64 { 1 }
// A pack passes its elements' addresses through one buffer either way. A
// tuple with a pack expansion passes as one address where a result borrows
// from it, and otherwise as its elements and a pack.
@_lifetime(borrow v) @inline(never) public func borrowPack<each T>(_ v: repeat (each T, Int64)) -> View { View(1) }
@inline(never) public func takePack<each T>(_ v: repeat (each T, Int64)) -> Int64 { 1 }
@_lifetime(borrow v) @inline(never) public func borrowTuplePack<each T>(_ v: (Int64, repeat each T)) -> View { View(1) }
@inline(never) public func takeTuplePack<each T>(_ v: (Int64, repeat each T)) -> Int64 { 1 }
// A copy dependency, and an inout one, leave the convention alone.
@_lifetime(copy v) @inline(never) public func borrowCopiedView(_ v: View) -> View { v }
@inline(never) public func takeCopiedView(_ v: View) -> Int64 { v.n }
@_lifetime(&v) @inline(never) public func borrowInoutString(_ v: inout String) -> View { View(1) }
@inline(never) public func takeInoutString(_ v: inout String) -> Int64 { 1 }

// The mangled names of functions whose results borrow from different
// inputs are equal apart from their names.
@_lifetime(borrow a) @inline(never) public func borrowFirst(_ a: String, _ b: String) -> View { View(1) }
@_lifetime(borrow b) @inline(never) public func borrowSecond(_ a: String, _ b: String) -> View { View(1) }
@_lifetime(borrow a, borrow b) @inline(never) public func borrowBoth(_ a: String, _ b: String) -> View { View(1) }
@inline(never) public func takeBoth(_ a: String, _ b: String) -> Int64 { 1 }

#if compiler(>=6.4)
// Function types record lifetime dependencies only in Swift 6.4 and later,
// and neither their mangling nor a field record shows them.
@inline(never) public func callBorrowingString(_ f: @_lifetime(borrow s) (_ s: String) -> View, _ s: String) -> Int64 { f(s).n }
@inline(never) public func callString(_ f: (String) -> View, _ s: String) -> Int64 { f(s).n }
@inline(never) public func callBorrowingPlain(_ f: @_lifetime(borrow p) (_ p: Plain) -> View, _ p: Plain) -> Int64 { f(p).n }
@inline(never) public func callPlain(_ f: (Plain) -> View, _ p: Plain) -> Int64 { f(p).n }
public struct HoldsBorrowing { public var f: @_lifetime(borrow s) (_ s: String) -> View }
public struct HoldsString { public var f: (String) -> View }
#endif

extension Label {
    @_lifetime(borrow self) @inline(never) public func scopedGeneric<T>(_ value: T) -> View {
        View(n)
    }
}
// Class-bound generic elements leave AFD clear in the declaration's abstraction.
@_lifetime(borrow v) @inline(never) public func borrowClassBoundTuple<T: AnyObject>(
    _ v: (T, Int64)
) -> View { View(v.1) }
@_lifetime(immortal) @inline(never) public func independentString(_ v: String) -> View { View(1) }

// Binding the result to an escapable type does not change this abstraction.
@_lifetime(borrow s)
@inline(never) public func projected<T: ~Escapable>(_ s: String, _ value: consuming T) -> T {
    unsafe _overrideLifetime(value, borrowing: s)
}

@_lifetime(borrow text)
@inline(never) public func projectedOptional<Value: ~Escapable>(
    _ text: String, _ value: consuming Value?
) -> Value? { unsafe _overrideLifetime(value, borrowing: text) }

@_lifetime(borrow text)
@inline(never) public func opaqueProjected<Value: ~Escapable>(
    _ text: String, _ value: consuming Value
) -> some ~Escapable { unsafe _overrideLifetime(value, borrowing: text) }

public final class DependencyBox<Tag> {}
@_lifetime(borrow pair)
@inline(never) public func projectedBox<Value: ~Escapable, Tag>(
    _ pair: (String, DependencyBox<Tag>),
    _ value: consuming Value
) -> Value { unsafe _overrideLifetime(value, borrowing: pair) }
