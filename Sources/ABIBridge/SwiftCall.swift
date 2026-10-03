import ABIBridgeCore

final class SwiftCall: Sendable {
    let interface: SwiftCallInterface
    let errorPlan: SwiftErrorPlan?
    private let values: SwiftCallValues
    private let hasTrailingValue: Bool
    let generic: SwiftGenericCallPlan?
    let closure: SwiftGenericClosurePlan?
    private let parameters: SwiftGenericParameters

    init(signature: Any.Type, trailingType: CValueType? = nil, consumesArguments: Bool = false, errorPlan: SwiftErrorPlan? = nil, opaqueResult: SwiftOpaqueResultPlan? = nil, generic: SwiftGenericCallPlan? = nil, closure: SwiftGenericClosurePlan? = nil) throws {
        try generic?.validateMetadataArguments()
        self.errorPlan = errorPlan
        self.generic = generic
        self.closure = closure
        let signature = try SwiftFunctionSignature(signature)
        parameters = try generic?.parameters ?? closure?.parameters ?? SwiftGenericParameters(actual: signature.parameters,
            arguments: SwiftGenericParameters.concreteArguments(signature: signature, defaultConsuming: consumesArguments))
        values = try SwiftCallValues(signature: signature, consumesArguments: consumesArguments,
            opaqueResult: opaqueResult, arguments: parameters.arguments,
            result: generic?.result ?? closure?.result ?? .concrete)
        let logical = values.arguments.map(\.type)
        var parameters = self.parameters.types(from: logical)
        if let trailingType { parameters.append(trailingType) }
        if let generic {
            parameters += Array(repeating: try CValueType(scalar: ABIValuePointer), count: generic.metadata.count)
        }
        if let closure {
            guard case .synchronous(let original) = closure.transport else {
                preconditionFailure("A synchronous closure has a synchronous transport.")
            }
            interface = original
        } else {
            interface = try SwiftCallInterface.cached(result: values.result.type, parameters: parameters, errorPlan: errorPlan)
        }
        hasTrailingValue = trailingType != nil

    }

    @unsafe func unsafeInvoke<Result, each Argument>(
        symbol: ResolvedSymbol, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, receiverStorage: NativeValueStorage? = nil, retaining owner: Any? = nil,
        retainingCode codeOwner: Any? = nil,
        didInvoke: (() -> Void)? = nil, implementation: SwiftImplementation? = nil,
        _ values: repeat each Argument
    ) throws -> Result {
        try unsafe symbol.withUnsafeAddress { address in
            try unsafe unsafeInvoke(
                function: implementation?.function ?? ABIUnsafeFunctionAtAddress(address),
                context: context, trailingValue: trailingValue, receiverStorage: receiverStorage, retaining: (owner ?? symbol, implementation),
                retainingCode: (symbol.image, implementation, codeOwner), images: [symbol.image] + [implementation?.image].compactMap { $0 },
                didInvoke: didInvoke, repeat each values
            )
        }
    }

    @unsafe func unsafeInvoke<Result, each Argument>(
        function: ABIUnmanagedFunction, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, receiverStorage: NativeValueStorage? = nil, retaining owner: Any?,
        retainingCode codeOwner: Any? = nil, images: [NativeImage] = [],
        didInvoke: (() -> Void)? = nil, _ values: repeat each Argument
    ) throws -> Result {
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
        var didThrow = false
        return try withExtendedLifetime((logicalStorage, encoded, trailingValue, receiverStorage, owner, generic)) {
            var failure: OpaquePointer?
            let success = SwiftValueCodeLifetime.withCurrent(lifetime) {
                addresses.withUnsafeBufferPointer { addresses in
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
            }
            guard success else {
                throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftInvocation")
            }
            encoded.finishInvocation()
            self.values.relinquishConsumed(logicalStorage)
            didInvoke?()
            let outcome = Swift.Result<Result, any Error> {
                if didThrow, let errorPlan, let nativeError {
                    throw NativeSwiftError(try errorPlan.decode(nativeError), retainingCode: codeOwners)
                }
                return try self.values.decode(output, retaining: owner, retainingCode: codeOwners)
            }
            return try self.values.finishInvocation(outcome, storage: logicalStorage)
        }
    }
}
