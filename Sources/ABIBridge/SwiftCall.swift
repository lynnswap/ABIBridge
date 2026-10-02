import ABIBridgeCore

struct SwiftCall: Sendable {
    let interface: SwiftCallInterface
    let errorPlan: SwiftErrorPlan?
    private let values: SwiftCallValues
    private let hasTrailingValue: Bool
    private let generic: SwiftGenericCallPlan?

    init(signature: Any.Type, trailingType: CValueType? = nil, consumesArguments: Bool = false, errorPlan: SwiftErrorPlan? = nil, opaqueResult: SwiftOpaqueResultPlan? = nil, generic: SwiftGenericCallPlan? = nil) throws {
        try generic?.validateMetadataArguments()
        self.errorPlan = errorPlan
        self.generic = generic
        values = try SwiftCallValues(signature: SwiftFunctionSignature(signature), consumesArguments: consumesArguments,
            opaqueResult: opaqueResult, generic: generic)
        let logical = values.arguments.map(\.type)
        var parameters = generic?.parameters.types(from: logical) ?? logical
        if let trailingType { parameters.append(trailingType) }
        if let generic {
            parameters += Array(repeating: try CValueType(scalar: ABIValuePointer), count: generic.metadata.count)
        }
        interface = try SwiftCallInterface.cached(result: values.result.type, parameters: parameters, errorPlan: errorPlan)
        hasTrailingValue = trailingType != nil

    }

    @unsafe func unsafeInvoke<Result, each Argument>(
        symbol: ResolvedSymbol, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, retaining owner: Any? = nil,
        retainingCode codeOwner: Any? = nil,
        didInvoke: (() -> Void)? = nil, implementation: SwiftImplementation? = nil,
        _ values: repeat each Argument
    ) throws -> Result {
        try unsafe symbol.withUnsafeAddress { address in
            try unsafe unsafeInvoke(
                function: implementation?.function ?? ABIUnsafeFunctionAtAddress(address),
                context: context, trailingValue: trailingValue, retaining: (owner ?? symbol, implementation),
                retainingCode: (symbol.image, implementation, codeOwner),
                didInvoke: didInvoke, repeat each values
            )
        }
    }

    @unsafe func unsafeInvoke<Result, each Argument>(
        function: ABIUnmanagedFunction, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, retaining owner: Any?,
        retainingCode codeOwner: Any? = nil,
        didInvoke: (() -> Void)? = nil, _ values: repeat each Argument
    ) throws -> Result {
        precondition(hasTrailingValue == (trailingValue != nil))
        let logicalStorage = try self.values.encode(repeat each values, retainingCode: (codeOwner, generic))
        let logicalAddresses: [UnsafeMutableRawPointer?] = logicalStorage.map(\.address)
        let encoded = generic?.parameters.encode(logicalAddresses)
        var addresses = encoded?.addresses ?? logicalAddresses
        if let trailingValue { addresses.append(trailingValue.address) }
        if let generic { addresses.append(contentsOf: generic.metadata.addresses) }
        let output = self.values.result.makeStorage()
        let nativeError = errorPlan?.makeStorage()
        var didThrow = false
        return try withExtendedLifetime((logicalStorage, encoded, trailingValue, owner, generic)) {
            var failure: OpaquePointer?
            let success = addresses.withUnsafeBufferPointer { addresses in
                if let nativeError {
                    return ABIUnsafeInvokeSwiftThrowingCallInterface(
                        interface.handle, function, output.address, addresses.baseAddress, context,
                        nativeError.address, &didThrow, &failure
                    )
                }
                return ABIUnsafeInvokeSwiftCallInterface(
                    interface.handle, function, output.address, addresses.baseAddress, context, &failure
                )
            }
            guard success else {
                throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftInvocation")
            }
            self.values.relinquishConsumed(logicalStorage)
            didInvoke?()
            if didThrow, let errorPlan, let nativeError {
                throw NativeSwiftError(try errorPlan.decode(nativeError), retainingCode: (codeOwner, generic))
            }
            return try self.values.decode(output, retaining: owner, retainingCode: (codeOwner, generic))
        }
    }
}
