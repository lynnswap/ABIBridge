import ABIBridgeCore

/// A C-compatible function whose value layouts are described at runtime.
///
/// Prefer NativeFunction and function-type metatypes when Swift types are known. This handle retains its image and prepared signature; input and output values retain their own storage and pointee owners.
public struct DynamicNativeFunction: Sendable {
    /// The resolved symbol and retained image.
    public let symbol: ResolvedSymbol
    /// The concrete input/result layouts and optional variadic boundary.
    public let signature: NativeSignature
    private let interface: CCallInterface
    private let storageLayout: NativeCallStorageLayout

    init(symbol: ResolvedSymbol, signature: NativeSignature) throws {
        self.symbol = symbol
        self.signature = signature
        storageLayout = try NativeCallStorageLayout(
            result: (0, 1),
            parameters: signature.parameters.map { ($0.size, $0.alignment) }
        )
        interface = try CCallInterface(
            result: signature.result.requireCType(),
            parameters: signature.parameters.map { try $0.requireCType() },
            fixedParameterCount: signature.fixedParameterCount
        )
    }

    /// Invokes the native function with values matching the runtime signature.
    ///
    /// Count and layout compatibility are checked before dispatch. Each argument is copied to aligned call storage while its owner stays alive. Results own their byte allocation; ownership of resources referenced by returned pointers must be established by the adapter. Anonymous Float and narrow integer values undergo C default promotions when the signature is variadic. Nontrivial values, consumed arguments, and foreign exceptions need native adapters.
    ///
    /// - Parameter values: Explicit arguments in declaration order.
    /// - Returns: Native result storage that can be cast to a user-defined wrapper.
    /// - Throws: A count/layout mismatch or native call-interface error.
    @unsafe public func unsafeInvoke(with values: [NativeValue]) throws -> NativeValue {
        guard values.count == signature.parameters.count else {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    declaration: symbol.declaration,
                    position: .argumentCount,
                    expected: "\(signature.parameters.count) arguments",
                    found: ["\(values.count) arguments"]
                )
            )
        }
        for (value, expected) in zip(values, signature.parameters) {
            try value.requireLayout(expected)
        }
        return try storageLayout.withStorage { addresses, _ in
            for (index, value) in values.enumerated() {
                unsafe value.withUnsafeBytes {
                    if let base = $0.baseAddress, !$0.isEmpty {
                        addresses[index]!.copyMemory(from: base, byteCount: $0.count)
                    }
                }
            }
            return try withExtendedLifetime(values) {
                try NativeValue(type: signature.result) { output in
                    var failure: OpaquePointer?
                    let success = unsafe symbol.withUnsafeAddress { address in
                        ABIUnsafeInvokeCCallInterface(
                            interface.handle,
                            ABIUnsafeFunctionAtAddress(address),
                            output.baseAddress,
                            addresses.baseAddress,
                            &failure
                        )
                    }
                    guard success else { throw consumeNativeCallFailure(failure) }
                }
            }
        }
    }
}

/// A C or C-compatible C++ function declaration using runtime-known layouts.
///
/// Wrap the declaration with `NativeRequest.c` or `NativeRequest.cxx`, then
/// resolve it with an `ABIRuntime`. Construction does not perform lookup or
/// validate native layouts; resolution prepares the call and retains its image.
public struct DynamicNativeFunctionRequest: Sendable {
    let name: String
    var language: NativeLanguage
    let signature: NativeSignature

    /// Describes the explicit arguments and result of a native function.
    ///
    /// The signature supplies all concrete layouts and its variadic boundary.
    /// C names omit the Mach-O underscore. C++ names are complete demangled
    /// declarations that select an overload. The declaration name does not
    /// establish that the supplied signature matches the native ABI.
    public static func function(
        _ name: String,
        signature: NativeSignature
    ) -> Self {
        Self(name: name, language: .c, signature: signature)
    }
}

extension NativeRequest {
    /// Describes a C function.
    public static func c(
        _ declaration: DynamicNativeFunctionRequest
    ) -> Self where Declaration == DynamicNativeFunctionRequest {
        var declaration = declaration
        declaration.language = .c
        return Self(declaration: declaration)
    }

    /// Describes a C-compatible C++ free or static function.
    public static func cxx(
        _ declaration: DynamicNativeFunctionRequest
    ) -> Self where Declaration == DynamicNativeFunctionRequest {
        var declaration = declaration
        declaration.language = .cxx
        return Self(declaration: declaration)
    }
}

extension ABIRuntime {
    /// Resolves a C or C-compatible C++ function using runtime-known layouts.
    ///
    /// Search and call preparation run synchronously on the caller's thread.
    /// An explicit prepare is optional; lookup joins any required work already
    /// in progress. Nontrivial C++ values and exceptions require a compiler
    /// adapter.
    ///
    /// - Parameters:
    ///   - request: The language, declaration name, and concrete call signature.
    ///   - scope: Images to search; automatic scope considers only loaded images.
    ///   - loading: Whether to acquire and initialize an explicit image.
    /// - Returns: A reusable function retaining its image and prepared signature.
    /// - Throws: A resolution error, unsupported representation, or call preparation error.
    public nonisolated func resolveAndWait(
        _ request: NativeRequest<DynamicNativeFunctionRequest>,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> DynamicNativeFunction {
        let declaration = request.declaration
        return try DynamicNativeFunction(
            symbol: resolver.resolve(
                .init(name: declaration.name, language: declaration.language),
                in: scope,
                loading: loading
            ),
            signature: declaration.signature
        )
    }

    /// Resolves and prepares a C or C-compatible C++ function without blocking
    /// the caller's executor.
    ///
    /// Image acquisition, search, and call preparation run on a worker. An
    /// explicit prepare is optional; lookup joins any required work already in
    /// progress. Native invocation is a separate operation.
    ///
    /// - Returns: A reusable function retaining its image and prepared signature.
    /// - Throws: The same errors as synchronous resolution.
    public nonisolated func resolve(
        _ request: NativeRequest<DynamicNativeFunctionRequest>,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) async throws -> DynamicNativeFunction {
        try await NativePreparation.run {
            try self.resolveAndWait(request, in: scope, loading: loading)
        }
    }

    /// Resolves a C or C-compatible C++ function using runtime-known layouts.
    ///
    /// Search and call preparation run synchronously on the caller's thread.
    /// An explicit prepare is optional; lookup joins any required work already
    /// in progress. Nontrivial C++ values and exceptions require a compiler
    /// adapter.
    ///
    /// - Parameters:
    ///   - request: The language, declaration name, and concrete call signature.
    ///   - image: The retained image whose symbol index can be reused.
    ///   - loading: Whether to acquire and initialize an explicit image.
    /// - Returns: A reusable function retaining its image and prepared signature.
    /// - Throws: A resolution error, unsupported representation, or call preparation error.
    public nonisolated func resolveAndWait(
        _ request: NativeRequest<DynamicNativeFunctionRequest>,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> DynamicNativeFunction {
        let declaration = request.declaration
        return try DynamicNativeFunction(
            symbol: resolver.resolve(
                .init(name: declaration.name, language: declaration.language),
                in: image,
                loading: loading
            ),
            signature: declaration.signature
        )
    }

    /// Resolves and prepares a C or C-compatible C++ function without blocking
    /// the caller's executor.
    ///
    /// Image acquisition, search, and call preparation run on a worker. An
    /// explicit prepare is optional; lookup joins any required work already in
    /// progress. Native invocation is a separate operation.
    ///
    /// - Returns: A reusable function retaining its image and prepared signature.
    /// - Throws: The same errors as synchronous resolution.
    public nonisolated func resolve(
        _ request: NativeRequest<DynamicNativeFunctionRequest>,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) async throws -> DynamicNativeFunction {
        try await NativePreparation.run {
            try self.resolveAndWait(request, in: image, loading: loading)
        }
    }
}
