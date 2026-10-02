import SwiftValueFixtures

private struct ExtensionOpaqueValue: ExistentialValue { let number: Int64 }
private final class ExtensionOpaqueObject: ExistentialObjectValue {
    let number: Int64 = 49
}
extension OpaqueOwner {
    public func extensionOpaque(_ number: Int64) -> some ExistentialValue { ExtensionOpaqueValue(number: number) }
    public var extensionSummary: some ExistentialValue { ExtensionOpaqueValue(number: 48) }
    public func extensionClassOpaque() -> some ExistentialObjectValue { ExtensionOpaqueObject() }
}

extension BindingDeclaredBase: BindingDeclaredScore {
    public static func score() -> Int64 { 42 }
}
public struct BindingDeclaredKnown<Value: BindingDeclaredScore> {}
extension BindingDeclaredKnown where Value: BindingDeclaredBase {
    @inline(never) public static func entry<Failure: Error>(
        _ error: Failure, _ shouldThrow: Bool
    ) throws(Failure) -> Int64 {
        if shouldThrow { throw error }
        return Value.score()
    }
}
