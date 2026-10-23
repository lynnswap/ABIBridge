// Declarations that must fail to type-check: a result cannot borrow from a
// consuming input, whether a parameter, an initializer's parameter, which is
// consuming by default, or a consuming self.
public struct View: ~Escapable {
    let n: Int64
    @_lifetime(borrow s) public init(_ s: String) { n = 1 }
}
@_lifetime(borrow s) public func borrowConsuming(_ s: consuming String) -> View { View(s) }
public struct Label {
    public var text: String
    @_lifetime(borrow self) public consuming func scoped() -> View { View(text) }
}
