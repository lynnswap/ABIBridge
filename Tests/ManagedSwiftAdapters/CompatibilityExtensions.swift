import ManagedSwiftFixtures

// Members another module adds to a class, as frameworks extend the classes
// they consume.
extension CompatibilityBase {
    @inline(never) public var extensionDerived: CompatibilityDerived { CompatibilityDerived() }
    @inline(never) @concurrent public func extensionAsyncName() async -> String { "async" }
}
