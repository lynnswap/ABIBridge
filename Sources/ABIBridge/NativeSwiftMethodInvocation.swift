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
/// Access requires the original thread and an active callback. Copied diagnostic
/// metadata remains readable after return; a saved invocation does not preserve
/// its native frame or callback captures. `proceed` does not redispatch the method.
public struct NativeSwiftMethodInvocation<Result, each Argument>: CustomStringConvertible {
    let frame: SwiftHookFrame
    let prepared: SwiftHookCallbackSignature<Result, repeat each Argument>
    let receiverView: SwiftHookReceiverView
    /// The resolved source declaration, not an inferred predecessor name.
    public let declaration: NativeDeclaration
    /// Explicit argument/result types, excluding the hidden receiver.
    public var signature: ((repeat each Argument) -> Result).Type { ((repeat each Argument) -> Result).self }
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
    /// - Throws: Scope/thread errors or an incompatible receiver representation.
    public func receiver<Receiver>(as type: Receiver.Type) throws -> Receiver {
        try frame.receiver { try receiverView.decode($0, as: type) }
    }

    /// Calls the next implementation with replacement explicit arguments.
    ///
    /// The incoming receiver is preserved. Mutating value methods use its
    /// original address. A consuming method receives an independent owned
    /// receiver copy for each continuation, so the callback can
    /// inspect its receiver before and after proceeding. Errors after a completed
    /// continuation preserve its latest result without repeating native effects.
    public func proceed(_ values: repeat each Argument) throws -> Result {
        try frame.use { operation in
            let storage = try prepared.encodeArguments(repeat each values)
            let result = try operation(storage)
            return try prepared.result.copy(from: result, retaining: result)
        }
    }
}

func prepareSwiftMethodHandler<Signature, Result, each Argument>(
    method: NativeSwiftMethod<Signature>,
    prepared: SwiftHookCallbackSignature<Result, repeat each Argument>,
    receiver: SwiftHookReceiverView, requiresMainActor: Bool,
    onFailure: @escaping @Sendable (any Error) -> Void,
    body: @escaping @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
) -> SwiftHookHandler {
    let declaration = method.symbol.declaration
    let description = hookDescription(declaration: declaration,
        signature: ((repeat each Argument) -> Result).self, unnamed: "<Swift method>")
    return SwiftHookHandler(requiresMainActor: requiresMainActor, retaining: method, failure: onFailure) { frame, storage in
        let values = try prepared.decodeArguments(storage)
        let call = NativeSwiftMethodInvocation(frame: frame, prepared: prepared, receiverView: receiver,
            declaration: declaration, description: description)
        return try prepared.result.encode(body(call, repeat each values))
    }
}

extension NativeSwiftMethod {
    func prepareHook<Result, each Argument>(
        requiresMainActor: Bool, onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) throws -> (signature: SwiftHookSignature, handler: SwiftHookHandler) {
        guard errorPlan == nil else {
            throw ABIResolutionError.unsupportedDeclaration("Managed hooks cannot yet return native Swift errors.")
        }
        let receiverView = SwiftHookReceiverView(self)
        let prepared = try SwiftHookCallbackSignature<Result, repeat each Argument>()
        let signature = try prepared.erased(consumingArguments: consumesArguments, receiver: receiver, retaining: self)
        let handler = prepareSwiftMethodHandler(method: self, prepared: prepared, receiver: receiverView,
            requiresMainActor: requiresMainActor, onFailure: onFailure, body: body)
        return (signature, handler)
    }
}
