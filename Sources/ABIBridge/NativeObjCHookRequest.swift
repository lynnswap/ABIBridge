import ABIBridgeObjCXX
import Foundation
import ObjectiveC

struct ObjCHookValidation {
    struct Key: Hashable { let type: ObjectIdentifier; let selector: String }
    let key: Key
    let retained: Bool
    let consumed: Bool
    let binding: ObjCInvocationBinding
    let interface: CCallInterface
}

extension NativeObjCMethodHook {
    static func validation<Result, each Argument>(
        type: AnyClass, selector: String, signature: ((repeat each Argument) -> Result).Type,
        classMethod: Bool, options: NativeMethodOptions, initializer: Bool
    ) throws -> ObjCHookValidation {
        guard !selector.utf8.contains(0) else {
            throw ABIResolutionError.unsupportedDeclaration("A selector cannot contain a NUL byte.")
        }
        let sel = NSSelectorFromString(selector)
        var error: NSError?
        guard let raw = ABICopyObjCImplementation(type, sel, classMethod,
            options.returnsRetainedObject.map { $0 ? 1 : 0 } ?? -1,
            options.consumesReceiver.map { $0 ? 1 : 0 } ?? -1, &error) else {
            if ABIObjCMethodHookIsDisplaced(type, sel, classMethod) { throw NativeObjCMethodHookError.displaced }
            throw error ?? ABIResolutionError.metadataUnavailable(selector) as NSError
        }
        let binding = ObjCInvocationBinding(raw)
        let value = try ObjCMethodSignature<Result, repeat each Argument>(handle: raw)
        let interface = try value.callInterface()
        guard ABIValidateObjCMethodHook(type, sel, classMethod, initializer, raw, nil, &error) else {
            switch error?.code {
            case 1: throw NativeObjCMethodHookError.displaced
            case 2: throw NativeObjCMethodHookError.unsupportedMethod
            case 3: throw NativeObjCMethodHookError.incompatibleContract
            default: throw error ?? ABIResolutionError.invalidAddress as NSError
            }
        }
        return ObjCHookValidation(key: .init(type: ObjectIdentifier(classMethod ? object_getClass(type)! : type), selector: selector),
            retained: ABIObjCInvocationReturnsRetained(raw), consumed: ABIObjCInvocationConsumesReceiver(raw), binding: binding, interface: interface)
    }
}

/// A declaration for coordinated Objective-C hook installation.
///
/// Creating a request does not publish an IMP. Requests retain their declaration
/// inputs and callbacks; release them when they are no longer needed. A request
/// can be reused. Single hooks can still be installed directly on `ABIRuntime`.
public struct NativeObjCHookRequest {
    let validate: () throws -> ObjCHookValidation
    let install: (ABIRuntime) throws -> NativeObjCMethodHook

    /// Describes an ordinary method hook using the direct installation contract.
    ///
    /// - Parameters:
    ///   - type: The requested class.
    ///   - selector: The Objective-C selector, including colons.
    ///   - signature: Explicit argument and result types.
    ///   - classMethod: Whether this describes a metaclass method.
    ///   - options: Declaration ownership overrides.
    ///   - owner: Optional lifetime owner for the first published fallback.
    ///   - onFailure: Synchronous callback/conversion error handler.
    ///   - body: The typed callback and scoped continuation.
    @unsafe public static func method<Result, each Argument>(
        on type: AnyClass, selector: String, as signature: ((repeat each Argument) -> Result).Type,
        classMethod: Bool = false, options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) -> Self {
        Self(validate: {
            try NativeObjCMethodHook.validation(type: type, selector: selector, signature: signature,
                classMethod: classMethod, options: options, initializer: false)
        }, install: { runtime in
            try unsafe runtime.hookMethod(on: type, selector: selector, as: signature,
                classMethod: classMethod, options: options, retaining: owner, onFailure: onFailure, body: body)
        })
    }

    /// Describes dedicated initializer preparation and postprocessing.
    /// Parameters and unsafe requirements match `ABIRuntime.hookInitializer`.
    @unsafe public static func initializer<Result, each Argument>(
        on type: AnyClass, selector: String, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        transformingArguments: (@Sendable (repeat each Argument) throws -> (repeat each Argument))? = nil,
        before: (@Sendable (repeat each Argument) throws -> Void)? = nil,
        after: @escaping @Sendable (Result) throws -> Void = { _ in }
    ) -> Self {
        Self(validate: {
            try NativeObjCMethodHook.validation(type: type, selector: selector, signature: signature,
                classMethod: false, options: options, initializer: true)
        }, install: { runtime in
            try unsafe runtime.hookInitializer(on: type, selector: selector, as: signature,
                options: options, retaining: owner, onFailure: onFailure,
                transformingArguments: transformingArguments, before: before, after: after)
        })
    }
    /// Describes a weak identity-filtered ordinary instance hook.
    /// The request retains its object until the request is released; the installed
    /// registration itself uses weak identity, just like `NativeObject.hookMethod`.
    @unsafe public static func objectMethod<Result, each Argument>(
        on object: AnyObject, selector: String, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) -> Self {
        Self(validate: {
            try NativeObjCMethodHook.validation(type: object_getClass(object)!, selector: selector, signature: signature,
                classMethod: false, options: options, initializer: false)
        }, install: { runtime in
            try unsafe runtime.object(object).hookMethod(selector: selector, as: signature,
                options: options, retaining: owner, onFailure: onFailure, body: body)
        })
    }

    /// Describes a method callback with the direct MainActor-hook contract.
    /// Preparation itself does not execute the callback or infer future isolation.
    @unsafe @MainActor public static func mainActorMethod<Result, each Argument>(
        on type: AnyClass, selector: String, as signature: ((repeat each Argument) -> Result).Type,
        classMethod: Bool = false, options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @MainActor @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) -> Self {
        Self(validate: {
            try NativeObjCMethodHook.validation(type: type, selector: selector, signature: signature,
                classMethod: classMethod, options: options, initializer: false)
        }, install: { _ in
            try NativeObjCMethodHook.prepare(on: type, selector: selector, as: signature,
                classMethod: classMethod, options: options, object: nil, owner: owner, initializer: false) { signature in
                    ObjCReplacement<Result, repeat each Argument>.mainActorCallback(signature, onFailure: onFailure, body: body)
                }
        })
    }

    /// Describes initializer phases with the direct MainActor-initializer contract.
    @unsafe @MainActor public static func mainActorInitializer<Result, each Argument>(
        on type: AnyClass, selector: String, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        transformingArguments: (@MainActor @Sendable (repeat each Argument) throws -> (repeat each Argument))? = nil,
        before: (@MainActor @Sendable (repeat each Argument) throws -> Void)? = nil,
        after: @escaping @MainActor @Sendable (Result) throws -> Void = { _ in }
    ) -> Self {
        Self(validate: {
            try NativeObjCMethodHook.validation(type: type, selector: selector, signature: signature,
                classMethod: false, options: options, initializer: true)
        }, install: { _ in
            try NativeObjCMethodHook.prepare(on: type, selector: selector, as: signature,
                classMethod: false, options: options, object: nil, owner: owner, initializer: true) { signature in
                    ObjCReplacement<Result, repeat each Argument>.mainActorInitializerCallback(signature,
                        onFailure: onFailure, transformingArguments: transformingArguments, before: before, after: after)
                }
        })
    }

}

/// Failure of a coordinated Objective-C hook installation.
public struct NativeObjCHookInstallationError: Error {
    /// Preparation publishes nothing. Activation revalidates and installs in order.
    public enum Phase: Sendable { case preparation, activation }
    /// Zero-based index in the original request array.
    public let failedIndex: Int
    /// The phase that failed.
    public let phase: Phase
    /// The original lookup, declaration, ownership, or installation failure.
    public let underlyingError: any Error
    /// Earlier registrations created by this operation, already invalidated.
    /// Their status remains readable. Published dispatchers and subclass-local
    /// pass-through method entries may remain; rollback is logical, not structural.
    public let invalidatedHooks: [NativeObjCMethodHook]
}

extension ABIRuntime {
    /// Validates all Objective-C requests, then installs them in array order.
    ///
    /// Returns ordinary owning handles. Release the array or invalidate its
    /// elements to remove registrations; retained aliases follow normal handle
    /// ownership. Empty input returns an empty array.
    ///
    /// Activation revalidates current predecessors, so superclass/subclass
    /// requests may appear in either order. Visibility is not atomic across
    /// methods. If activation fails, only registrations added by this operation
    /// are invalidated. Other hooks and external IMPs are preserved.
    ///
    /// - Parameter requests: Typed ordinary-method and initializer declarations.
    /// - Returns: Handles in request order, each independently inspectable.
    /// - Throws: `NativeObjCHookInstallationError` with the original cause,
    ///   failed index, phase, and any invalidated partial registrations.
    ///
    /// Per-request unsafe ownership/lifetime contracts and external-writer
    /// coordination still apply. See <doc:CoordinatedObjectiveCHooks>.
    @unsafe public nonisolated func installHooks(_ requests: [NativeObjCHookRequest]) throws -> [NativeObjCMethodHook] {
        var validations: [ObjCHookValidation] = []
        var contracts: [ObjCHookValidation.Key: (retained: Bool, consumed: Bool)] = [:]
        for (index, request) in requests.enumerated() {
            do {
                let value = try request.validate()
                if let previous = contracts[value.key], previous.retained != value.retained || previous.consumed != value.consumed {
                    throw NativeObjCMethodHookError.incompatibleContract
                }
                contracts[value.key] = (value.retained, value.consumed)
                validations.append(value)
            } catch {
                throw NativeObjCHookInstallationError(failedIndex: index, phase: .preparation, underlyingError: error, invalidatedHooks: [])
            }
        }
        return try withExtendedLifetime(validations) {
            var handles: [NativeObjCMethodHook] = []
            for (index, request) in requests.enumerated() {
                do { handles.append(try request.install(self)) }
                catch {
                    for handle in handles.reversed() { handle.invalidate() }
                    throw NativeObjCHookInstallationError(failedIndex: index, phase: .activation, underlyingError: error, invalidatedHooks: handles)
                }
            }
            return handles
        }
    }
}
