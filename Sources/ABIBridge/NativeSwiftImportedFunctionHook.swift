import Foundation

private func prepareSwiftImportedHandler<Result, each Argument>(
    declaration: NativeDeclaration,
    prepared: SwiftHookCallbackSignature<Result, repeat each Argument>,
    requiresMainActor: Bool,
    onFailure: @escaping @Sendable (any Error) -> Void,
    body: @escaping @Sendable (NativeSwiftFunctionInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
) -> SwiftHookHandler {
    let description = hookDescription(declaration: declaration,
        signature: ((repeat each Argument) -> Result).self, unnamed: "<Swift function>")
    return SwiftHookHandler(requiresMainActor: requiresMainActor, failure: onFailure) { frame, storage in
        let values = try prepared.decodeArguments(storage)
        let call = NativeSwiftFunctionInvocation(frame: frame, prepared: prepared,
            declaration: declaration, description: description)
        return try prepared.result.encode(body(call, repeat each values))
    }
}

extension ABIRuntime {
    func swiftHookSelection(declaration: NativeDeclaration, importer: ImageSelector,
                            provider: ImageSelector?) throws -> ImportedFunctionSelection {
        try ImportedFunctionSelection(resolver: resolver, declaration: declaration,
            importer: importer, provider: provider, language: .swift)
    }
}

extension NativeSwiftFunction {
    /// Intercepts this concrete Swift function through imports in loaded callers.
    ///
    /// The capturing closure receives typed arguments and a scoped `proceed`
    /// continuation. It can edit arguments, call the captured predecessor chain,
    /// and transform the result. Callbacks run synchronously on the incoming
    /// thread. If a callback throws before proceeding, its incoming arguments
    /// continue to the next implementation. After proceeding, a thrown error
    /// preserves the latest completed result without repeating native effects.
    /// `onFailure` receives the original callback or conversion error.
    ///
    /// Later registrations wrap earlier callbacks. Invalidation releases captures
    /// after in-flight snapshots finish, while published pass-through code and
    /// importing/provider image leases remain process-lived. Direct, inlined,
    /// specialized, and copied-pointer calls that bypass the imports are unaffected.
    ///
    /// The declared Swift ABI, ownership and isolation must match the native entry.
    /// Source names and metatypes do not establish those contracts. Unresolved
    /// lazy references must first be called normally; protected pages can reject
    /// publication. No images are loaded by import selection.
    /// - Parameters:
    ///   - importer: Loaded images containing the references to change.
    ///   - provider: Optional filter on the recorded dependency, including reexports.
    ///   - runtime: Runtime whose import indexes are reused.
    ///   - owner: Additional lifetime owner for generated predecessor code outside
    ///     loader images. Published code can keep this owner for process lifetime.
    ///   - onFailure: A thread-safe observer of callback and conversion failures.
    ///   - body: A synchronous callback with explicit Swift arguments and result.
    /// - Returns: A registration whose captures can be independently invalidated.
    /// - Throws: Selection/preparation errors or `NativeSwiftHookInstallationError`
    ///   containing partial publication and rollback outcomes.
    @unsafe public nonisolated(nonsending) func hookImportedCalls(
        in importer: ImageSelector, from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeSwiftFunctionInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook {
        try await installImportedHook(in: importer, from: provider, using: runtime, retaining: owner,
            requiresMainActor: false, onFailure: onFailure, body: body)
    }

    /// Intercepts imports whose native callers are required to enter on MainActor.
    ///
    /// This is a caller-supplied isolation contract, not an executor hop. Background
    /// entry reports `wrongThread` and bypasses this callback before decoding its
    /// Swift arguments. `onFailure` must also be safe on background threads.
    /// Import selection, failure recovery and lifetime match `hookImportedCalls`.
    @unsafe @MainActor public func hookMainActorImportedCalls(
        in importer: ImageSelector, from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @MainActor @Sendable (NativeSwiftFunctionInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook {
        try await installImportedHook(in: importer, from: provider, using: runtime, retaining: owner,
            requiresMainActor: true, onFailure: onFailure) {
                (call: NativeSwiftFunctionInvocation<Result, repeat each Argument>, values: repeat each Argument) in
                let input = ObjCReplacementIsolatedValue(value: (call, (repeat each values)))
                return try MainActor.assumeIsolated {
                    ObjCReplacementIsolatedValue(value: try body(input.value.0, repeat each input.value.1))
                }.value
            }
    }

    private nonisolated(nonsending) func installImportedHook(
        in importer: ImageSelector, from provider: ImageSelector?, using runtime: ABIRuntime,
        retaining owner: (any Sendable)?, requiresMainActor: Bool,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeSwiftFunctionInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook {
        guard errorPlan == nil else {
            throw ABIResolutionError.unsupportedDeclaration("Managed hooks cannot yet return native Swift errors.")
        }
        let prepared = try SwiftHookCallbackSignature<Result, repeat each Argument>()
        let signature = try prepared.erased(consumingArguments: consumesArguments, retaining: self)
        let handler = prepareSwiftImportedHandler(declaration: symbol.declaration, prepared: prepared,
            requiresMainActor: requiresMainActor, onFailure: onFailure, body: body)
        let selection = try await runtime.swiftHookSelection(declaration: symbol.declaration,
            importer: importer, provider: provider)
        return try await SwiftHookRegistry.shared.register(selection: selection, signature: signature,
            handler: handler, codeOwner: owner)
    }
}
