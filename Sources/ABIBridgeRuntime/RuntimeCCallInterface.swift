import ABIBridgeCore

package final class RuntimeCCallInterface: @unchecked Sendable {
    package let handle: OpaquePointer

    package init(
        result: RuntimeValueType,
        parameters: [RuntimeValueType],
        fixedParameterCount: Int? = nil
    ) throws {
        let handles: [OpaquePointer?] = parameters.map(\.handle)
        var failure: OpaquePointer?
        // Borrowed handles must outlive preparation, which retains their native storage.
        let handle = withExtendedLifetime((result, parameters)) {
            handles.withUnsafeBufferPointer {
                if let fixedParameterCount {
                    return ABICreateVariadicCCallInterface(
                        result.handle,
                        $0.baseAddress,
                        $0.count,
                        fixedParameterCount,
                        &failure
                    )
                }
                return ABICreateCCallInterface(result.handle, $0.baseAddress, $0.count, &failure)
            }
        }
        guard let handle else { throw consumeRuntimeCallFailure(failure) }
        self.handle = handle
    }

    deinit { ABIReleaseCallInterface(handle) }
}
