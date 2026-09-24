import ABIBridgeObjCXX
import Foundation

/// A captured Objective-C implementation whose receiver is supplied at call time.
///
/// Later method replacement does not change this handle, and no instance is
/// retained. Discoverable implementation and class images are retained.
///
/// Caller-created classes must remain registered, and generated IMPs must remain
/// callable while any handle exists. A retained block does not prevent another
/// owner from invalidating its IMP with `imp_removeBlock`.
/// See <doc:ObjectiveCInvocation> for dispatch and lifetime rules.
public struct NativeObjCImplementation<Result, each Argument> {
    private let binding: ObjCInvocationBinding
    private let signature: ObjCMethodSignature<Result, repeat each Argument>
    private let interface: CCallInterface
    private let codeOwner: Any?

    init(binding: ObjCInvocationBinding, retaining owner: Any?) throws {
        self.binding = binding
        signature = try ObjCMethodSignature(handle: binding.handle)
        interface = try signature.callInterface()
        codeOwner = owner
    }

    /// Calls the captured IMP with a compatible receiver.
    ///
    /// Instance captures accept instances of the requested class or subclasses.
    /// Class-method captures accept that class or subclass class objects.
    /// Overrides are not selected. The caller honors isolation, pointer/code
    /// lifetimes, ownership annotations, and block signatures. Foreign exceptions
    /// must not cross this boundary.
    ///
    /// - Parameters:
    ///   - receiver: The live instance or class object for this call.
    ///   - values: Explicit arguments, excluding self and the selector.
    /// - Returns: The converted result, with retainable values managed by Swift.
    /// - Throws: An incompatible-receiver, conversion, or invocation error.
    @unsafe public func unsafeInvoke(on receiver: AnyObject, _ values: repeat each Argument) throws -> Result {
        try withExtendedLifetime((receiver, codeOwner)) {
            try signature.invoke(repeat each values, using: { addresses, output in
                var error: NSError?
                let success = addresses.withUnsafeBufferPointer {
                    ABIInvokeObjCImplementation(binding.handle, interface.handle, receiver, output, $0.baseAddress, &error)
                }
                guard success else {
                    if let error { throw error }
                    throw ABIResolutionError.invalidAddress
                }
            })
        }
    }
}

extension ABIRuntime {
    /// Captures a concrete Objective-C implementation without binding an instance.
    ///
    /// The signature describes explicit arguments only. Dynamic method resolution
    /// may run during lookup, but forwarding-only selectors cannot be captured.
    /// Ordinary selector method handles continue to follow current message dispatch.
    ///
    /// - Parameters:
    ///   - type: The class whose instance or class method should be captured.
    ///   - selector: The selector, including argument colons.
    ///   - signature: A supported synchronous function-type metatype.
    ///   - classMethod: Whether to capture a class method; defaults to false.
    ///   - options: Ownership overrides absent from runtime encodings.
    ///   - owner: An optional owner keeping generated code or a dynamic class valid.
    /// - Returns: A reusable implementation with no retained receiver instance.
    /// - Throws: A lookup, signature, unsupported-implementation, or image error.
    public nonisolated func objcImplementation<Result, each Argument>(
        on type: AnyClass, selector: String,
        as signature: ((repeat each Argument) -> Result).Type,
        classMethod: Bool = false, options: NativeMethodOptions = .init(),
        retaining owner: Any? = nil
    ) throws -> NativeObjCImplementation<Result, repeat each Argument> {
        var error: NSError?
        guard let handle = ABICopyObjCImplementation(
            type, NSSelectorFromString(selector), classMethod,
            options.returnsRetainedObject.map { $0 ? 1 : 0 } ?? -1,
            options.consumesReceiver.map { $0 ? 1 : 0 } ?? -1, &error
        ) else {
            if let error { throw error }
            throw ABIResolutionError.metadataUnavailable(selector)
        }
        return try NativeObjCImplementation(binding: ObjCInvocationBinding(handle), retaining: owner)
    }
}
