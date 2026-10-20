import Foundation

private func prepareSwiftImportedHandler<Signature, Result, each Argument>(
    declaration: NativeDeclaration,
    prepared: SwiftHookCallbackSignature<Result, repeat each Argument>,
    requiresMainActor: Bool,
    onFailure: @escaping @Sendable (any Error) -> Void,
    body:
        @escaping @Sendable (NativeSwiftFunctionInvocation<Signature>, repeat each Argument) throws
        -> Result
) -> SwiftHookHandler {
    let description = hookDescription(
        declaration: declaration,
        signature: Signature.self,
        unnamed: "<Swift function>"
    )
    return SwiftHookHandler(requiresMainActor: requiresMainActor, failure: onFailure) {
        frame,
        storage in
        let call = NativeSwiftFunctionInvocation<Signature>(
            frame: frame,
            prepared: prepared.values,
            declaration: declaration,
            description: description
        )
        return try prepared.invoke(storage, recovery: frame.recovery) {
            (values: repeat each Argument) in
            try body(call, repeat each values)
        }
    }
}

extension ABIRuntime {
    nonisolated func swiftHookSelection(
        declaration: NativeDeclaration,
        importer: ImageSelector,
        provider: ImageSelector?
    ) async throws -> ImportedFunctionSelection {
        try await NativePreparation.run {
            try ImportedFunctionSelection(
                resolver: self.resolver,
                declaration: declaration,
                importer: importer,
                provider: provider,
                language: .swift
            )
        }
    }
}

extension NativeSwiftFunction {
    // Swift 6.3 mismanages async task allocations when a same-type requirement
    // decomposes Signature into a parameter pack. Transparent entry thunks keep
    // that requirement out of the implementation frame, including in Debug builds.

    /// Intercepts this concrete Swift function through imports in loaded callers.
    ///
    /// Callbacks run synchronously on the incoming thread. Errors accepted by the native error type return through that channel, including every error for `throws(any Error)`. Other errors reach `onFailure`: before proceeding, unchanged arguments continue to the next implementation; afterward, the latest completed result or native error is preserved without repeating native effects.
    ///
    /// Later registrations wrap earlier callbacks. Invalidation releases captures after in-flight calls finish. Published pass-through code and importing/provider image leases remain retained for process lifetime. Direct, inlined, specialized, and copied-pointer calls bypassing the imports are unaffected.
    ///
    /// The Swift ABI, ownership, and isolation must match the native entry; source names and metatypes do not establish them. Call unresolved lazy references normally before hooking them. Protected pages can reject publication, and import selection does not load images. See <doc:SwiftFunctionHooks> for chaining and failure handling.
    ///
    /// - Parameters:
    ///   - importer: Loaded images containing the references to change.
    ///   - provider: Optional filter on the recorded dependency, including reexports.
    ///   - runtime: Runtime whose import indexes are reused.
    ///   - owner: Keeps generated predecessor code outside loader images alive. Published code can retain this owner for process lifetime.
    ///   - onFailure: A thread-safe observer of callback and conversion failures.
    ///   - body: A synchronous callback with typed arguments and a scoped `proceed` continuation; it may replace arguments and transform results.
    /// - Returns: A registration whose captures can be independently invalidated.
    /// - Throws: Selection or preparation errors, or `NativeSwiftHookInstallationError` containing partial publication and rollback outcomes.
    @_transparent
    @unsafe
    public nonisolated(nonsending) func hookImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @Sendable (NativeSwiftFunctionInvocation<Signature>, repeat each Argument)
            throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook
    where Signature == (repeat each Argument) throws(Failure) -> Result {
        try await _hookImportedCalls(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            onFailure: onFailure,
            body: body
        )
    }

    @_transparent
    @unsafe
    public nonisolated(nonsending) func hookImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @Sendable (NativeSwiftFunctionInvocation<Signature>, repeat each Argument)
            throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try await _hookImportedCalls(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            onFailure: onFailure,
            body: body
        )
    }

    /// Intercepts imports whose native callers are required to enter on MainActor.
    ///
    /// This is a caller-supplied isolation contract, not an executor hop. Background entry reports `wrongThread` and bypasses this callback before decoding its Swift arguments. `onFailure` must also be safe on background threads. Import selection, failure recovery and lifetime match `hookImportedCalls`.
    @_transparent
    @unsafe @MainActor
    public func hookMainActorImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @MainActor @Sendable (
                NativeSwiftFunctionInvocation<Signature>, repeat each Argument
            ) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook
    where Signature == (repeat each Argument) throws(Failure) -> Result {
        try await _hookMainActorImportedCalls(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            onFailure: onFailure,
            body: body
        )
    }

    @_transparent
    @unsafe @MainActor
    public func hookMainActorImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @MainActor @Sendable (
                NativeSwiftFunctionInvocation<Signature>, repeat each Argument
            ) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try await _hookMainActorImportedCalls(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            onFailure: onFailure,
            body: body
        )
    }

    private func prepareHook<Result, each Argument>(
        requiresMainActor: Bool,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @Sendable (NativeSwiftFunctionInvocation<Signature>, repeat each Argument)
            throws -> Result
    ) async throws -> (signature: SwiftHookSignature, handler: SwiftHookHandler) {
        try await NativePreparation.run { [self] in
            guard case .synchronous(let call) = call else {
                preconditionFailure("A synchronous hook has a synchronous callable plan.")
            }
            let prepared = try SwiftHookCallbackSignature<Result, repeat each Argument>(call: call)
            let signature = try prepared.erased(
                consumingArguments: consumesArguments,
                errorPlan: errorPlan,
                retaining: self
            )
            let handler = prepareSwiftImportedHandler(
                declaration: self.declaration,
                prepared: prepared,
                requiresMainActor: requiresMainActor,
                onFailure: onFailure,
                body: body
            )
            return (signature, handler)

        }
    }

    private nonisolated(nonsending) func installImportedHook(
        in importer: ImageSelector,
        from provider: ImageSelector?,
        using runtime: ABIRuntime,
        retaining owner: (any Sendable)?,
        prepared: (signature: SwiftHookSignature, handler: SwiftHookHandler)
    ) async throws -> NativeSwiftImportedFunctionHook {
        let selection = try await runtime.swiftHookSelection(
            declaration: self.declaration,
            importer: importer,
            provider: provider
        )
        return try await SwiftHookRegistry.shared.register(
            selection: selection,
            signature: prepared.signature,
            handler: prepared.handler,
            codeOwner: owner
        )
    }

    @usableFromInline nonisolated(nonsending) func _hookImportedCalls<Result, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @Sendable (NativeSwiftFunctionInvocation<Signature>, repeat each Argument)
            throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook {
        let prepared = try await prepareHook(
            requiresMainActor: false,
            onFailure: onFailure,
            body: body
        )
        return try await installImportedHook(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            prepared: prepared
        )
    }

    @usableFromInline @MainActor func _hookMainActorImportedCalls<Result, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @MainActor @Sendable (
                NativeSwiftFunctionInvocation<Signature>, repeat each Argument
            ) throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook {
        let prepared = try await prepareHook(requiresMainActor: true, onFailure: onFailure) {
            (call: NativeSwiftFunctionInvocation<Signature>, values: repeat each Argument) in
            let input = ObjCReplacementIsolatedValue(value: (call, (repeat each values)))
            return try MainActor.assumeIsolated {
                ObjCReplacementIsolatedValue(
                    value: try body(input.value.0, repeat each input.value.1)
                )
            }.value
        }
        return try await installImportedHook(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            prepared: prepared
        )
    }

}

extension NativeSwiftFunction {
    /// Intercepts an asynchronous entry on the incoming Swift task. The callback and `proceed` may suspend; cancellation and task-local values follow that task. Invalidation leaves entered snapshots alive until return. Unrepresentable failures preserve the latest native outcome, or continue with unchanged arguments when no predecessor has completed.
    @_transparent
    @unsafe
    public nonisolated(nonsending) func hookImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @Sendable (NativeSwiftFunctionInvocation<Signature>, repeat each Argument)
            async throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook
    where Signature == (repeat each Argument) async throws(Failure) -> Result {
        try await _hookImportedCalls(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            onFailure: onFailure,
            body: body
        )
    }

    @_transparent
    @unsafe
    public nonisolated(nonsending) func hookImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @Sendable (NativeSwiftFunctionInvocation<Signature>, repeat each Argument)
            async throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook
    where Signature == @Sendable (repeat each Argument) async throws(Failure) -> Result {
        try await _hookImportedCalls(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            onFailure: onFailure,
            body: body
        )
    }

    @_transparent
    @unsafe
    public nonisolated(nonsending) func hookImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @Sendable (NativeSwiftFunctionInvocation<Signature>, repeat each Argument)
            async throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook
    where Signature == @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try await _hookImportedCalls(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            onFailure: onFailure,
            body: body
        )
    }

    @_transparent
    @unsafe
    public nonisolated(nonsending) func hookImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @Sendable (NativeSwiftFunctionInvocation<Signature>, repeat each Argument)
            async throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook
    where Signature == @Sendable @concurrent (repeat each Argument) async throws(Failure) -> Result
    {
        try await _hookImportedCalls(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            onFailure: onFailure,
            body: body
        )
    }

    @usableFromInline nonisolated(nonsending) func _hookImportedCalls<Result, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @Sendable (NativeSwiftFunctionInvocation<Signature>, repeat each Argument)
            async throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook {
        let prepared = try await prepareAsyncHook(requiresMainActor: false, onFailure: onFailure) {
            (call: NativeSwiftFunctionInvocation<Signature>, values: repeat each Argument) in
            try await body(call, repeat each values)
        }
        return try await installImportedHook(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            prepared: prepared
        )
    }

    @_transparent
    @unsafe @MainActor
    public func hookMainActorImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @MainActor @Sendable (
                NativeSwiftFunctionInvocation<Signature>, repeat each Argument
            ) async throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook
    where Signature == (repeat each Argument) async throws(Failure) -> Result {
        try await _hookMainActorImportedCalls(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            onFailure: onFailure,
            body: body
        )
    }

    @_transparent
    @unsafe @MainActor
    public func hookMainActorImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @MainActor @Sendable (
                NativeSwiftFunctionInvocation<Signature>, repeat each Argument
            ) async throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook
    where Signature == @Sendable (repeat each Argument) async throws(Failure) -> Result {
        try await _hookMainActorImportedCalls(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            onFailure: onFailure,
            body: body
        )
    }

    @_transparent
    @unsafe @MainActor
    public func hookMainActorImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @MainActor @Sendable (
                NativeSwiftFunctionInvocation<Signature>, repeat each Argument
            ) async throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook
    where Signature == @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try await _hookMainActorImportedCalls(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            onFailure: onFailure,
            body: body
        )
    }

    @_transparent
    @unsafe @MainActor
    public func hookMainActorImportedCalls<Result, Failure: Error, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @MainActor @Sendable (
                NativeSwiftFunctionInvocation<Signature>, repeat each Argument
            ) async throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook
    where Signature == @Sendable @concurrent (repeat each Argument) async throws(Failure) -> Result
    {
        try await _hookMainActorImportedCalls(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            onFailure: onFailure,
            body: body
        )
    }

    @usableFromInline @MainActor func _hookMainActorImportedCalls<Result, each Argument>(
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        using runtime: ABIRuntime = .shared,
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @MainActor @Sendable (
                NativeSwiftFunctionInvocation<Signature>, repeat each Argument
            ) async throws -> Result
    ) async throws -> NativeSwiftImportedFunctionHook {
        let prepared = try await prepareAsyncHook(requiresMainActor: true, onFailure: onFailure) {
            (call: NativeSwiftFunctionInvocation<Signature>, values: repeat each Argument) in
            let input = ObjCReplacementIsolatedValue(value: (call, (repeat each values)))
            let invoke:
                @MainActor @Sendable () async throws -> ObjCReplacementIsolatedValue<Result> = {
                    ObjCReplacementIsolatedValue(
                        value: try await body(input.value.0, repeat each input.value.1)
                    )
                }
            return try await invoke().value
        }
        return try await installImportedHook(
            in: importer,
            from: provider,
            using: runtime,
            retaining: owner,
            prepared: prepared
        )
    }

}

extension NativeSwiftFunction {
    private func prepareAsyncHook<Result, each Argument>(
        requiresMainActor: Bool,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body:
            @escaping @Sendable (NativeSwiftFunctionInvocation<Signature>, repeat each Argument)
            async throws -> Result
    ) async throws -> (signature: SwiftHookSignature, handler: SwiftHookHandler) {
        try await NativePreparation.run { [self] in
            guard case .asynchronous(let call, let implementation) = call else {
                preconditionFailure("An async hook has an async callable plan.")
            }
            let prepared = try SwiftHookCallbackSignature<Result, repeat each Argument>(
                call: call,
                contextSize: implementation.entry.contextSize
            )
            let signature = try prepared.erased(
                consumingArguments: consumesArguments,
                errorPlan: errorPlan,
                retaining: self
            )
            let declaration = self.declaration
            let description = hookDescription(
                declaration: declaration,
                signature: Signature.self,
                unnamed: "<Swift function>"
            )
            let handler = SwiftHookHandler(
                requiresMainActor: requiresMainActor,
                failure: onFailure,
                invokeAsync: { frame, storage in
                    let invocation = NativeSwiftFunctionInvocation<Signature>(
                        frame: frame,
                        prepared: prepared.values,
                        declaration: declaration,
                        description: description
                    )
                    return try await prepared.invokeAsync(
                        storage,
                        recovery: frame.recovery,
                        invocation: invocation,
                        body: body
                    )
                }
            )
            return (signature, handler)

        }
    }
}
