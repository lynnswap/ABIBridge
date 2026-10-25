import ABIBridgeCore
import ABIBridgeCore.Backend
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

extension RuntimeSwiftAsyncCallInterface {
    private static let cache = RuntimeCallInterfaceCache<RuntimeSwiftAsyncCallInterface>()

    package static func cached(
        result: RuntimeValueType,
        parameters: [RuntimeValueType],
        errorPlan: RuntimeErrorConvention?,
        inheritsCallerIsolation: Bool
    ) throws -> RuntimeSwiftAsyncCallInterface {
        try cache.interface(
            for: RuntimeCallInterfaceKey(
                result: result,
                parameters: parameters,
                error: errorPlan?.type,
                typedError: errorPlan?.isTyped ?? false,
                inheritsCallerIsolation: inheritsCallerIsolation
            )
        ) {
            try RuntimeSwiftAsyncCallInterface(
                result: result,
                parameters: parameters,
                errorPlan: errorPlan,
                inheritsCallerIsolation: inheritsCallerIsolation
            )
        }
    }
}
