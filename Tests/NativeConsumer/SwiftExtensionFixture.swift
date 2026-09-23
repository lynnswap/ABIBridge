import SwiftFunctionFixture

extension Renderer {
    @inline(never) public func extendedScore(_ value: Int) -> Int { text.count + value + 1 }
}
