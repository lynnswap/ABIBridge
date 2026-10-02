// Inspect the demangled declaration role, not an arbitrary raw suffix or the
// current code address. For example, an ordinary Float parameter followed by
// the function marker ends in `fF`, also used by property init accessors.
private func validateImportedSwiftMember(_ selection: ImportedFunctionSelection, consumesArguments: Bool) throws {
    for reference in selection.references {
        let name = reference.symbol
        guard let declaration = DeclarationKey.demangle(name, language: .swift) else {
            throw ABIResolutionError.metadataUnavailable("The imported Swift member has no decoded declaration.")
        }
        let isSetter: Bool
        let isOrdinary: Bool
        if let separator = declaration.range(of: " : ") {
            let accessor = declaration[..<separator.lowerBound]
            isSetter = accessor.hasSuffix(".setter") && name.hasSuffix("s")
            isOrdinary = isSetter || (accessor.hasSuffix(".getter") && name.hasSuffix("g"))
        } else {
            isSetter = false
            isOrdinary = declaration.contains(" -> ") && name.hasSuffix("F")
        }
        guard isOrdinary else {
            throw ABIResolutionError.unsupportedDeclaration("Swift member hooks require ordinary instance methods or getters/setters, not lifecycle or coroutine imports.")
        }
        if isSetter && !consumesArguments {
            throw ABIResolutionError.unsupportedDeclaration("Resolve a Swift setter through setter(named:as:) to establish its consumed argument ownership.")
        }
    }
}

extension NativeSwiftMethod {
    // Swift 6.3 mismanages async task allocations when a same-type requirement
    // decomposes Signature into a parameter pack. Transparent entry thunks keep
    // that requirement out of the implementation frame, including in Debug builds.

    /// Intercepts importing references to this concrete Swift instance member.
    ///
    /// The callback receives scoped access to the actual incoming receiver.
    /// Import selection, chaining, failure recovery and process-lived code follow
    /// the Swift imported-function hook contract. These imports are independent
    /// of metadata dispatch unless both operations select the same pointer slot.
    /// Value receivers use the representation selected during type lookup.
    /// Mutating methods keep the caller's receiver address; consuming methods
    /// receive independent owned receiver storage for each continuation.
    /// Lifecycle/coroutine entries and unestablished layouts require separate support.
    /// - Parameters:
    ///   - importer: Loaded images containing references to the implementation.
    ///   - provider: Optional recorded-dependency filter, including reexports.
    ///   - runtime: Runtime whose import indexes are reused.
    ///   - owner: Additional lifetime owner for generated predecessor code.
    ///   - onFailure: Thread-safe observer of callback/conversion errors.
    ///   - body: Synchronous callback with an initialized receiver and typed arguments.
    /// - Throws: Selection/preparation errors or `NativeSwiftHookInstallationError`
    ///   retaining partial publication and rollback outcomes.
    @_transparent
    @unsafe public nonisolated(nonsending) func hookImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector, from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook where Signature == (repeat each Argument) throws(Failure) -> Result {
        try await _hookImportedCalls(in: importer, from: provider, using: runtime, retaining: owner, onFailure: onFailure, body: body)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func hookImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector, from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try await _hookImportedCalls(in: importer, from: provider, using: runtime, retaining: owner, onFailure: onFailure, body: body)
    }

    /// Installs an imported-member callback for a caller-supplied MainActor method contract.
    ///
    /// Background entry reports `wrongThread` and bypasses this callback before
    /// argument or receiver decoding. The callback stays synchronous and the
    /// failure observer must be thread-safe. Other rules match `hookImportedCalls`.
    @_transparent
    @unsafe @MainActor public func hookMainActorImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector, from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @MainActor @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook where Signature == (repeat each Argument) throws(Failure) -> Result {
        try await _hookMainActorImportedCalls(in: importer, from: provider, using: runtime, retaining: owner, onFailure: onFailure, body: body)
    }

    @_transparent
    @unsafe @MainActor public func hookMainActorImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector, from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @MainActor @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try await _hookMainActorImportedCalls(in: importer, from: provider, using: runtime, retaining: owner, onFailure: onFailure, body: body)
    }

    private nonisolated(nonsending) func installImportedMethodHook(
        in importer: ImageSelector, from provider: ImageSelector?, using runtime: ABIRuntime,
        retaining owner: (any Sendable)?, prepared: (signature: SwiftHookSignature, handler: SwiftHookHandler)
    ) async throws -> NativeSwiftImportedFunctionHook {
        let selection = try await runtime.swiftHookSelection(declaration: symbol.declaration, importer: importer, provider: provider)
        try validateImportedSwiftMember(selection, consumesArguments: consumesArguments)
        return try await SwiftHookRegistry.shared.register(selection: selection, signature: prepared.signature,
            handler: prepared.handler, codeOwner: owner)
    }

    @usableFromInline nonisolated(nonsending) func _hookImportedCalls<Result, each Argument>(
        in importer: ImageSelector, from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook {
        let prepared = try prepareHook(requiresMainActor: false, onFailure: onFailure, body: body)
        return try await installImportedMethodHook(in: importer, from: provider, using: runtime, retaining: owner, prepared: prepared)
    }

    @usableFromInline @MainActor func _hookMainActorImportedCalls<Result, each Argument>(
        in importer: ImageSelector, from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @MainActor @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook {
        let prepared = try prepareHook(requiresMainActor: true, onFailure: onFailure) {
                (call: NativeSwiftMethodInvocation<Result, repeat each Argument>, values: repeat each Argument) in
                let input = ObjCReplacementIsolatedValue(value: (call, (repeat each values)))
                return try MainActor.assumeIsolated {
                    ObjCReplacementIsolatedValue(value: try body(input.value.0, repeat each input.value.1))
                }.value
            }
        return try await installImportedMethodHook(in: importer, from: provider, using: runtime, retaining: owner, prepared: prepared)
    }

}
