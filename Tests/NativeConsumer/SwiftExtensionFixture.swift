import SwiftFunctionFixture
import Foundation

@inline(never) public func importedHookInteger(_ value: Int64) -> Int64 { hookEcho(value) }
@inline(never) public func importedHookString(_ value: String) -> String { hookEcho(value) }
@inline(never) public func importedHookArray(_ value: [String]) -> [String] { hookEcho(value) }
@inline(never) public func importedHookThrowing(_ value: Int64) throws(NSError) -> Int64 { try hookThrowing(value) }

extension Renderer {
    @inline(never) public func extendedScore(_ value: Int) -> Int { text.count + value + 1 }
}

extension GenericExtensionRenderer where Value == Int {
    @inline(never) public func constrainedScore(_ extra: Int) -> Int { value + extra }
    public var constrainedValue: Int { @inline(never) get { value } }
}
