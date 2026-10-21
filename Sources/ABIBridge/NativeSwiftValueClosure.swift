import ABIBridgeCore
import ABIBridgeRuntime

extension NativeSwiftValue {
    /// Resolves an owned closure without blocking the caller's executor.
    ///
    /// Owned runtime values use the maximally abstracted function convention. The requested signature preserves
    /// its effects, isolation, and argument ownership, and may use runtime value handles
    /// for types unavailable at compile time. This value remains available; the returned
    /// closure owns its captured context and implementation images independently.
    public nonisolated(nonsending) func resolveClosure<Signature>(
        as signature: Signature.Type
    ) async throws -> NativeSwiftClosure<Signature> {
        let source = try closureSource()
        let nativeType = type
        let function = UInt(bitPattern: source.address.load(as: ABISwiftClosureValue.self).function)
        let codec = try await NativePreparation.run {
            try Self.closureCodec(for: nativeType, function: function, as: signature)
        }
        return try withExtendedLifetime(source) {
            try codec.makeValue(
                source.address.load(as: ABISwiftClosureValue.self),
                nativeType,
                false,
                source.codeLifetime
            ) as! NativeSwiftClosure<Signature>
        }
    }

    /// Resolves an owned closure synchronously on the caller's thread.
    ///
    /// Resolution joins any required ABI preparation already in progress. The returned
    /// closure retains its context and code independently without consuming this value.
    public func resolveClosureAndWait<Signature>(
        as signature: Signature.Type
    ) throws -> NativeSwiftClosure<Signature> {
        let source = try closureSource()
        let function = UInt(bitPattern: source.address.load(as: ABISwiftClosureValue.self).function)
        let codec = try Self.closureCodec(for: type, function: function, as: signature)
        return try withExtendedLifetime(source) {
            try codec.makeValue(
                source.address.load(as: ABISwiftClosureValue.self),
                type,
                false,
                source.codeLifetime
            ) as! NativeSwiftClosure<Signature>
        }
    }

    private static func closureCodec<Signature>(
        for type: NativeSwiftType,
        function: UInt,
        as signature: Signature.Type
    ) throws -> SwiftClosureCodec {
        let plan = try SwiftGenericClosurePlan.storedValue(
            type.metadata,
            as: signature,
            resolver: type.resolver,
            retaining: type.codeImages
        )
        guard plan.isEscaping else {
            throw ABIResolutionError.unsupportedDeclaration(
                "A nonescaping native closure cannot be resolved as an owned closure."
            )
        }
        return try NativeSwiftClosure<Signature>.makeClosureCodec(
            generic: plan,
            preparingFunction: function
        )
    }

    private func closureSource() throws -> NativeValueStorage {
        let source = try access(.borrowing)
        guard runtimeMetadataKind(type.metadata) == .function else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Expected a Swift function value: " + type.name + "."
            )
        }
        return source
    }
}

extension SwiftGenericClosurePlan {
    // Owned runtime values contain the maximally abstracted function-value convention.
    // Host markers describe conversions while the native metadata continues to own the
    // transport, authentication discriminator, and formal error storage.
    static func storedValue(
        _ nativeType: Any.Type,
        as hostType: Any.Type,
        resolver: SymbolResolver,
        retaining images: [NativeImage]
    ) throws -> SwiftGenericClosurePlan {
        let native = try SwiftFunctionSignature(nativeType, nativeConventions: true)
        let host = try SwiftFunctionSignature(hostType)
        try validateEffects(native: native, host: host)
        for parameter in native.parameters { try validateSwiftRuntimeValueStorage(parameter) }
        try validateSwiftRuntimeValueStorage(native.result)
        guard native.parameters.count == host.parameters.count else {
            throw mismatch(nativeType, hostType)
        }
        let source = try nativeValue(nativeType)
        func runtimePlan(_ metadata: Any.Type) throws -> SwiftRuntimeValuePlan {
            try SwiftRuntimeValuePlan(
                metadata: metadata,
                type: SwiftValueSchema.storage(of: metadata),
                resolver: resolver,
                retaining: images,
                nativeClosure: closureInStoredValue(metadata)
            )
        }
        func argument(
            native metadata: Any.Type,
            host representation: Any.Type,
            convention: SwiftArgumentConvention,
            wrapped: Bool = false
        ) throws -> SwiftGenericArgument {
            if let wrapper = representation as? any SwiftConventionArgument.Type {
                guard wrapper.convention == convention else {
                    throw mismatch(nativeType, hostType)
                }
                let nested = try argument(
                    native: metadata,
                    host: wrapper.wrappedType,
                    convention: convention,
                    wrapped: true
                )
                return .convention(try wrapper.makeArgumentCodec(generic: nested))
            }
            guard convention == .borrowing || wrapped else { throw mismatch(nativeType, hostType) }
            if representation == NativeSwiftValue.self
                || representation == NativeSwiftBorrowedValue.self
            {
                return .runtimeValue(
                    try runtimePlan(metadata),
                    convention: convention,
                    asynchronous: native.isAsync
                )
            }
            if let closure = representation as? any SwiftClosureValue.Type {
                return .closure(
                    try storedValue(
                        metadata,
                        as: closure.swiftFunctionType,
                        resolver: resolver,
                        retaining: images
                    ),
                    asynchronous: native.isAsync
                )
            }
            guard metadata == representation else { throw mismatch(nativeType, hostType) }
            return .value(
                try SwiftValueSchema.storage(of: metadata),
                consuming: convention == .consuming
            )
        }
        let arguments = try zip(native.parameters, host.parameters).enumerated().map {
            index,
            pair in
            try argument(
                native: pair.0,
                host: pair.1,
                convention: native.parameterConventions[index]
            )
        }
        let result: SwiftGenericResult
        if host.result == NativeSwiftValue.self || host.result == NativeSwiftBorrowedValue.self {
            result = .runtimeValue(try runtimePlan(native.result))
        } else if let closure = host.result as? any SwiftClosureValue.Type {
            let nested = try storedValue(
                native.result,
                as: closure.swiftFunctionType,
                resolver: resolver,
                retaining: images
            )
            result = .closure(try closure.makeGenericClosureCodec(plan: nested))
        } else {
            guard native.result == host.result else { throw mismatch(nativeType, hostType) }
            result = .value(try SwiftValueSchema.storage(of: native.result))
        }
        return SwiftGenericClosurePlan(
            transport: source.transport,
            parameters: SwiftGenericParameters(actual: host.parameters, arguments: arguments)
                .usingStorageConvention(),
            discriminator: source.discriminator,
            authentication: source.authentication,
            isEscaping: source.isEscaping,
            resultConstants: source.resultConstants,
            errorPlan: source.errorPlan,
            runtimeArguments: arguments.map { argument in
                guard let plan = argument.runtimeValue else { return nil }
                return SwiftCallbackRuntimeArgument(
                    plan: plan,
                    borrowed: true,
                    asynchronous: native.isAsync,
                    convention: argument.convention
                )
            },
            result: result,
            nativeResult: native.result,
            hostParameters: host.parameters,
            nativeParameters: native.parameters,
            nativeArgumentClosures: source.nativeArgumentClosures,
            nativeResultClosure: source.nativeResultClosure
        )
    }

    private static func validateEffects(
        native: SwiftFunctionSignature,
        host: SwiftFunctionSignature
    ) throws {
        let nativeEffects = native.attributes
        let hostEffects = host.attributes
        let sameActor = native.globalActor == host.globalActor
        // Swift 6 infers @Sendable for global-actor function types. Legacy
        // metadata need not carry that flag; the handle remains non-Sendable.
        let sameSendability =
            nativeEffects.isSendable == hostEffects.isSendable
            || (sameActor && native.globalActor == MainActor.self)
        guard native.isAsync == host.isAsync, native.failure == host.failure,
            sameActor, sameSendability,
            nativeEffects.isolation == hostEffects.isolation,
            nativeEffects.hasSendingResult == hostEffects.hasSendingResult,
            nativeEffects.parameterFlags == hostEffects.parameterFlags
        else {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    expected: "The native closure's effects, isolation, and argument attributes",
                    found: []
                )
            )
        }
    }

    private static func mismatch(_ native: Any.Type, _ host: Any.Type) -> ABIResolutionError {
        .signatureMismatch(
            .init(
                expected: String(reflecting: native),
                found: [String(reflecting: host)]
            )
        )
    }
}
