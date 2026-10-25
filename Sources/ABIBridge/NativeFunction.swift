import ABIBridgeRuntime
import ABIBridgeCore
import ABIBridgeCore.Backend

// The backend owns all types and permits concurrent use of a prepared interface.
// Each invocation supplies independent argument and result storage.
final class CCallInterface: Sendable {
    let runtime: RuntimeCCallInterface
    var handle: OpaquePointer { runtime.handle }
    init(result: CValueType, parameters: [CValueType], fixedParameterCount: Int? = nil) throws {
        runtime = try withRuntimeErrors {
            try RuntimeCCallInterface.cached(
                result: result.runtime,
                parameters: parameters.map(\.runtime),
                fixedParameterCount: fixedParameterCount
            )
        }
    }
}

// Shares the typed marshalling path between free functions and bound methods.
// Hidden pointers are ABI-supplied arguments such as this and an adapter target.
struct CFunctionCall<Result, each Argument>: Sendable {
    private let interface: CCallInterface
    private let arguments: [CArgumentCodec]
    private let result: CValueCodec<Result>
    private let hiddenPointerCount: Int
    private let storageLayout: NativeCallStorageLayout

    init(hiddenPointerCount: Int = 0, variadicFrom: Int? = nil) throws {
        self.hiddenPointerCount = hiddenPointerCount
        var arguments: [CArgumentCodec] = []
        for type in repeat (each Argument).self { arguments.append(try CArgumentCodec(type)) }
        let result = try CValueCodec<Result>()
        var types: [CValueType] = []
        if hiddenPointerCount > 0 {
            types = Array(
                repeating: try CValueType(scalar: ABIValuePointer),
                count: hiddenPointerCount
            )
        }
        types.append(contentsOf: arguments.map(\.type))
        storageLayout = try NativeCallStorageLayout(
            result: (result.type.size, result.type.alignment),
            parameters: types.map { ($0.size, $0.alignment) }
        )
        if let variadicFrom, variadicFrom < 0 || variadicFrom > types.count - hiddenPointerCount {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    expected: "A variadic boundary within the explicit argument list",
                    found: [String(variadicFrom)]
                )
            )
        }
        interface = try CCallInterface(
            result: result.type,
            parameters: types,
            fixedParameterCount: variadicFrom.map { $0 + hiddenPointerCount }
        )
        self.arguments = arguments
        self.result = result
    }

    @unsafe func unsafeInvoke(
        _ function: ABIUnmanagedFunction?,
        hiddenPointers: [UnsafeRawPointer] = [],
        retainingResultOwner owner: Any? = nil,
        _ values: repeat each Argument
    ) throws -> Result {
        precondition(hiddenPointers.count == hiddenPointerCount)
        return try storageLayout.withStorage { addresses, output in
            for (index, pointer) in hiddenPointers.enumerated() {
                addresses[index]!.storeBytes(of: pointer, as: UnsafeRawPointer.self)
            }
            var owners: [NativeValue] = []
            var index = hiddenPointerCount
            for value in repeat each values {
                let owner = try withUnsafePointer(to: value) {
                    try arguments[index - hiddenPointerCount].encode($0, addresses[index]!)
                }
                if let owner {
                    owners.append(owner)
                }
                index += 1
            }
            return try withExtendedLifetime(owners) {
                var failure: OpaquePointer?
                let success = ABIUnsafeInvokeCCallInterface(
                    interface.handle,
                    function,
                    output,
                    addresses.baseAddress,
                    &failure
                )
                guard success else { throw consumeNativeCallFailure(failure) }
                return try result.decode(output, retaining: owner)
            }
        }
    }
}

/// A typed C or C-compatible C++ function that retains its containing image.
///
/// A function handle reuses its prepared signature across calls. The handle is Sendable because it owns immutable call metadata, but the function itself may impose thread or actor requirements. See <doc:CFunctionInvocation>.
public struct NativeFunction<Result, each Argument>: Sendable {
    /// The resolved symbol and image retained for this function.
    public let symbol: ResolvedSymbol

    private let call: CFunctionCall<Result, repeat each Argument>

    init(symbol: ResolvedSymbol, variadicFrom: Int? = nil) throws {
        self.symbol = symbol
        call = try CFunctionCall(variadicFrom: variadicFrom)
    }

    /// Calls the function using the prepared platform C calling convention.
    ///
    /// The caller must ensure the signature matches the native declaration, pointers remain valid, and any thread or ownership requirements are met. Pointer values remain borrowed; the handle does not retain pointees. Variadic calls use the prepared fixed-prefix boundary and standard C promotions for anonymous arguments. Native exceptions and nontrivial C++ values require a compiler adapter.
    ///
    /// - Parameter values: All concrete arguments, including the anonymous tail.
    /// - Returns: The result converted to the requested Swift type.
    /// - Throws: An argument-layout or value-conversion error, including a null
    ///   nonoptional pointer result, or a native call-interface error. Native ABI
    ///   mismatches are not recoverable errors.
    @unsafe public func unsafeInvoke(_ values: repeat each Argument) throws -> Result {
        try unsafe symbol.withUnsafeAddress {
            try unsafe call.unsafeInvoke(ABIUnsafeFunctionAtAddress($0), repeat each values)
        }
    }
}

/// A C or C-compatible C++ function declaration using an ordinary Swift function-type metatype.
///
/// Wrap the declaration with `NativeRequest.c` or `NativeRequest.cxx`, then
/// resolve it with an `ABIRuntime`. Construction does not perform lookup or
/// validate native layouts; resolution prepares the call and retains its image.
public struct NativeFunctionRequest<Result, each Argument>: Sendable {
    let name: String
    let nameForm: NativeSymbolNameForm
    var language: NativeLanguage
    let variadicFrom: Int?

    /// Describes the explicit arguments and result of a native function.
    ///
    /// Integer widths must match the native declaration; use `Int32` for C
    /// `int`. The metatype describes all concrete arguments and the result.
    /// `variadicFrom` is the first anonymous argument index, or nil for a
    /// fixed declaration. Variadic arguments use standard C promotions.
    /// C names omit the Mach-O underscore. C++ names are complete demangled
    /// declarations that select an overload. The declaration name does not
    /// establish that the supplied signature matches the native ABI.
    public static func function(
        _ name: String,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int? = nil
    ) -> Self {
        Self(name: name, nameForm: .source, language: .c, variadicFrom: variadicFrom)
    }
    /// Describes a function by its exact linker spelling, without normalization.
    /// Mach-O's leading underscore is added exactly once.
    public static func function(
        linkerName: String,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int? = nil
    ) -> Self {
        Self(name: linkerName, nameForm: .linker, language: .c, variadicFrom: variadicFrom)
    }

    /// Describes a function by its literal Mach-O symbol-table spelling.
    public static func function(
        machOName: String,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int? = nil
    ) -> Self {
        Self(name: machOName, nameForm: .machO, language: .c, variadicFrom: variadicFrom)
    }

    var nativeDeclaration: NativeDeclaration {
        .init(name: name, language: language, kind: .function, nameForm: nameForm)
    }
}

extension NativeRequest {
    /// Describes a C function.
    public static func c<Result, each Argument>(
        _ declaration: NativeFunctionRequest<Result, repeat each Argument>
    ) -> Self where Declaration == NativeFunctionRequest<Result, repeat each Argument> {
        var declaration = declaration
        declaration.language = .c
        return Self(declaration: declaration)
    }

    /// Describes a C-compatible C++ free or static function.
    public static func cxx<Result, each Argument>(
        _ declaration: NativeFunctionRequest<Result, repeat each Argument>
    ) -> Self where Declaration == NativeFunctionRequest<Result, repeat each Argument> {
        var declaration = declaration
        declaration.language = .cxx
        return Self(declaration: declaration)
    }
}

extension ABIRuntime {
    /// Resolves a C or C-compatible C++ function using an ordinary Swift function-type metatype.
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
    public nonisolated func resolveAndWait<Result, each Argument>(
        _ request: NativeRequest<NativeFunctionRequest<Result, repeat each Argument>>,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeFunction<Result, repeat each Argument> {
        let declaration = request.declaration
        return try NativeFunction(
            symbol: resolver.resolve(
                declaration.nativeDeclaration,
                in: scope,
                loading: loading
            ),
            variadicFrom: declaration.variadicFrom
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
    public nonisolated func resolve<Result, each Argument>(
        _ request: NativeRequest<NativeFunctionRequest<Result, repeat each Argument>>,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) async throws -> NativeFunction<Result, repeat each Argument> {
        try await NativePreparation.run {
            try self.resolveAndWait(request, in: scope, loading: loading)
        }
    }

    /// Resolves a C or C-compatible C++ function using an ordinary Swift function-type metatype.
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
    public nonisolated func resolveAndWait<Result, each Argument>(
        _ request: NativeRequest<NativeFunctionRequest<Result, repeat each Argument>>,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeFunction<Result, repeat each Argument> {
        let declaration = request.declaration
        return try NativeFunction(
            symbol: resolver.resolve(
                declaration.nativeDeclaration,
                in: image,
                loading: loading
            ),
            variadicFrom: declaration.variadicFrom
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
    public nonisolated func resolve<Result, each Argument>(
        _ request: NativeRequest<NativeFunctionRequest<Result, repeat each Argument>>,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) async throws -> NativeFunction<Result, repeat each Argument> {
        try await NativePreparation.run {
            try self.resolveAndWait(request, in: image, loading: loading)
        }
    }
}
