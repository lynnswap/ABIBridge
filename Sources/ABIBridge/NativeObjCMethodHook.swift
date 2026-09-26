import ABIBridgeObjCXX
import Foundation
import ObjectiveC

/// A failure in a managed Objective-C method hook.
public enum NativeObjCMethodHookError: Error, Sendable, Equatable {
    /// The invocation's callback has already returned.
    case expiredInvocation
    /// The continuation or MainActor callback was entered from the wrong thread.
    case wrongThread
    /// Another writer replaced the managed entry, or changed it during preparation.
    case displaced
    /// This method requires an initializer, allocation, or lifecycle-specific contract.
    case unsupportedMethod
    /// A registration disagrees with the existing entry's signature or ownership.
    case incompatibleContract
}

/// Owns one registration in an Objective-C method's managed hook chain.
///
/// Keep the token alive to keep its callback installed. Invalidation and token
/// destruction remove its behavior without waiting for in-flight snapshots.
/// Later registrations run outside earlier ones. Calls already in progress keep
/// their snapshot, including callbacks invalidated during that call.
///
/// One dispatcher per class/selector/method-kind and its fallback ownership remain
/// for the process lifetime so saved IMPs stay callable. Callback captures are
/// released independently. See <doc:ObjectiveCMethodHooks> for inheritance, weak
/// object scope, external writers, and dynamic class/code lifetime requirements.
public final class NativeObjCMethodHook: @unchecked Sendable {
    /// The registration's logical state and current method-table ownership.
    public enum Status: Sendable, Equatable {
        /// New calls entering the dispatcher can run this callback.
        case active
        /// The token's callback was logically removed.
        case invalidated
        /// Another writer replaced the method-table entry.
        ///
        /// Calls through saved dispatcher IMPs can still run active callbacks.
        case displaced
    }

    private let handle: OpaquePointer
    private init(_ handle: OpaquePointer) { self.handle = handle }

    /// A snapshot of the token state; inspection does not reinstall a displaced entry.
    public var status: Status {
        switch ABIObjCMethodHookStatus(handle) {
        case 0: .invalidated
        case 1: .active
        default: .displaced
        }
    }

    /// Removes this callback from future snapshots without blocking active calls.
    ///
    /// Idempotent and safe from a callback. Does not overwrite external IMPs or
    /// remove runtime method entries added for inherited methods.
    public func invalidate() { ABIInvalidateObjCMethodHook(handle) }
    deinit { ABIReleaseObjCMethodHook(handle) }

    static func install<Result, each Argument>(
        on type: AnyClass, selector: String, as: ((repeat each Argument) -> Result).Type,
        classMethod: Bool, options: NativeMethodOptions, object: AnyObject?, owner: Any?,
        requiresMainThread: Bool,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) throws -> NativeObjCMethodHook {
        guard !selector.utf8.contains(0) else {
            throw ABIResolutionError.unsupportedDeclaration("A selector cannot contain a NUL byte.")
        }
        var error: NSError?
        let sel = NSSelectorFromString(selector)
        guard let binding = ABICopyObjCImplementation(type, sel, classMethod,
            options.returnsRetainedObject.map { $0 ? 1 : 0 } ?? -1,
            options.consumesReceiver.map { $0 ? 1 : 0 } ?? -1, &error) else {
            throw error ?? ABIResolutionError.metadataUnavailable(selector) as NSError
        }
        defer { ABIReleaseObjCInvocation(binding) }
        let signature = try ObjCMethodSignature<Result, repeat each Argument>(handle: binding)
        let interface = try signature.callInterface()
        let context = Unmanaged.passRetained(ObjCReplacement<Result, repeat each Argument>.callback(
            signature, requiresMainThread: requiresMainThread, onFailure: onFailure, body: body))
        guard let handle = ABICreateObjCMethodHook(type, sel, classMethod, binding, interface.handle,
            { context, call in Unmanaged<ObjCReplacementCallback>.fromOpaque(context).takeUnretainedValue().body(call) },
            context.toOpaque(), { context in Unmanaged<ObjCReplacementCallback>.fromOpaque(context).release() },
            object, owner.map { $0 as AnyObject }, &error) else {
            // Native registration consumes context on success and failure.
            if let error, error.domain == ABIObjCMethodHookErrorDomain {
                switch error.code {
                case 1: throw NativeObjCMethodHookError.displaced
                case 2: throw NativeObjCMethodHookError.unsupportedMethod
                case 3: throw NativeObjCMethodHookError.incompatibleContract
                default: throw error
                }
            }
            throw error ?? ABIResolutionError.invalidAddress as NSError
        }
        return NativeObjCMethodHook(handle)
    }
}

extension ABIRuntime {
    /// Installs a typed hook on a concrete synchronous Objective-C method.
    ///
    /// The callback runs on each caller's thread. If it throws before proceeding,
    /// its original arguments continue to the next hook. If it throws after a
    /// completed continuation, that result is preserved without replaying it.
    /// Failures are synchronously delivered to `onFailure` on the caller's thread.
    ///
    /// - Parameters:
    ///   - type: The class whose instance or class method is intercepted.
    ///   - selector: The Objective-C selector, including argument colons.
    ///   - signature: A supported ordinary function type with explicit arguments only.
    ///   - classMethod: Whether to intercept the metaclass method.
    ///   - options: Ownership annotations missing from runtime encodings.
    ///   - owner: Lifetime owner for generated original code or a dynamic class when
    ///     this method's dispatcher is first created. Later registrations reuse it.
    ///   - onFailure: Handles Swift callback and value-conversion failures.
    ///   - body: Produces a result, optionally invoking the scoped next implementation.
    /// - Returns: A token that keeps this registration active until invalidated or released.
    /// - Throws: A lookup, signature, ownership, preparation, or displaced-entry error.
    ///
    /// The caller supplies correct ownership/block declarations, keeps pointer
    /// pointees valid, honors execution isolation, and coordinates installation
    /// with external method-table writers. Consumed explicit arguments, foreign
    /// exceptions, initializers, allocation, and lifecycle methods are unsupported.
    @unsafe public nonisolated func hookMethod<Result, each Argument>(
        on type: AnyClass, selector: String, as signature: ((repeat each Argument) -> Result).Type,
        classMethod: Bool = false, options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) throws -> NativeObjCMethodHook {
        try NativeObjCMethodHook.install(on: type, selector: selector, as: signature,
            classMethod: classMethod, options: options, object: nil, owner: owner,
            requiresMainThread: false, onFailure: onFailure, body: body)
    }

    /// Installs a hook for a method whose callers are required to run on MainActor.
    ///
    /// This declaration is a caller-supplied contract. The callback is synchronous;
    /// it does not hop executors. Background entry reports `wrongThread` and passes
    /// through to the next hook before decoding Swift arguments. `onFailure` must
    /// therefore be safe on background threads. Other parameters and unsafe
    /// requirements match ``hookMethod(on:selector:as:classMethod:options:retaining:onFailure:body:)``.
    @unsafe @MainActor public func hookMainActorMethod<Result, each Argument>(
        on type: AnyClass, selector: String, as signature: ((repeat each Argument) -> Result).Type,
        classMethod: Bool = false, options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @MainActor @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) throws -> NativeObjCMethodHook {
        try NativeObjCMethodHook.install(on: type, selector: selector, as: signature,
            classMethod: classMethod, options: options, object: nil, owner: owner,
            requiresMainThread: true, onFailure: onFailure) {
                (call: NativeObjCMethodInvocation<Result, repeat each Argument>, values: repeat each Argument) in
                let input = ObjCReplacementIsolatedArguments(call: call, values: (repeat each values))
                return try MainActor.assumeIsolated {
                    ObjCReplacementIsolatedResult(value: try body(input.call, repeat each input.values))
                }.value
            }
    }
}

extension NativeObject {
    /// Installs a method hook filtered by this object's weak identity.
    ///
    /// The returned token does not retain this wrapper or its receiver. The
    /// wrapper itself still retains the receiver until released. Other instances
    /// use the same class dispatcher but skip this callback. Later isa changes or
    /// overrides that bypass the installed class entry are not followed.
    ///
    /// Parameters, failure behavior, and unsafe requirements match
    /// ``ABIRuntime/hookMethod(on:selector:as:classMethod:options:retaining:onFailure:body:)``.
    /// The target is an instance method of the receiver's current runtime class.
    @unsafe public func hookMethod<Result, each Argument>(
        selector: String, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) throws -> NativeObjCMethodHook {
        let object = receiver!
        return try NativeObjCMethodHook.install(on: object_getClass(object)!, selector: selector, as: signature,
            classMethod: false, options: options, object: object, owner: owner,
            requiresMainThread: false, onFailure: onFailure, body: body)
    }

    /// Installs a weak identity-filtered callback for a known MainActor method.
    ///
    /// Combines ``hookMethod(selector:as:options:retaining:onFailure:body:)`` scope
    /// with ``ABIRuntime/hookMainActorMethod(on:selector:as:classMethod:options:retaining:onFailure:body:)`` isolation.
    @unsafe @MainActor public func hookMainActorMethod<Result, each Argument>(
        selector: String, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @MainActor @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) throws -> NativeObjCMethodHook {
        let object = receiver!
        return try NativeObjCMethodHook.install(on: object_getClass(object)!, selector: selector, as: signature,
            classMethod: false, options: options, object: object, owner: owner,
            requiresMainThread: true, onFailure: onFailure) {
                (call: NativeObjCMethodInvocation<Result, repeat each Argument>, values: repeat each Argument) in
                let input = ObjCReplacementIsolatedArguments(call: call, values: (repeat each values))
                return try MainActor.assumeIsolated {
                    ObjCReplacementIsolatedResult(value: try body(input.call, repeat each input.values))
                }.value
            }
    }
}
