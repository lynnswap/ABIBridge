import ABIBridgeCore

package final class RuntimeSwiftClosureCallbackOwner: @unchecked Sendable {
    package let handle: OpaquePointer
    package var function: ABIUnmanagedFunction { ABISwiftClosureCallbackFunction(handle)! }

    package let implementation: RuntimeImplementation
    package init(handle: OpaquePointer) throws {
        self.handle = handle
        do {
            implementation = try RuntimeImplementation(
                function: ABISwiftClosureCallbackFunction(handle)!,
                retaining: nil
            )
        } catch { ABIReleaseSwiftClosureCallback(handle); throw error }
    }

    deinit { ABIReleaseSwiftClosureCallback(handle) }
}
