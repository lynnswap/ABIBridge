// ABI Mangling.rst identifies direct member and lifecycle roles. Inspect each
// binding, not a current code address: optimized methods and constructors can
// share implementations, and escaped ordinary methods can be named `init`.
private func validateImportedSwiftMember(_ selection: ImportedFunctionSelection, consumesArguments: Bool) throws {
    let lifecycle = ["fC", "fc", "fD", "fZ", "fd", "fe", "fE", "fP", "fF", "fW"]
    for reference in selection.references {
        let name = reference.symbol
        guard !lifecycle.contains(where: name.hasSuffix),
              name.hasSuffix("F") || name.hasSuffix("g") || name.hasSuffix("s") else {
            throw ABIResolutionError.unsupportedDeclaration("Swift member hooks require ordinary instance methods or getters/setters, not lifecycle or coroutine imports.")
        }
        if name.hasSuffix("s") && !consumesArguments {
            throw ABIResolutionError.unsupportedDeclaration("Resolve a Swift setter through setter(named:as:) to establish its consumed argument ownership.")
        }
    }
}

extension NativeSwiftMethod {
    /// Intercepts importing references to this ordinary Swift class member.
    ///
    /// The callback receives scoped access to the actual incoming receiver.
    /// Import selection, chaining, failure recovery and process-lived code follow
    /// the Swift imported-function hook contract. These imports are independent
    /// of metadata dispatch unless both operations select the same pointer slot.
    /// Value receivers and lifecycle/coroutine entries require separate support.
    /// - Parameters:
    ///   - importer: Loaded images containing references to the implementation.
    ///   - provider: Optional recorded-dependency filter, including reexports.
    ///   - runtime: Runtime whose import indexes are reused.
    ///   - owner: Additional lifetime owner for generated predecessor code.
    ///   - onFailure: Thread-safe observer of callback/conversion errors.
    ///   - body: Synchronous callback with an initialized receiver and typed arguments.
    /// - Throws: Selection/preparation errors or `NativeSwiftHookInstallationError`
    ///   retaining partial publication and rollback outcomes.
    @unsafe public nonisolated(nonsending) func hookImportedCalls(
        in importer: ImageSelector, from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook {
        try await installImportedMethodHook(in: importer, from: provider, using: runtime, retaining: owner,
            requiresMainActor: false, onFailure: onFailure, body: body)
    }

    /// Installs an imported-member callback for a caller-supplied MainActor method contract.
    ///
    /// Background entry reports `wrongThread` and bypasses this callback before
    /// argument or receiver decoding. The callback stays synchronous and the
    /// failure observer must be thread-safe. Other rules match `hookImportedCalls`.
    @unsafe @MainActor public func hookMainActorImportedCalls(
        in importer: ImageSelector, from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @MainActor @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook {
        try await installImportedMethodHook(in: importer, from: provider, using: runtime, retaining: owner,
            requiresMainActor: true, onFailure: onFailure) {
                (call: NativeSwiftMethodInvocation<Result, repeat each Argument>, values: repeat each Argument) in
                let input = ObjCReplacementIsolatedValue(value: (call, (repeat each values)))
                return try MainActor.assumeIsolated {
                    ObjCReplacementIsolatedValue(value: try body(input.value.0, repeat each input.value.1))
                }.value
            }
    }

    private nonisolated(nonsending) func installImportedMethodHook(
        in importer: ImageSelector, from provider: ImageSelector?, using runtime: ABIRuntime,
        retaining owner: (any Sendable)?, requiresMainActor: Bool,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook {
        let receiverView = try SwiftClassHookReceiver(self)
        let prepared = try SwiftHookCallbackSignature<Result, repeat each Argument>()
        let signature = try prepared.erased(consumingArguments: consumesArguments,
            classReceiver: receiver.isConsuming, retaining: self)
        let handler = prepareSwiftMethodHandler(method: self, prepared: prepared, receiver: receiverView,
            requiresMainActor: requiresMainActor, onFailure: onFailure, body: body)
        let selection = try await runtime.swiftHookSelection(declaration: symbol.declaration, importer: importer, provider: provider)
        try validateImportedSwiftMember(selection, consumesArguments: consumesArguments)
        return try await SwiftHookRegistry.shared.register(selection: selection, signature: signature,
            handler: handler, codeOwner: owner)
    }
}
