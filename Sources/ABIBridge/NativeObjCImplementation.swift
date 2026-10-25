import ABIBridgeObjCXX
import ABIBridgeObjCXX.Backend
import Foundation
import ObjectiveC

/// A captured Objective-C implementation whose receiver is supplied at call time.
///
/// Later method replacement does not change this handle, and no instance is retained. Discoverable implementation and class images are retained.
///
/// Caller-created classes must remain registered, and generated IMPs must remain callable while any handle exists. A retained block does not prevent another owner from invalidating its IMP with `imp_removeBlock`. See <doc:ObjectiveCInvocation> for dispatch and lifetime rules.
public struct NativeObjCImplementation<Result, each Argument> {
    private let binding: ObjCInvocationBinding
    private let signature: ObjCCallSignature<Result, repeat each Argument>
    private let interface: CCallInterface
    private let codeOwner: Any?

    init(
        binding: ObjCInvocationBinding,
        signature: ObjCCallSignature<Result, repeat each Argument>,
        interface: CCallInterface,
        retaining owner: Any?
    ) {
        self.binding = binding
        self.signature = signature
        self.interface = interface
        codeOwner = owner
    }

    /// Retains a compatible receiver for repeated calls to this captured IMP.
    ///
    /// Binding shares this implementation and its code owner without selecting
    /// another IMP or consulting the receiver's current method signature.
    /// The receiver remains in the caller's isolation domain.
    /// - Throws: A resolution error when the receiver is incompatible with the captured class or instance method.
    public func bind(
        to receiver: AnyObject
    ) throws -> NativeBoundObjCImplementation<Result, repeat each Argument> {
        var error: NSError?
        guard ABIValidateCapturedObjCInvocationReceiver(binding.handle, receiver, &error) else {
            throw objcResolutionError(error, declaration: binding.declaration)
        }
        return NativeBoundObjCImplementation(implementation: self, receiver: receiver)
    }

    /// Calls the captured IMP with a compatible receiver.
    ///
    /// Instance captures accept instances of the requested class or subclasses. Class-method captures accept that class or subclass class objects. Overrides are not selected. The caller honors isolation, pointer/code lifetimes, ownership annotations, and block signatures. An Objective-C exception is thrown as ``NativeObjCException``; an implementation prepared with a `throws` signature throws the `NSError` it reports.
    ///
    /// - Parameters:
    ///   - receiver: The live instance or class object for this call.
    ///   - values: Explicit arguments, excluding self and the selector.
    /// - Returns: The converted result, with retainable values managed by Swift.
    /// - Throws: An incompatible-receiver, conversion, or invocation error.
    @unsafe public func unsafeInvoke(
        on receiver: AnyObject,
        _ values: repeat each Argument
    ) throws -> Result {
        try withExtendedLifetime((receiver, codeOwner)) {
            try signature.invoke(
                repeat each values,
                using: { addresses, output in
                    var error: NSError?
                    let success = ABIInvokeObjCImplementation(
                        binding.handle,
                        interface.handle,
                        receiver,
                        output,
                        addresses.baseAddress,
                        &error
                    )
                    guard success else {
                        throw objcResolutionError(error, declaration: binding.declaration)
                    }
                }
            )
        }
    }
}

/// A captured Objective-C implementation bound to a retained receiver.
///
/// Calls use the captured IMP even after method replacement. The receiver and
/// code owner remain in the caller's isolation domain, and the receiver is
/// released before the implementation's retained images.
public struct NativeBoundObjCImplementation<Result, each Argument> {
    private let storage: BoundObjCImplementationStorage<Result, repeat each Argument>

    /// The same captured implementation, independent of this receiver binding.
    public var implementation: NativeObjCImplementation<Result, repeat each Argument> {
        storage.implementation
    }

    init(
        implementation: NativeObjCImplementation<Result, repeat each Argument>,
        receiver: AnyObject
    ) {
        storage = BoundObjCImplementationStorage(implementation: implementation, receiver: receiver)
    }

    /// Calls the captured IMP using the retained receiver.
    ///
    /// The caller honors the receiver's isolation, native ownership, block
    /// signatures, and pointer lifetimes, as for the unbound implementation.
    /// - Throws: A conversion or invocation error, including a native Objective-C exception or reported NSError.
    @unsafe public func unsafeInvoke(_ values: repeat each Argument) throws -> Result {
        try unsafe implementation.unsafeInvoke(on: storage.receiver!, repeat each values)
    }
}

private final class BoundObjCImplementationStorage<Result, each Argument> {
    let implementation: NativeObjCImplementation<Result, repeat each Argument>
    var receiver: AnyObject?

    init(
        implementation: NativeObjCImplementation<Result, repeat each Argument>,
        receiver: AnyObject
    ) {
        self.implementation = implementation
        self.receiver = receiver
    }

    deinit { withExtendedLifetime(implementation) { receiver = nil } }
}

extension NativeObject {
    /// Captures a fixed IMP from this receiver's class and retains the receiver.
    ///
    /// Search and preparation run on the caller's thread. Later replacements
    /// do not change the captured implementation; forwarding-only selectors
    /// cannot be captured.
    public func resolveAndWait<Result, each Argument>(
        _ request: NativeRequest<NativeObjCImplementationRequest<Result, repeat each Argument>>
    ) throws -> NativeBoundObjCImplementation<Result, repeat each Argument> {
        let receiver = receiver!
        let receiverType = object_getClass(receiver)!
        let classMethod = class_isMetaClass(receiverType)
        let type: AnyClass = classMethod ? receiver as! AnyClass : receiverType
        return try runtime.resolveAndWait(request, on: type, classMethod: classMethod).bind(
            to: receiver
        )
    }

    /// Captures a fixed IMP without blocking the caller's executor.
    ///
    /// Class lookup and ABI preparation run on a worker. This receiver and the
    /// returned bound handle remain in the caller's isolation domain.
    public nonisolated(nonsending) func resolve<Result, each Argument>(
        _ request: NativeRequest<NativeObjCImplementationRequest<Result, repeat each Argument>>
    ) async throws -> NativeBoundObjCImplementation<Result, repeat each Argument> {
        let receiver = receiver!
        let receiverType = object_getClass(receiver)!
        let classMethod = class_isMetaClass(receiverType)
        let type: AnyClass = classMethod ? receiver as! AnyClass : receiverType
        return try await runtime.resolve(request, on: type, classMethod: classMethod).bind(
            to: receiver
        )
    }
}

extension ABIRuntime {

    /// Captures an Objective-C implementation from a class without binding an
    /// instance.
    ///
    /// Lookup and preparation run synchronously on the caller's thread and
    /// join any shared call-interface preparation already in progress. The
    /// signature describes explicit arguments only. Dynamic method resolution
    /// may run during lookup, but forwarding-only selectors cannot be
    /// captured. Later method replacement does not change the handle.
    ///
    /// - Parameters:
    ///   - request: The implementation and its ownership options.
    ///   - type: The class whose instance or class method is captured.
    ///   - classMethod: Whether to capture a class method.
    ///   - owner: An optional owner keeping generated code or a dynamic class
    ///     valid.
    /// - Returns: A reusable implementation with no retained receiver
    ///   instance.
    /// - Throws: A lookup, signature, unsupported-implementation, or image
    ///   error.
    public nonisolated func resolveAndWait<Result, each Argument>(
        _ request: NativeRequest<NativeObjCImplementationRequest<Result, repeat each Argument>>,
        on type: AnyClass,
        classMethod: Bool = false,
        retaining owner: Any? = nil
    ) throws -> NativeObjCImplementation<Result, repeat each Argument> {
        let prepared:
            (ObjCInvocationPlan, ObjCCallSignature<Result, repeat each Argument>, CCallInterface) =
                try prepareObjCImplementation(
                    request.declaration.query,
                    on: type,
                    classMethod: classMethod
                )
        return NativeObjCImplementation(
            binding: ObjCInvocationBinding(plan: prepared.0),
            signature: prepared.1,
            interface: prepared.2,
            retaining: owner
        )
    }

    /// Captures an Objective-C implementation from a class without blocking
    /// the caller's executor.
    ///
    /// Class lookup, dynamic resolution, image acquisition, and
    /// call-interface preparation run on a worker, joining shared ABI
    /// preparation already in progress. The optional code owner remains in
    /// the caller's isolation domain. No instance is retained, and invocation
    /// stays on the caller's executor.
    ///
    /// - Parameters:
    ///   - request: The implementation and its ownership options.
    ///   - type: The class whose instance or class method is captured.
    ///   - classMethod: Whether to capture a class method.
    ///   - owner: An optional owner keeping generated code or a dynamic class
    ///     valid.
    /// - Returns: A reusable implementation with no retained receiver
    ///   instance.
    /// - Throws: The same errors as synchronous resolution.
    public nonisolated(nonsending) func resolve<Result, each Argument>(
        _ request: NativeRequest<NativeObjCImplementationRequest<Result, repeat each Argument>>,
        on type: AnyClass,
        classMethod: Bool = false,
        retaining owner: Any? = nil
    ) async throws -> NativeObjCImplementation<Result, repeat each Argument> {
        let query = request.declaration.query
        let prepared:
            (ObjCInvocationPlan, ObjCCallSignature<Result, repeat each Argument>, CCallInterface) =
                try await NativePreparation.run {
                    try self.prepareObjCImplementation(query, on: type, classMethod: classMethod)
                }
        return NativeObjCImplementation(
            binding: ObjCInvocationBinding(plan: prepared.0),
            signature: prepared.1,
            interface: prepared.2,
            retaining: owner
        )
    }

    private nonisolated func prepareObjCImplementation<Result, each Argument>(
        _ query: ObjCMessageQuery,
        on type: AnyClass,
        classMethod: Bool
    ) throws -> (
        ObjCInvocationPlan, ObjCCallSignature<Result, repeat each Argument>, CCallInterface
    ) {
        let selector = query.selector
        let options = query.options
        let declaration = objcMethodDeclaration(
            on: type,
            selector: selector,
            classMethod: classMethod
        )
        var error: NSError?
        let handle = options.withConsumedArguments { consumed in
            ABICopyCapturedObjCInvocation(
                type,
                NSSelectorFromString(selector),
                classMethod,
                options.returnsRetainedObject.map { $0 ? 1 : 0 } ?? -1,
                options.consumesReceiver.map { $0 ? 1 : 0 } ?? -1,
                consumed.baseAddress,
                consumed.count,
                &error
            )
        }
        guard let handle else {
            throw objcResolutionError(error, declaration: declaration)
        }
        let plan = ObjCInvocationPlan(handle, declaration: declaration)
        let prepared = try ObjCCallSignature<Result, repeat each Argument>(
            handle: handle,
            declaration: declaration,
            variadicFrom: query.variadicFrom,
            reportsErrors: query.reportsErrors
        )
        return (plan, prepared, try prepared.callInterface())
    }
}
