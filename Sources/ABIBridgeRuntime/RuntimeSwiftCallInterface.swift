import ABIBridgeCore
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
    private struct Entry: Sendable {
        let result: RuntimeValueType
        let parameters: [RuntimeValueType]
        let error: RuntimeValueType?
        let typedError: Bool
        let interface: RuntimeSwiftCallInterface

        func matches(
            result: RuntimeValueType,
            parameters: [RuntimeValueType],
            errorPlan: RuntimeErrorConvention?
        ) -> Bool {
            guard Self.equal(self.result, result), self.parameters.count == parameters.count,
                typedError == (errorPlan?.isTyped ?? false)
            else { return false }
            switch (error, errorPlan?.type) {
            case (.none, .none): break
            case (.some(let first), .some(let second)):
                guard Self.equal(first, second) else { return false }
            default: return false
            }
            return zip(self.parameters, parameters).allSatisfy(Self.equal)
        }

        private static func equal(_ first: RuntimeValueType, _ second: RuntimeValueType) -> Bool {
            first === second || ABIValueTypesEqual(first.handle, second.handle)
        }
    }

    // Only native layouts are cached: no Swift metatypes, codecs, images or
    // callback bodies. Active handles retain interfaces independently of eviction.
    private static let cache = Mutex<[Entry]>([])

    package static func cached(
        result: RuntimeValueType,
        parameters: [RuntimeValueType],
        errorPlan: RuntimeErrorConvention? = nil
    ) throws -> RuntimeSwiftCallInterface {
        try cache.withLock { entries in
            if let entry = entries.last(where: {
                $0.matches(result: result, parameters: parameters, errorPlan: errorPlan)
            }) {
                return entry.interface
            }
            let interface = try RuntimeSwiftCallInterface(
                result: result,
                parameters: parameters,
                errorPlan: errorPlan
            )
            if entries.count == 64 { entries.removeFirst() }
            entries.append(
                Entry(
                    result: result,
                    parameters: parameters,
                    error: errorPlan?.type,
                    typedError: errorPlan?.isTyped ?? false,
                    interface: interface
                )
            )
            return interface
        }
    }
}
