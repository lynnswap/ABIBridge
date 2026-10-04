import ABIBridgeCore

package final class RuntimeSwiftAsyncClosureCallbackOwner: @unchecked Sendable {
    package let handle: OpaquePointer
    package let entry: RuntimeSwiftAsyncEntry
    package init(handle: OpaquePointer) throws {
        self.handle = handle
        do {
            entry = try RuntimeSwiftAsyncEntry(
                descriptor: ABISwiftAsyncClosureCallbackDescriptor(handle)!
            )
        } catch { ABIReleaseSwiftAsyncClosureCallback(handle); throw error }
    }

    deinit { ABIReleaseSwiftAsyncClosureCallback(handle) }
}
