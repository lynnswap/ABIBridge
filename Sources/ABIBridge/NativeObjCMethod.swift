import ABIBridgeObjCXX
import Foundation

/// A prepared Objective-C message whose receiver is supplied at call time.
///
/// The handle retains its class image and optional code owner, but no receiver
/// instance or fixed IMP. Compatible subclass overrides and later replacements
/// participate in normal message dispatch. The caller honors receiver isolation
/// and the prepared declaration's ABI and ownership contract.
public struct NativeObjCMethod<Result, each Argument> {
    private let binding: ObjCInvocationBinding
    private let signature: ObjCMethodSignature<Result, repeat each Argument>

    init(binding: ObjCInvocationBinding) throws {
        self.binding = binding
        signature = try ObjCMethodSignature(handle: binding.handle, declaration: binding.declaration)
    }

    init(binding: ObjCInvocationBinding, signature: ObjCMethodSignature<Result, repeat each Argument>) {
        self.binding = binding
        self.signature = signature
    }

    /// Sends the prepared message to a compatible instance or class object.
    ///
    /// The receiver stays alive throughout the call. Its current method encoding
    /// must remain compatible with the prepared declaration. Foreign exceptions
    /// are not converted into Swift errors.
    @unsafe public func unsafeInvoke(on receiver: AnyObject, _ values: repeat each Argument) throws -> Result {
        try withExtendedLifetime((receiver, binding)) {
            try signature.invoke(repeat each values, using: { addresses, output in
                var error: NSError?
                let success = addresses.withUnsafeBufferPointer {
                    ABIInvokeObjCDispatch(binding.handle, receiver, output, $0.baseAddress, &error)
                }
                guard success else { throw objcResolutionError(error, declaration: binding.declaration) }
            })
        }
    }

    /// Retains a compatible receiver for repeated ordinary message dispatch.
    ///
    /// The bound handle shares the prepared signature and keeps its receiver
    /// alive until the last bound copy is released. Subsequent replacements must
    /// preserve the signature and ownership contract, as for other bound methods.
    public func bind(to receiver: AnyObject) throws -> NativeBoundObjCMethod<Result, repeat each Argument> {
        var error: NSError?
        guard let handle = ABICopyBoundObjCInvocation(binding.handle, receiver, &error) else {
            throw objcResolutionError(error, declaration: binding.declaration)
        }
        return NativeBoundObjCMethod(
            binding: ObjCInvocationBinding(handle, declaration: binding.declaration, retaining: binding.owner),
            signature: signature
        )
    }
}

extension ABIRuntime {
    /// Prepares a class-declared message without retaining a receiver instance.
    ///
    /// Dynamic method resolution may run. A concrete method signature must be
    /// available on the requested class; use object(receiver).method for
    /// receiver-specific forwarding signatures. Invocation selects the receiver's
    /// current implementation rather than the IMP present during preparation.
    ///
    /// - Parameters:
    ///   - type: The class declaring the instance or class method.
    ///   - selector: A selector name, including argument colons.
    ///   - signature: Explicit arguments and result, excluding self and _cmd.
    ///   - classMethod: Whether calls accept class objects instead of instances.
    ///   - options: Ownership overrides absent from runtime encodings.
    ///   - owner: Optional lifetime owner for generated classes or code.
    public nonisolated func objcMethod<Result, each Argument>(
        on type: AnyClass, selector: String,
        as signature: ((repeat each Argument) -> Result).Type,
        classMethod: Bool = false, options: NativeMethodOptions = .init(),
        retaining owner: Any? = nil
    ) throws -> NativeObjCMethod<Result, repeat each Argument> {
        let declaration = objcMethodDeclaration(on: type, selector: selector, classMethod: classMethod)
        var error: NSError?
        guard let handle = ABICopyObjCDispatch(
            type, NSSelectorFromString(selector), classMethod,
            options.returnsRetainedObject.map { $0 ? 1 : 0 } ?? -1,
            options.consumesReceiver.map { $0 ? 1 : 0 } ?? -1, &error
        ) else { throw objcResolutionError(error, declaration: declaration) }
        return try NativeObjCMethod(
            binding: ObjCInvocationBinding(handle, declaration: declaration, retaining: owner)
        )
    }
}
