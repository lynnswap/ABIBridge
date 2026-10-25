import ABIBridgeCore
import ABIBridgeCore.Backend
import Synchronization

package final class RuntimeSwiftCallInterface: @unchecked Sendable {
    package let handle: OpaquePointer
    private let callback = Mutex<RuntimeSwiftClosureCallbackOwner?>(nil)

    package func closureEntry(
        functions: ABISwiftThrowingClosureCallbackFunctions
    ) throws -> RuntimeSwiftClosureCallbackOwner {
        try callback.withLock { cached in
            if let cached { return cached }
            var failure: OpaquePointer?
            guard
                let handle = ABICreateSwiftThrowingClosureCallback(handle, functions, nil, &failure)
            else {
                throw consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftClosure")
            }
            let entry = try RuntimeSwiftClosureCallbackOwner(handle: handle)
            cached = entry
            return entry
        }
    }
    package init(
        result: RuntimeValueType,
        parameters: [RuntimeValueType],
        errorPlan: RuntimeErrorConvention? = nil
    ) throws {
        let handles: [OpaquePointer?] = parameters.map(\.handle)
        var failure: OpaquePointer?
        let handle = withExtendedLifetime((result, parameters, errorPlan)) {
            handles.withUnsafeBufferPointer { handles in
                if let errorPlan {
                    return ABICreateSwiftThrowingCallInterface(
                        result.handle,
                        handles.baseAddress,
                        handles.count,
                        errorPlan.type.handle,
                        errorPlan.isTyped,
                        &failure
                    )
                }
                return ABICreateSwiftCallInterface(
                    result.handle,
                    handles.baseAddress,
                    handles.count,
                    &failure
                )
            }
        }
        guard let handle else {
            throw consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftInvocation")
        }
        self.handle = handle
    }
    deinit { ABIReleaseSwiftCallInterface(handle) }
}

extension RuntimeSwiftCallInterface {
    static let cache = RuntimeCallInterfaceCache<RuntimeSwiftCallInterface>()

    package static func cached(
        result: RuntimeValueType,
        parameters: [RuntimeValueType],
        errorPlan: RuntimeErrorConvention? = nil
    ) throws -> RuntimeSwiftCallInterface {
        try cache.interface(
            for: RuntimeCallInterfaceKey(
                result: result,
                parameters: parameters,
                error: errorPlan?.type,
                typedError: errorPlan?.isTyped ?? false
            )
        ) {
            try RuntimeSwiftCallInterface(
                result: result,
                parameters: parameters,
                errorPlan: errorPlan
            )
        }
    }
}
