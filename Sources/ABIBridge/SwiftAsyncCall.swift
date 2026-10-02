import ABIBridgeCore

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
    init(result: CValueType, parameters: [CValueType], errorPlan: SwiftErrorPlan?, inheritsCallerIsolation: Bool) throws {
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

struct SwiftAsyncCall: Sendable {
    let interface: SwiftAsyncCallInterface
    private let values: SwiftCallValues
    let errorPlan: SwiftErrorPlan?
    private let hasTrailingValue: Bool
    private let generic: SwiftGenericCallPlan?

    init(signature: Any.Type, trailingType: CValueType? = nil, consumesArguments: Bool = false,
         errorPlan: SwiftErrorPlan? = nil, inheritsCallerIsolation: Bool, opaqueResult: SwiftOpaqueResultPlan? = nil, generic: SwiftGenericCallPlan? = nil) throws {
        try generic?.validateMetadataArguments()
        values = try SwiftCallValues(signature: SwiftFunctionSignature(signature), consumesArguments: consumesArguments,
            opaqueResult: opaqueResult, generic: generic)
        let logical = values.arguments.map(\.type)
        var types = generic?.parameters.types(from: logical) ?? logical
        if let trailingType { types.append(trailingType) }
        if let generic {
            types += Array(repeating: try CValueType(scalar: ABIValuePointer), count: generic.metadata.count)
        }
        self.generic = generic
        interface = try SwiftAsyncCallInterface(result: values.result.type, parameters: types,
            errorPlan: errorPlan, inheritsCallerIsolation: inheritsCallerIsolation)
        self.errorPlan = errorPlan
        hasTrailingValue = trailingType != nil

    }

    @unsafe nonisolated(nonsending) func unsafeInvoke<Result, each Argument>(
        implementation: SwiftAsyncImplementation, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, retaining owner: Any? = nil,
        retainingCode codeOwner: Any? = nil, didInvoke: (() -> Void)? = nil,
        _ values: repeat each Argument
    ) async throws -> Result {
        try unsafe await unsafeInvoke(entry: implementation.entry, context: context,
            trailingValue: trailingValue, retaining: (implementation, owner),
            retainingCode: (implementation, codeOwner), didInvoke: didInvoke, repeat each values)
    }

    @unsafe nonisolated(nonsending) func unsafeInvoke<Result, each Argument>(
        entry: SwiftAsyncEntry, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, retaining owner: Any? = nil,
        retainingCode codeOwner: Any? = nil, didInvoke: (() -> Void)? = nil,
        _ values: repeat each Argument
    ) async throws -> Result {
        precondition(hasTrailingValue == (trailingValue != nil))
        let logicalStorage = try self.values.encode(repeat each values, retainingCode: (codeOwner, generic))
        let logicalAddresses: [UnsafeMutableRawPointer?] = logicalStorage.map(\.address)
        let encoded = generic?.parameters.encode(logicalAddresses)
        var addresses = encoded?.addresses ?? logicalAddresses
        if let trailingValue { addresses.append(trailingValue.address) }
        if let generic { addresses.append(contentsOf: generic.metadata.addresses) }
        let output = self.values.result.makeStorage()
        let nativeError = errorPlan?.makeStorage()
        let codeOwners: Any = (entry, codeOwner, generic)
        var failure: OpaquePointer?
        let invocation = addresses.withUnsafeBufferPointer {
            ABICreateSwiftAsyncInvocation(interface.handle,
                entry.function,
                entry.contextSize, output.address, $0.baseAddress, context,
                nativeError?.address, &failure)
        }
        guard let invocation else { throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftAsyncInvocation") }
        defer {
            withExtendedLifetime((self, entry, logicalStorage, encoded, output, nativeError, trailingValue, owner, codeOwners)) {
                ABIReleaseSwiftAsyncInvocation(invocation)
            }
        }
        await invokeSwiftAsync(invocation)
        self.values.relinquishConsumed(logicalStorage)
        didInvoke?()
        if ABISwiftAsyncInvocationDidThrow(invocation), let errorPlan, let nativeError {
            throw NativeSwiftError(try errorPlan.decode(nativeError), retainingCode: codeOwners)
        }
        return try self.values.decode(output, retaining: owner, retainingCode: codeOwners)
    }
}
