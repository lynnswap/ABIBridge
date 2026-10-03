import ABIBridgeCore
import Synchronization

@_silgen_name("ABIInvokeSwiftAsync")
nonisolated(nonsending) func invokeSwiftAsync(_ invocation: OpaquePointer) async

struct SwiftAsyncImplementation: Sendable {
    let symbol: ResolvedSymbol
    let descriptor: ResolvedSymbol
    let entry: SwiftAsyncEntry

    init(symbol: ResolvedSymbol, resolver: SymbolResolver) throws {
        let descriptor = try resolver.resolve(.init(
            name: "async function pointer to " + symbol.declaration.name, language: .swift, kind: .data),
            in: symbol.image, loading: .loadedOnly)
        try self.init(symbol: symbol, descriptor: descriptor)
    }

    init(symbol: ResolvedSymbol, descriptor: ResolvedSymbol) throws {
        self.symbol = symbol
        self.descriptor = descriptor
        entry = try SwiftAsyncEntry(descriptor: UnsafeRawPointer(bitPattern: UInt(descriptor.address))!)
    }
}

final class SwiftAsyncEntry: @unchecked Sendable {
    let handle: OpaquePointer
    var function: ABIUnmanagedFunction { ABISwiftAsyncDescriptorFunction(handle)! }
    var contextSize: UInt32 { ABISwiftAsyncDescriptorContextSize(handle) }
    init(descriptor: UnsafeRawPointer) throws {
        var failure: OpaquePointer?
        guard let handle = ABICopySwiftAsyncDescriptor(descriptor, &failure) else {
            throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftAsyncInvocation")
        }
        self.handle = handle
    }
    deinit { ABIReleaseSwiftAsyncDescriptor(handle) }
}

final class SwiftAsyncCallInterface: @unchecked Sendable {
    let handle: OpaquePointer
    let inheritsCallerIsolation: Bool
    private let callback = Mutex<SwiftAsyncClosureCallbackOwner?>(nil)

    func closureEntry() throws -> SwiftAsyncClosureCallbackOwner {
        try callback.withLock { cached in
            if let cached { return cached }
            let entry = try SwiftAsyncClosureCallbackOwner(interface: self)
            cached = entry
            return entry
        }
    }
    init(result: CValueType, parameters: [CValueType], errorPlan: SwiftErrorPlan?, inheritsCallerIsolation: Bool) throws {
        self.inheritsCallerIsolation = inheritsCallerIsolation
        let handles: [OpaquePointer?] = parameters.map(\.handle)
        var failure: OpaquePointer?
        let handle = withExtendedLifetime((result, parameters, errorPlan)) {
            handles.withUnsafeBufferPointer {
                ABICreateSwiftAsyncCallInterface(result.handle, $0.baseAddress, $0.count,
                    errorPlan?.type.handle, errorPlan?.isTyped ?? false, inheritsCallerIsolation, &failure)
            }
        }
        guard let handle else { throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftAsyncInvocation") }
        self.handle = handle
    }
    deinit { ABIReleaseSwiftAsyncCallInterface(handle) }
}

final class SwiftAsyncCall: Sendable {
    let interface: SwiftAsyncCallInterface
    let values: SwiftCallValues
    let errorPlan: SwiftErrorPlan?
    private let hasTrailingValue: Bool
    let generic: SwiftGenericCallPlan?
    let closure: SwiftGenericClosurePlan?
    let parameters: SwiftGenericParameters

    init(signature: Any.Type, trailingType: CValueType? = nil, consumesArguments: Bool = false,
         errorPlan: SwiftErrorPlan? = nil, inheritsCallerIsolation: Bool, opaqueResult: SwiftOpaqueResultPlan? = nil, generic: SwiftGenericCallPlan? = nil, closure: SwiftGenericClosurePlan? = nil) throws {
        try generic?.validateMetadataArguments()
        let signature = try SwiftFunctionSignature(signature)
        parameters = try generic?.parameters ?? closure?.parameters ?? SwiftGenericParameters(actual: signature.parameters,
            arguments: SwiftGenericParameters.concreteArguments(signature: signature, defaultConsuming: consumesArguments))
        values = try SwiftCallValues(signature: signature, consumesArguments: consumesArguments,
            opaqueResult: opaqueResult, arguments: parameters.arguments,
            result: generic?.result ?? closure?.result ?? .concrete)
        let logical = values.arguments.map(\.type)
        var types = parameters.types(from: logical)
        if let trailingType { types.append(trailingType) }
        if let generic {
            types += Array(repeating: try CValueType(scalar: ABIValuePointer), count: generic.metadata.count)
        }
        self.generic = generic
        self.closure = closure
        if let closure {
            guard case .asynchronous(let original, _) = closure.transport else {
                preconditionFailure("An async closure has an async transport.")
            }
            interface = original
        } else {
            interface = try SwiftAsyncCallInterface(result: values.result.type, parameters: types,
                errorPlan: errorPlan, inheritsCallerIsolation: inheritsCallerIsolation)
        }
        self.errorPlan = errorPlan
        hasTrailingValue = trailingType != nil

    }

    @unsafe nonisolated(nonsending) func unsafeInvoke<Result, each Argument>(
        implementation: SwiftAsyncImplementation, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, receiverStorage: NativeValueStorage? = nil, retaining owner: Any? = nil,
        retainingCode codeOwner: Any? = nil, didInvoke: (() -> Void)? = nil,
        _ values: repeat each Argument
    ) async throws -> Result {
        try unsafe await unsafeInvoke(entry: implementation.entry, context: context,
            trailingValue: trailingValue, receiverStorage: receiverStorage, retaining: (implementation, owner),
            retainingCode: (implementation, codeOwner), images: [implementation.symbol.image, implementation.descriptor.image], didInvoke: didInvoke, repeat each values)
    }

    @unsafe nonisolated(nonsending) func unsafeInvoke<Result, each Argument>(
        entry: SwiftAsyncEntry, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, receiverStorage: NativeValueStorage? = nil, retaining owner: Any? = nil,
        retainingCode codeOwner: Any? = nil, images: [NativeImage] = [], didInvoke: (() -> Void)? = nil,
        _ values: repeat each Argument
    ) async throws -> Result {
        precondition(hasTrailingValue == (trailingValue != nil))
        let logicalStorage = try self.values.encode(repeat each values, retainingCode: (codeOwner, generic, closure))
        let logicalAddresses: [UnsafeMutableRawPointer?] = logicalStorage.map(\.address)
        let encoded = parameters.encode(logicalAddresses, retaining: logicalStorage)
        var addresses = encoded.addresses
        if let trailingValue { addresses.append(trailingValue.address) }
        if let generic { addresses.append(contentsOf: generic.metadata.addresses) }
        let output = self.values.result.makeStorage()
        let lifetimes = (logicalStorage + [trailingValue, receiverStorage, output].compactMap { $0 }).compactMap(\.codeLifetime)
            + [SwiftValueCodeLifetime.current].compactMap { $0 }
        let lifetime = SwiftValueCodeLifetime.connect(lifetimes,
            retaining: images + (generic?.binding.images ?? []) + (generic?.binding.typeOwners.flatMap(\.codeImages) ?? []))
        let codeOwners: Any = (codeOwner, generic, closure, lifetime)
        let nativeError = errorPlan?.makeStorage()
        var failure: OpaquePointer?
        let invocation = addresses.withUnsafeBufferPointer {
            ABICreateSwiftAsyncInvocation(interface.handle,
                entry.function,
                entry.contextSize, output.address, $0.baseAddress, context,
                nativeError?.address, &failure)
        }
        guard let invocation else { throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftAsyncInvocation") }
        defer {
            withExtendedLifetime((self, entry, logicalStorage, encoded, output, nativeError, trailingValue, receiverStorage, owner, codeOwners)) {
                ABIReleaseSwiftAsyncInvocation(invocation)
            }
        }
        await SwiftValueCodeLifetime.withCurrent(lifetime) { await invokeSwiftAsync(invocation) }
        encoded.finishInvocation()
        self.values.relinquishConsumed(logicalStorage)
        didInvoke?()
        let outcome = Swift.Result<Result, any Error> {
            if ABISwiftAsyncInvocationDidThrow(invocation), let errorPlan, let nativeError {
                throw NativeSwiftError(try errorPlan.decode(nativeError), retainingCode: codeOwners)
            }
            return try self.values.decode(output, retaining: owner, retainingCode: codeOwners)
        }
        return try self.values.finishInvocation(outcome, storage: logicalStorage)
    }
}
