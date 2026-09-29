import SwiftFunctionFixture

extension Renderer {
    @inline(never) public func extendedScore(_ value: Int) -> Int { text.count + value + 1 }
}

extension GenericExtensionRenderer where Value == Int {
    @inline(never) public func constrainedScore(_ extra: Int) -> Int { value + extra }
    public var constrainedValue: Int { @inline(never) get { value } }
}
