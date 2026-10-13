import ABIBridgeObjCXX
import Foundation

/// A prepared Objective-C message whose receiver is supplied at call time.
///
/// The handle retains its class image and optional code owner, but no receiver instance or fixed IMP. Compatible subclass overrides and later replacements participate in normal message dispatch. The caller honors receiver isolation and the prepared declaration's ABI and ownership contract.
public struct NativeObjCMethod<Result, each Argument> {
    private let binding: ObjCInvocationBinding
    private let signature: ObjCMethodSignature<Result, repeat each Argument>

    init(
        binding: ObjCInvocationBinding,
        signature: ObjCMethodSignature<Result, repeat each Argument>
    ) {
        self.binding = binding
        self.signature = signature
    }

    /// Sends the prepared message to a compatible instance or class object.
    ///
    /// The receiver stays alive throughout the call. Its current method encoding must remain compatible with the prepared declaration. Foreign exceptions are not converted into Swift errors.
    @unsafe public func unsafeInvoke(
        on receiver: AnyObject,
        _ values: repeat each Argument
    ) throws -> Result {
        try withExtendedLifetime((receiver, binding)) {
            try signature.invoke(
                repeat each values,
                using: { addresses, output in
                    var error: NSError?
                    let success: Bool
                    if let interface = signature.variadicInterface {
                        success = ABIInvokeVariadicObjCDispatch(
                            binding.handle,
                            interface.handle,
                            receiver,
                            output,
                            addresses.baseAddress,
                            &error
                        )
                    } else {
                        success = ABIInvokeObjCDispatch(
                            binding.handle,
                            receiver,
                            output,
                            addresses.baseAddress,
                            &error
                        )
                    }
                    guard success else {
                        throw objcResolutionError(error, declaration: binding.declaration)
                    }
                }
            )
        }
    }

    /// Retains a compatible receiver for repeated ordinary message dispatch.
    ///
    /// The bound handle shares the prepared signature and keeps its receiver alive until the last bound copy is released. Subsequent replacements must preserve the signature and ownership contract, as for other bound methods.
    public func bind(
        to receiver: AnyObject
    ) throws -> NativeBoundObjCMethod<Result, repeat each Argument> {
        var error: NSError?
        guard let handle = ABICopyBoundObjCInvocation(binding.handle, receiver, &error) else {
            throw objcResolutionError(error, declaration: binding.declaration)
        }
        return NativeBoundObjCMethod(
            binding: ObjCInvocationBinding(
                handle,
                declaration: binding.declaration,
                retaining: binding.owner
            ),
            signature: signature
        )
    }
}

extension ABIRuntime {
    /// Prepares a class-declared message without retaining a receiver instance.
    ///
    /// Search and preparation run synchronously on the caller's thread. Dynamic method resolution may run. A concrete method signature must be available on the requested class; use `object(receiver).resolveMethodAndWait(selector:as:)` for receiver-specific forwarding signatures. Invocation selects the receiver's current implementation rather than the IMP present during preparation.
    ///
    /// - Parameters:
    ///   - type: The class declaring the instance or class method.
    ///   - selector: A selector name, including argument colons.
    ///   - signature: Explicit arguments and result, excluding self and _cmd.
    ///   - variadicFrom: Index of the first anonymous argument, or nil for a fixed signature.
    ///   - classMethod: Whether calls accept class objects instead of instances.
    ///   - options: Ownership overrides absent from runtime encodings.
    ///   - owner: Optional lifetime owner for generated classes or code.
    public nonisolated func resolveObjCMethodAndWait<Result, each Argument>(
        on type: AnyClass,
        selector: String,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int? = nil,
        classMethod: Bool = false,
        options: NativeMethodOptions = .init(),
        retaining owner: Any? = nil
    ) throws -> NativeObjCMethod<Result, repeat each Argument> {
        let prepared: (ObjCInvocationPlan, ObjCMethodSignature<Result, repeat each Argument>) =
            try prepareObjCMethod(
                on: type,
                selector: selector,
                as: signature,
                variadicFrom: variadicFrom,
                classMethod: classMethod,
                options: options
            )
        return NativeObjCMethod(
            binding: ObjCInvocationBinding(plan: prepared.0, retaining: owner),
            signature: prepared.1
        )
    }

    /// Resolves a class-declared message without blocking the caller's executor.
    ///
    /// Class lookup, dynamic method resolution, image acquisition, and signature preparation run on a worker. Shared call interfaces join any preparation already in progress. The optional owner and returned handle remain in the caller's isolation domain. Invocation follows ordinary message dispatch on the caller's executor.
    public nonisolated(nonsending) func resolveObjCMethod<Result, each Argument>(
        on type: AnyClass,
        selector: String,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int? = nil,
        classMethod: Bool = false,
        options: NativeMethodOptions = .init(),
        retaining owner: Any? = nil
    ) async throws -> NativeObjCMethod<Result, repeat each Argument> {
        let prepared = try await NativePreparation.run {
            try self.prepareObjCMethod(
                on: type,
                selector: selector,
                as: signature,
                variadicFrom: variadicFrom,
                classMethod: classMethod,
                options: options
            )
        }
        return NativeObjCMethod(
            binding: ObjCInvocationBinding(plan: prepared.0, retaining: owner),
            signature: prepared.1
        )
    }

    private nonisolated func prepareObjCMethod<Result, each Argument>(
        on type: AnyClass,
        selector: String,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int?,
        classMethod: Bool,
        options: NativeMethodOptions
    ) throws -> (ObjCInvocationPlan, ObjCMethodSignature<Result, repeat each Argument>) {
        let declaration = objcMethodDeclaration(
            on: type,
            selector: selector,
            classMethod: classMethod
        )
        var error: NSError?
        let handle = options.withConsumedArguments { consumed in
            ABICopyObjCDispatch(
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
        guard let handle else { throw objcResolutionError(error, declaration: declaration) }
        let plan = ObjCInvocationPlan(handle, declaration: declaration)
        let prepared = try ObjCMethodSignature<Result, repeat each Argument>(
            handle: handle,
            declaration: declaration,
            variadicFrom: variadicFrom
        )
        return (plan, prepared)
    }
}
