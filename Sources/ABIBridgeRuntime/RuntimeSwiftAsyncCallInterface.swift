import ABIBridgeCore
import Synchronization

package final class RuntimeSwiftAsyncCallInterface: @unchecked Sendable {
    package let handle: OpaquePointer
    private let callback = Mutex<RuntimeSwiftAsyncClosureCallbackOwner?>(nil)

    package func closureEntry(
        functions: ABISwiftAsyncClosureCallbackFunctions
    ) throws -> RuntimeSwiftAsyncClosureCallbackOwner {
        try callback.withLock { cached in
            if let cached { return cached }
            var failure: OpaquePointer?
            guard let handle = ABICreateSwiftAsyncClosureCallback(handle, functions, nil, &failure)
            else {
                throw consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftAsyncClosure")
            }
            let entry = try RuntimeSwiftAsyncClosureCallbackOwner(handle: handle)
            cached = entry
            return entry
        }
    }
    package let inheritsCallerIsolation: Bool
    package init(
        result: RuntimeValueType,
        parameters: [RuntimeValueType],
        errorPlan: RuntimeErrorConvention?,
        inheritsCallerIsolation: Bool
    ) throws {
        self.inheritsCallerIsolation = inheritsCallerIsolation
        let handles: [OpaquePointer?] = parameters.map(\.handle)
        var failure: OpaquePointer?
        let handle = withExtendedLifetime((result, parameters, errorPlan)) {
            handles.withUnsafeBufferPointer {
                ABICreateSwiftAsyncCallInterface(
                    result.handle,
                    $0.baseAddress,
                    $0.count,
                    errorPlan?.type.handle,
                    errorPlan?.isTyped ?? false,
                    inheritsCallerIsolation,
                    &failure
                )
            }
        }
        guard let handle else {
            throw consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftAsyncInvocation")
        }
        self.handle = handle
    }
    deinit { ABIReleaseSwiftAsyncCallInterface(handle) }
}
