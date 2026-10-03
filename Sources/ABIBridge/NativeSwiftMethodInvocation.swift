import ABIBridgeCore
import Foundation
import ObjectiveC

struct SwiftHookReceiverView: Sendable {
    let codec: SwiftReceiverCodec
    let expectedClass: AnyClass?
    let owner: any Sendable

    init<Signature>(_ method: NativeSwiftMethod<Signature>) {
        codec = method.receiver.codec; expectedClass = method.type.metadata as? AnyClass; owner = method
    }

    func decode<Value>(_ storage: NativeValueStorage, as: Value.Type) throws -> Value {
        if let expectedClass {
            guard let address = storage.address.load(as: UnsafeRawPointer?.self) else {
                throw ABIInvocationError.incompatibleValue(expected: "a live Swift receiver", actual: "nil")
            }
            let object = Unmanaged<AnyObject>.fromOpaque(address).takeUnretainedValue()
            var type: AnyClass? = Swift.type(of: object)
            while let current = type, current !== expectedClass { type = class_getSuperclass(current) }
            guard type != nil else {
                throw ABIInvocationError.incompatibleValue(expected: String(reflecting: expectedClass), actual: String(reflecting: Swift.type(of: object)))
            }
        }
        let decoded = try codec.decode(storage, owner)
        guard let value = decoded as? Value else {
            throw ABIInvocationError.incompatibleValue(expected: String(reflecting: Value.self), actual: String(reflecting: Swift.type(of: decoded)))
        }
        return value
    }
}

/// A scoped Swift receiver and continuation for an intercepted instance method.
///
/// Access requires an active callback and the original thread for synchronous
/// signatures or the same Swift task for asynchronous signatures. Copied
/// diagnostic metadata remains readable after return; a saved invocation does
/// not preserve its native frame or captures. `proceed` does not redispatch.
public struct NativeSwiftMethodInvocation<Signature>: CustomStringConvertible {
    let frame: SwiftHookFrame
    let prepared: SwiftCallValues
    let receiverView: SwiftHookReceiverView
    /// The resolved source declaration, not an inferred predecessor name.
    public let declaration: NativeDeclaration
    /// Argument, result, and effect signature, excluding the hidden receiver.
    public var signature: Signature.Type { Signature.self }
    /// Cached declaration and signature without accessing receiver properties.
    public let description: String

    /// Copies the current receiver into the requested Swift representation.
    ///
    /// A class reference preserves the incoming object's identity and ordinary
    /// Swift lifetime. Property changes are visible to subsequent implementations
    /// and to the native caller. A value receiver is a snapshot in its selected
    /// representation; editing that copy does not write back. A later read sees
    /// native changes made through an original mutating receiver address.
    /// Pointer adapters retain their own pointee rules.
    /// - Throws: Scope, thread/task errors, or an incompatible receiver representation.
    public func receiver<Receiver>(as type: Receiver.Type) throws -> Receiver {
        try frame.receiver { try receiverView.decode($0, as: type) }
    }

    /// Calls the next implementation with replacement explicit arguments.
    ///
    /// The incoming receiver is preserved. Mutating value methods use its
    /// original address. A consuming method receives an independent owned
    /// receiver copy for each continuation, so the callback can
    /// inspect its receiver before and after proceeding. Native failures throw
    /// `NativeSwiftError`. If a later hook failure cannot use the declared native
    /// error channel, recovery preserves the latest result or native failure.
    public func proceed<Result, Failure: Error, each Argument>(_ values: repeat each Argument) throws -> Result
    where Signature == (repeat each Argument) throws(Failure) -> Result {
        try invoke(repeat each values)
    }

    public func proceed<Result, Failure: Error, each Argument>(_ values: repeat each Argument) throws -> Result
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try invoke(repeat each values)
    }

    /// Awaits the captured predecessor on this callback's native task.
    /// The continuation remains usable across suspension until the callback returns.
    @_transparent
    public nonisolated(nonsending) func proceed<Result, Failure: Error, each Argument>(_ values: repeat each Argument) async throws -> Result
    where Signature == (repeat each Argument) async throws(Failure) -> Result {
        try await invokeAsync(repeat each values)
    }

    @_transparent
    public nonisolated(nonsending) func proceed<Result, Failure: Error, each Argument>(_ values: repeat each Argument) async throws -> Result
    where Signature == @Sendable (repeat each Argument) async throws(Failure) -> Result {
        try await invokeAsync(repeat each values)
    }

    @_transparent
    public nonisolated(nonsending) func proceed<Result, Failure: Error, each Argument>(_ values: repeat each Argument) async throws -> Result
    where Signature == @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try await invokeAsync(repeat each values)
    }

    @_transparent
    public nonisolated(nonsending) func proceed<Result, Failure: Error, each Argument>(_ values: repeat each Argument) async throws -> Result
    where Signature == @Sendable @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try await invokeAsync(repeat each values)
    }

    @usableFromInline nonisolated(nonsending) func invokeAsync<Result, each Argument>(_ values: repeat each Argument) async throws -> Result {
        do {
            return try await frame.useAsync { operation in
                let storage = try frame.recovery.map { scope in try scope.withTransfer { try prepared.encode(repeat each values, retainingCode: nil) } }
                    ?? prepared.encode(repeat each values, retainingCode: nil)
                let result = try await operation(storage)
                return try prepared.decode(result, retaining: result, retainingCode: nil)
            }
        } catch let error as SwiftHookCompletedResultError { throw error.underlying }
    }

    private func invoke<Result, each Argument>(_ values: repeat each Argument) throws -> Result {
        try frame.invoke(prepared: prepared, repeat each values)
    }
}

func prepareSwiftMethodHandler<Signature, Result, each Argument>(
    method: NativeSwiftMethod<Signature>,
    prepared: SwiftHookCallbackSignature<Result, repeat each Argument>,
    receiver: SwiftHookReceiverView, requiresMainActor: Bool,
    onFailure: @escaping @Sendable (any Error) -> Void,
    body: @escaping @Sendable (NativeSwiftMethodInvocation<Signature>, repeat each Argument) throws -> Result
) -> SwiftHookHandler {
    let declaration = method.symbol.declaration
    let description = hookDescription(declaration: declaration,
        signature: Signature.self, unnamed: "<Swift method>")
    return SwiftHookHandler(requiresMainActor: requiresMainActor, retaining: method, failure: onFailure) { frame, storage in
        let call = NativeSwiftMethodInvocation<Signature>(frame: frame, prepared: prepared.values, receiverView: receiver,
            declaration: declaration, description: description)
        return try prepared.invoke(storage, recovery: frame.recovery) { (values: repeat each Argument) in
            try body(call, repeat each values)
        }
    }
}

extension NativeSwiftMethod {
    func prepareHook<Result, each Argument>(
        requiresMainActor: Bool, onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeSwiftMethodInvocation<Signature>, repeat each Argument) throws -> Result
    ) throws -> (signature: SwiftHookSignature, handler: SwiftHookHandler) {
        let receiverView = SwiftHookReceiverView(self)
        guard case .synchronous(let call) = call else {
            preconditionFailure("A synchronous hook has a synchronous callable plan.")
        }
        let prepared = try SwiftHookCallbackSignature<Result, repeat each Argument>(call: call)
        let signature = try prepared.erased(consumingArguments: consumesArguments, receiver: receiver,
            errorPlan: errorPlan, retaining: self)
        let handler = prepareSwiftMethodHandler(method: self, prepared: prepared, receiver: receiverView,
            requiresMainActor: requiresMainActor, onFailure: onFailure, body: body)
        return (signature, handler)
    }
}

extension NativeSwiftMethod {
    func prepareAsyncHook<Result, each Argument>(
        requiresMainActor: Bool, onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeSwiftMethodInvocation<Signature>, repeat each Argument) async throws -> Result
    ) throws -> (signature: SwiftHookSignature, handler: SwiftHookHandler) {
        guard case .asynchronous(let call, let implementation) = call else {
            preconditionFailure("An async hook has an async callable plan.")
        }
        let prepared = try SwiftHookCallbackSignature<Result, repeat each Argument>(call: call, contextSize: implementation.entry.contextSize)
        let signature = try prepared.erased(consumingArguments: consumesArguments, receiver: receiver,
            errorPlan: errorPlan, retaining: self)
        let receiverView = SwiftHookReceiverView(self)
        let declaration = symbol.declaration
        let description = hookDescription(declaration: declaration, signature: Signature.self, unnamed: "<Swift method>")
        let handler = SwiftHookHandler(requiresMainActor: requiresMainActor, retaining: self, failure: onFailure,
            invokeAsync: { frame, storage in
                    let invocation = NativeSwiftMethodInvocation<Signature>(frame: frame, prepared: prepared.values,
                    receiverView: receiverView, declaration: declaration, description: description)
                return try await prepared.invokeAsync(storage, recovery: frame.recovery, invocation: invocation, body: body)
            })
        return (signature, handler)
    }
}
