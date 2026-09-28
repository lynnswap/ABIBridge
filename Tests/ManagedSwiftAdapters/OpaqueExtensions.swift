import ManagedSwiftFixtures

private struct ExtensionOpaqueValue: ExistentialValue { let number: Int64 }
private final class ExtensionOpaqueObject: ExistentialObjectValue {
    let number: Int64 = 49
}
extension OpaqueOwner {
    public func extensionOpaque(_ number: Int64) -> some ExistentialValue { ExtensionOpaqueValue(number: number) }
    public var extensionSummary: some ExistentialValue { ExtensionOpaqueValue(number: 48) }
    public func extensionClassOpaque() -> some ExistentialObjectValue { ExtensionOpaqueObject() }
}
