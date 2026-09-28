/// A concrete native Swift async function with a retained implementation.
///
/// Invocation runs on the caller's Swift task, preserving cancellation and
/// task-local state. The native declaration controls suspension and executor
/// changes; the bridge resumes its Swift caller on the original executor.
/// Native failures use NativeSwiftError, while bridge failures keep their types.
public struct NativeSwiftAsyncFunction<Result, each Argument>: Sendable {
    /// The selected declaration and retained implementation image.
    public var symbol: ResolvedSymbol { implementation.symbol }

    private let implementation: SwiftAsyncImplementation
    private let call: SwiftAsyncCall<Result, repeat each Argument>
    private let context: UInt
    private let owner: NativeSwiftType?

    init(symbol: ResolvedSymbol, resolver: SymbolResolver, errorPlan: SwiftErrorPlan?,
         inheritsCallerIsolation: Bool, metadata: Any.Type? = nil, owner: NativeSwiftType? = nil,
         consumesArguments: Bool = false) throws {
        implementation = try SwiftAsyncImplementation(symbol: symbol, resolver: resolver)
        call = try SwiftAsyncCall(consumesArguments: consumesArguments, errorPlan: errorPlan,
                                   inheritsCallerIsolation: inheritsCallerIsolation)
        context = metadata.map { unsafeBitCast($0, to: UInt.self) } ?? 0
        self.owner = owner
    }

    static func declaration<Failure: Error>(
        named name: String, failure: Failure.Type, resultName: String? = nil, defaultConsuming: Bool = false
    ) throws -> NativeDeclaration {
        var types: [Any.Type] = []
        for type in repeat (each Argument).self { types.append(type) }
        return try swiftFunctionDeclaration(named: name, parameterTypes: types, resultType: Result.self,
            failureType: Failure.self, isAsync: true, resultName: resultName, defaultConsuming: defaultConsuming)
    }

    /// Awaits the native implementation without creating a replacement task.
    ///
    /// The function metatype must match the native argument, result, error, and
    /// caller-isolation convention. Actor/thread and ownership requirements
    /// remain the caller's responsibility. Storage and code stay alive across
    /// suspension. Cancellation is cooperative and does not free an active call.
    ///
    /// - Parameter values: Explicit arguments in declaration order.
    /// - Returns: The native result with its Swift ownership.
    /// - Throws: A NativeSwiftError or a lookup/conversion/preparation error.
    @unsafe public nonisolated(nonsending) func unsafeInvoke(_ values: repeat each Argument) async throws -> Result {
        try unsafe await call.unsafeInvoke(implementation: implementation,
            context: UnsafeRawPointer(bitPattern: context), retaining: (implementation, owner),
            retainingCode: owner?.image, repeat each values)
    }
}

// Swift 6.3 distinguishes the function metatypes but not overload declarations
// differing only in this annotation. The explicit convention override also
// permits caller-shaped metatypes for actor entries without the hidden payload.
extension ABIRuntime {
    /// Resolves an async declaration using the caller-isolated Swift convention.
    ///
    /// Use a nonisolated(nonsending) function metatype for that convention.
    /// Plain async function types select it when NonisolatedNonsendingByDefault
    /// is enabled. Symbols do not encode this hidden argument convention.
    public func swiftFunction<Result, Failure: Error, each Argument>(
        named name: String,
        as signature: (nonisolated(nonsending) (repeat each Argument) async throws(Failure) -> Result).Type,
        inheritsCallerIsolation: Bool = true,
        in scope: ImageSelector = .automatic, loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftAsyncFunction<Result, repeat each Argument> {
        let errorPlan = try SwiftErrorPlan.make(Failure.self)
        let declaration = try NativeSwiftAsyncFunction<Result, repeat each Argument>.declaration(named: name, failure: Failure.self)
        return try NativeSwiftAsyncFunction(symbol: resolve(declaration, in: scope, loading: loading),
            resolver: resolver, errorPlan: errorPlan, inheritsCallerIsolation: inheritsCallerIsolation)
    }

    /// Resolves an async declaration without a hidden caller-isolation argument.
    ///
    /// A concurrent metatype selects this native ABI. This also describes the
    /// physical arguments/results of actor-isolated entries; the metatype does
    /// not establish that the caller satisfies their isolation requirements.
    public func swiftFunction<Result, Failure: Error, each Argument>(
        named name: String,
        as signature: (@concurrent (repeat each Argument) async throws(Failure) -> Result).Type,
        in scope: ImageSelector = .automatic, loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftAsyncFunction<Result, repeat each Argument> {
        let errorPlan = try SwiftErrorPlan.make(Failure.self)
        let declaration = try NativeSwiftAsyncFunction<Result, repeat each Argument>.declaration(named: name, failure: Failure.self)
        return try NativeSwiftAsyncFunction(symbol: resolve(declaration, in: scope, loading: loading),
            resolver: resolver, errorPlan: errorPlan, inheritsCallerIsolation: false)
    }

    /// Resolves a caller-isolated async implementation in an already retained image.
    public func swiftFunction<Result, Failure: Error, each Argument>(
        named name: String,
        as signature: (nonisolated(nonsending) (repeat each Argument) async throws(Failure) -> Result).Type,
        inheritsCallerIsolation: Bool = true,
        in image: NativeImage, loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftAsyncFunction<Result, repeat each Argument> {
        let errorPlan = try SwiftErrorPlan.make(Failure.self)
        let declaration = try NativeSwiftAsyncFunction<Result, repeat each Argument>.declaration(named: name, failure: Failure.self)
        return try NativeSwiftAsyncFunction(symbol: resolve(declaration, in: image, loading: loading),
            resolver: resolver, errorPlan: errorPlan, inheritsCallerIsolation: inheritsCallerIsolation)
    }

    /// Resolves an async implementation without a caller-isolation prefix in a retained image.
    public func swiftFunction<Result, Failure: Error, each Argument>(
        named name: String,
        as signature: (@concurrent (repeat each Argument) async throws(Failure) -> Result).Type,
        in image: NativeImage, loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftAsyncFunction<Result, repeat each Argument> {
        let errorPlan = try SwiftErrorPlan.make(Failure.self)
        let declaration = try NativeSwiftAsyncFunction<Result, repeat each Argument>.declaration(named: name, failure: Failure.self)
        return try NativeSwiftAsyncFunction(symbol: resolve(declaration, in: image, loading: loading),
            resolver: resolver, errorPlan: errorPlan, inheritsCallerIsolation: false)
    }
}
