import ABIBridgeCore

final class SwiftCall: Sendable {
    let interface: SwiftCallInterface
    /// The values the interface passes: the arguments, a trailing `self`,
    /// and generic metadata and witness tables.
    let parameterTypes: [CValueType]
    let errorPlan: SwiftErrorPlan?
    let values: SwiftCallValues
    private let hasTrailingValue: Bool
    let generic: SwiftGenericCallPlan?
    let closure: SwiftGenericClosurePlan?
    let parameters: SwiftGenericParameters

    init(signature: Any.Type, trailingType: CValueType? = nil, consumesArguments: Bool = false, errorPlan: SwiftErrorPlan? = nil, opaqueResult: SwiftOpaqueResultPlan? = nil, generic: SwiftGenericCallPlan? = nil, closure: SwiftGenericClosurePlan? = nil) throws {
        try generic?.validateMetadataArguments()
        self.errorPlan = errorPlan
        self.generic = generic
        self.closure = closure
        let signature = try SwiftFunctionSignature(signature)
        var parameters =
            try generic?.parameters ?? closure?.parameters
            ?? SwiftGenericParameters(
                actual: signature.parameters,
                arguments: SwiftGenericParameters.concreteArguments(
                    signature: signature,
                    defaultConsuming: consumesArguments
                )
            )
        var values = try SwiftCallValues(signature: signature, consumesArguments: consumesArguments,
            opaqueResult: opaqueResult, arguments: parameters.arguments,
            result: generic?.result ?? closure?.result)
        if closure == nil {
            parameters = try parameters.passingByAddress(
                values.borrowedArgumentTypes(parameters: parameters, declaration: generic),
                binding: generic?.binding
            )
            if parameters.hasAddressedClosureFields {
                values = try SwiftCallValues(signature: signature, consumesArguments: consumesArguments,
                    opaqueResult: opaqueResult, arguments: parameters.arguments,
                    result: generic?.result ?? closure?.result)
            }
        }
        self.values = values
        self.parameters = parameters
        #if DEBUG
        generic?.checkClosedSchemas(signature, values: values)
        #endif
        let logical = values.arguments.map(\.type)
        var types = self.parameters.types(from: logical)
        if let trailingType { types.append(trailingType) }
        if let generic {
            types += Array(
                repeating: try CValueType(scalar: ABIValuePointer),
                count: generic.metadata.count
            )
        }
        parameterTypes = types
        if let closure {
            guard case .synchronous(let original) = closure.transport else {
                preconditionFailure("A synchronous closure has a synchronous transport.")
            }
            interface = original
        } else {
            interface = try SwiftCallInterface.cached(
                result: values.result.type,
                parameters: types,
                errorPlan: errorPlan
            )
        }
        hasTrailingValue = trailingType != nil

    }

    @unsafe func unsafeInvoke<Result, each Argument>(
        entry: SwiftEntry, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, receiverStorage: NativeValueStorage? = nil, retaining owner: Any? = nil,
        retainingCode codeOwner: Any? = nil,
        didInvoke: (() -> Void)? = nil,
        _ values: repeat each Argument
    ) throws -> Result {
        try self.values.requireIndependentResult()
        return try unsafe invoke(entry: entry, context: context, trailingValue: trailingValue, receiverStorage: receiverStorage,
            retaining: owner, retainingCode: codeOwner, didInvoke: didInvoke, repeat each values) { output, owner, codeOwner in
            try self.values.decode(output, retaining: owner, retainingCode: codeOwner)
        }
    }

    @unsafe func unsafeInvoke<Result: ~Copyable, each Argument>(
        entry: SwiftEntry, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, receiverStorage: NativeValueStorage? = nil, retaining owner: Any? = nil,
        retainingCode codeOwner: Any? = nil,
        didInvoke: (() -> Void)? = nil,
        _ values: repeat each Argument,
        withResult body: (NativeSwiftBorrowedValue) throws -> Result
    ) throws -> Result {
        let result = try self.values.scopedResult()
        return try unsafe invoke(entry: entry, context: context, trailingValue: trailingValue, receiverStorage: receiverStorage,
            retaining: owner, retainingCode: codeOwner, didInvoke: didInvoke, repeat each values) { output, _, _ in
            try result.withBorrowedResult(output, body)
        }
    }

    @unsafe func unsafeInvoke<Result, each Argument>(
        function: ABIUnmanagedFunction, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, receiverStorage: NativeValueStorage? = nil, retaining owner: Any?,
        retainingCode codeOwner: Any? = nil, images: [NativeImage] = [],
        didInvoke: (() -> Void)? = nil, _ values: repeat each Argument
    ) throws -> Result {
        try self.values.requireIndependentResult()
        return try unsafe invoke(function: function, context: context, trailingValue: trailingValue, receiverStorage: receiverStorage,
            retaining: owner, retainingCode: codeOwner, images: images, didInvoke: didInvoke, repeat each values) { output, owner, codeOwner in
            try self.values.decode(output, retaining: owner, retainingCode: codeOwner)
        }
    }

    @unsafe func unsafeInvoke<Result: ~Copyable, each Argument>(
        function: ABIUnmanagedFunction, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, receiverStorage: NativeValueStorage? = nil, retaining owner: Any?,
        retainingCode codeOwner: Any? = nil, images: [NativeImage] = [],
        didInvoke: (() -> Void)? = nil, _ values: repeat each Argument,
        withResult body: (NativeSwiftBorrowedValue) throws -> Result
    ) throws -> Result {
        let result = try self.values.scopedResult()
        return try unsafe invoke(function: function, context: context, trailingValue: trailingValue, receiverStorage: receiverStorage,
            retaining: owner, retainingCode: codeOwner, images: images, didInvoke: didInvoke, repeat each values) { output, _, _ in
            try result.withBorrowedResult(output, body)
        }
    }

    @unsafe func invoke<Result: ~Copyable, each Argument>(
        entry: SwiftEntry, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, receiverStorage: NativeValueStorage? = nil, retaining owner: Any? = nil,
        retainingCode codeOwner: Any? = nil,
        didInvoke: (() -> Void)? = nil,
        _ values: repeat each Argument,
        processingResult: (NativeValueStorage, Any?, Any?) throws -> Result
    ) throws -> Result {
        try unsafe entry.withFunction { function in
            try unsafe invoke(
                function: function,
                context: context, trailingValue: trailingValue, receiverStorage: receiverStorage,
                retaining: (owner ?? entry.symbol, entry.implementation),
                retainingCode: (entry.symbol.image, entry.implementation, codeOwner), images: entry.codeImages,
                didInvoke: didInvoke, repeat each values, processingResult: processingResult
            )
        }
    }

    @unsafe func invoke<Result: ~Copyable, each Argument>(
        function: ABIUnmanagedFunction, context: UnsafeRawPointer? = nil,
        trailingValue: NativeValueStorage? = nil, receiverStorage: NativeValueStorage? = nil, retaining owner: Any?,
        retainingCode codeOwner: Any? = nil, images: [NativeImage] = [],
        didInvoke: (() -> Void)? = nil, _ values: repeat each Argument,
        processingResult: (NativeValueStorage, Any?, Any?) throws -> Result
    ) throws -> Result {
        precondition(hasTrailingValue == (trailingValue != nil))
        let transfer = try self.values.encode(repeat each values, retainingCode: (codeOwner, generic, closure))
        let encoded = parameters.encode(transfer.addresses, retaining: transfer.storage)
        var addresses = encoded.addresses
        if let trailingValue { addresses.append(trailingValue.address) }
        if let generic { addresses.append(contentsOf: generic.metadata.addresses) }
        let output = self.values.result.makeStorage()
        var lifetimes = transfer.codeLifetimes
        if let lifetime = trailingValue?.codeLifetime { lifetimes.append(lifetime) }
        if let lifetime = receiverStorage?.codeLifetime { lifetimes.append(lifetime) }
        if let lifetime = output.codeLifetime { lifetimes.append(lifetime) }
        if let lifetime = SwiftValueCodeLifetime.current { lifetimes.append(lifetime) }
        let lifetime = SwiftValueCodeLifetime.connect(lifetimes,
            retaining: images + (generic?.binding.images ?? []) + (generic?.binding.typeOwners.flatMap(\.codeImages) ?? []))
        let codeOwners: Any = (codeOwner, generic, closure, lifetime)
        let nativeError = errorPlan?.makeStorage()
        var didThrow = false
        return try withExtendedLifetime((transfer, encoded, trailingValue, receiverStorage, owner, generic)) {
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
            transfer.relinquishConsumed()
            didInvoke?()
            let outcome = Swift.Result<Result, any Error> {
                if didThrow, let errorPlan, let nativeError {
                    throw NativeSwiftError(try errorPlan.decode(nativeError), retainingCode: codeOwners)
                }
                return try processingResult(output, owner, codeOwners)
            }
            return try transfer.finish(outcome)
        }
    }
}

extension SwiftCall {
    /// Requires that `replacement`, the plan of another declaration, receives
    /// the calls that native code makes with this plan, so that its code can
    /// stand for this declaration's: each argument and the result pass in
    /// the same registers or by address with the same storage, arguments
    /// keep their ownership, and the other values, such as a trailing `self`,
    /// generic metadata, and witness tables, pass alike. A nonthrowing
    /// replacement can stand for a throwing declaration; a throwing one needs
    /// the same error type.
    ///
    /// - Parameter declaration: The replacement's declaration, which a
    ///   mismatch names.
    func requireReplacement(_ replacement: SwiftCall, declaration: NativeDeclaration) throws {
        func mismatch(
            _ position: ABIResolutionError.SignatureMismatch.Position,
            _ expected: String,
            _ found: String
        ) -> ABIResolutionError {
            .signatureMismatch(
                .init(
                    declaration: declaration,
                    position: position,
                    expected: expected,
                    found: [found]
                )
            )
        }
        try SwiftErrorPlan.validateReplacement(replacement.errorPlan, for: errorPlan)
        for (index, (original, other)) in zip(values.arguments, replacement.values.arguments)
            .enumerated()
        {
            guard SwiftDeclaredLowering.passAlike(original.type, other.type, isResult: false) else {
                throw mismatch(
                    .argument(index),
                    SwiftDeclaredLowering.lowering(of: original.type),
                    SwiftDeclaredLowering.lowering(of: other.type)
                )
            }
            // Ownership is transferred only for values that have it, and an
            // inout argument is another argument than a value.
            guard
                original.convention == other.convention
                    || (original.convention != .inoutValue && other.convention != .inoutValue
                        && !original.hasOwnership && !other.hasOwnership)
            else {
                throw mismatch(
                    .argument(index),
                    original.convention.argumentDescription,
                    other.convention.argumentDescription
                )
            }
        }
        let result = values.result.type, otherResult = replacement.values.result.type
        guard SwiftDeclaredLowering.passAlike(result, otherResult, isResult: true) else {
            throw mismatch(
                .result,
                SwiftDeclaredLowering.lowering(ofResult: result),
                SwiftDeclaredLowering.lowering(ofResult: otherResult)
            )
        }
        guard parameterTypes.count == replacement.parameterTypes.count,
            zip(parameterTypes, replacement.parameterTypes).allSatisfy({
                SwiftDeclaredLowering.passAlike($0, $1, isResult: false)
            })
        else {
            func describe(_ types: [CValueType]) -> String {
                types.map { SwiftDeclaredLowering.lowering(of: $0) }.joined(separator: "; ")
            }
            throw mismatch(
                .signature,
                describe(parameterTypes),
                describe(replacement.parameterTypes)
            )
        }
    }
}

extension SwiftArgumentConvention {
    fileprivate var argumentDescription: String {
        switch self {
        case .borrowing: "a borrowed argument"
        case .consuming: "a consumed argument"
        case .inoutValue: "an inout argument"
        }
    }
}
