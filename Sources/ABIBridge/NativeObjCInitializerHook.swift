import Foundation

extension ABIRuntime {
    /// Observes one consuming Objective-C initialization with typed arguments and result.
    ///
    /// `before` receives the original arguments, then `transformingArguments` may replace them. The bridge initializes once and passes the actual object or nil to `after`. Callbacks receive neither uninitialized self nor a continuation.
    ///
    /// Later registrations wrap earlier ones. A failure before continuation bypasses this hook with its original arguments. A result-conversion or `after` failure preserves the initialized native result. `onFailure` runs synchronously on the caller's thread.
    ///
    /// For explicit `ns_consumed` arguments, set ``NativeObjCMethodOptions/consumedArguments`` to their zero-based positions, excluding the receiver and selector. The bridge owns incoming references and transfers independent references for final initialization, including transformed arguments.
    ///
    /// Honor declaration ownership, pointer and block lifetimes, execution isolation, and external-writer coordination. Foreign exceptions, cancellation, replacement construction, and repeated initialization are unsupported. See <doc:ObjectiveCInitializerHooks>.
    ///
    /// - Parameters:
    ///   - type: The class whose concrete instance initializer is intercepted.
    ///   - selector: The initializer selector, including argument colons.
    ///   - signature: Explicit arguments and the initialized-result type. Use an optional result when initialization may return nil.
    ///   - options: Overrides for a nonstandard declaration with consumed self and a retained object result. Nil values infer method families; `consumedArguments` identifies explicit `ns_consumed` parameters.
    ///   - owner: Keeps generated original code or a dynamic class alive when the method's process-lived dispatcher is first created.
    ///   - onFailure: Handles callback and conversion errors without unwinding into native code.
    ///   - transformingArguments: Returns the explicit argument tuple, a single value for one argument, or `()` for no arguments. Defaults to unchanged values.
    ///   - before: Runs before transformation and initialization. Defaults to no action.
    ///   - after: Processes the actual initialized result. Defaults to no action.
    /// - Returns: A registration removed by token invalidation or destruction.
    /// - Throws: A lookup, signature, ownership, preparation, or displacement error.
    @unsafe public nonisolated func hookInitializer<Result, each Argument>(
        on type: AnyClass, selector: String, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeObjCMethodOptions = .init(),
        retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        transformingArguments: (@Sendable (repeat each Argument) throws -> (repeat each Argument))? = nil,
        before: (@Sendable (repeat each Argument) throws -> Void)? = nil,
        after: @escaping @Sendable (Result) throws -> Void = { _ in }
    ) throws -> NativeObjCMethodHook {
        try NativeObjCMethodHook.prepare(on: type, selector: selector, as: signature,
            classMethod: false, options: options, object: nil, owner: owner, initializer: true) { signature in
                ObjCReplacement<Result, repeat each Argument>.initializerCallback(signature,
                    requiresMainThread: false, onFailure: onFailure,
                    transformingArguments: transformingArguments, before: before, after: after)
            }
    }

    /// Observes an initializer whose native callers must run on MainActor.
    ///
    /// The argument and result callbacks run synchronously on MainActor without an executor hop. Background entry reports `wrongThread` and bypasses the hook before decoding arguments; `onFailure` must be safe on background threads. Other parameters and unsafe requirements match ``hookInitializer(on:selector:as:options:retaining:onFailure:transformingArguments:before:after:)-(_,String,_,_,_,_,_,_,_)``.
    @unsafe @MainActor public func hookMainActorInitializer<Result, each Argument>(
        on type: AnyClass, selector: String, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeObjCMethodOptions = .init(),
        retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        transformingArguments: (@MainActor @Sendable (repeat each Argument) throws -> (repeat each Argument))? = nil,
        before: (@MainActor @Sendable (repeat each Argument) throws -> Void)? = nil,
        after: @escaping @MainActor @Sendable (Result) throws -> Void = { _ in }
    ) throws -> NativeObjCMethodHook {
        try NativeObjCMethodHook.prepare(on: type, selector: selector, as: signature,
            classMethod: false, options: options, object: nil, owner: owner, initializer: true) { signature in
                ObjCReplacement<Result, repeat each Argument>.mainActorInitializerCallback(signature,
                    onFailure: onFailure, transformingArguments: transformingArguments, before: before, after: after)
            }
    }
}
