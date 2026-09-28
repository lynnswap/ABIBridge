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

struct SwiftAsyncCall<Result, each Argument>: Sendable {
    let interface: SwiftAsyncCallInterface
    private let arguments: (repeat SwiftValueCodec<each Argument>)
    private let result: SwiftValueCodec<Result>
    let errorPlan: SwiftErrorPlan?
    private let hasTrailingValue: Bool
    private let consumesArguments: Bool

    init(trailingType: CValueType? = nil, consumesArguments: Bool = false,
         errorPlan: SwiftErrorPlan? = nil, inheritsCallerIsolation: Bool) throws {
        let arguments = (repeat try SwiftValueCodec<each Argument>())
        let result = try SwiftValueCodec<Result>()
        var types: [CValueType] = []
        for argument in repeat each arguments { types.append(argument.type) }
        if let trailingType { types.append(trailingType) }
        interface = try SwiftAsyncCallInterface(result: result.type, parameters: types,
            errorPlan: errorPlan, inheritsCallerIsolation: inheritsCallerIsolation)
        self.arguments = arguments
        self.result = result
        self.errorPlan = errorPlan
        hasTrailingValue = trailingType != nil
        self.consumesArguments = consumesArguments
    }

    @unsafe nonisolated(nonsending) func unsafeInvoke(
        implementation: SwiftAsyncImplementation, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, retaining owner: Any? = nil,
        retainingCode codeOwner: Any? = nil, didInvoke: (() -> Void)? = nil,
        _ values: repeat each Argument
    ) async throws -> Result {
        try unsafe await unsafeInvoke(entry: implementation.entry, context: context,
            trailingValue: trailingValue, retaining: (implementation, owner),
            retainingCode: (implementation, codeOwner), didInvoke: didInvoke, repeat each values)
    }

    @unsafe nonisolated(nonsending) func unsafeInvoke(
        entry: SwiftAsyncEntry, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, retaining owner: Any? = nil,
        retainingCode codeOwner: Any? = nil, didInvoke: (() -> Void)? = nil,
        _ values: repeat each Argument
    ) async throws -> Result {
        precondition(hasTrailingValue == (trailingValue != nil))
        var storage: [NativeValueStorage] = []
        for (codec, value) in repeat (each arguments, each values) { storage.append(try codec.encode(value)) }
        var addresses: [UnsafeMutableRawPointer?] = storage.map(\.address)
        if let trailingValue { addresses.append(trailingValue.address) }
        let output = result.makeStorage()
        let nativeError = errorPlan?.makeStorage()
        let codeOwners: Any = (entry, codeOwner)
        var failure: OpaquePointer?
        let invocation = addresses.withUnsafeBufferPointer {
            ABICreateSwiftAsyncInvocation(interface.handle,
                entry.function,
                entry.contextSize, output.address, $0.baseAddress, context,
                nativeError?.address, &failure)
        }
        guard let invocation else { throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftAsyncInvocation") }
        defer {
            withExtendedLifetime((self, entry, storage, output, nativeError, trailingValue, owner, codeOwners)) {
                ABIReleaseSwiftAsyncInvocation(invocation)
            }
        }
        await invokeSwiftAsync(invocation)
        if consumesArguments { for value in storage { value.relinquishValue() } }
        didInvoke?()
        if ABISwiftAsyncInvocationDidThrow(invocation), let errorPlan, let nativeError {
            throw NativeSwiftError(try errorPlan.decode(nativeError), retainingCode: codeOwners)
        }
        return try result.decode(output, retaining: owner, retainingCode: codeOwners)
    }
}
