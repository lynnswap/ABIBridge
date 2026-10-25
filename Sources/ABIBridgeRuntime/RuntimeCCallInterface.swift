import ABIBridgeCore
import ABIBridgeCore.Backend

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

extension RuntimeCCallInterface {
    private static let cache = RuntimeCallInterfaceCache<RuntimeCCallInterface>()

    package static func cached(
        result: RuntimeValueType,
        parameters: [RuntimeValueType],
        fixedParameterCount: Int? = nil
    ) throws -> RuntimeCCallInterface {
        try cache.interface(
            for: RuntimeCallInterfaceKey(
                result: result,
                parameters: parameters,
                fixedParameterCount: fixedParameterCount
            )
        ) {
            try RuntimeCCallInterface(
                result: result,
                parameters: parameters,
                fixedParameterCount: fixedParameterCount
            )
        }
    }
}
