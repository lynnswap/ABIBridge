import Foundation
import ObjectiveC

extension NativeObject {
    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    public func method<Result, each Argument>(
        selector: Selector,
        as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init()
    ) throws -> NativeBoundObjCMethod<Result, repeat each Argument> {
        try method(selector: NSStringFromSelector(selector), as: signature, options: options)
    }

    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    @unsafe public func hookMethod<Result, each Argument>(
        selector: Selector, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) throws -> NativeObjCMethodHook {
        try unsafe hookMethod(selector: NSStringFromSelector(selector), as: signature, options: options, retaining: owner, onFailure: onFailure, body: body)
    }

    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    @unsafe @MainActor public func hookMainActorMethod<Result, each Argument>(
        selector: Selector, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @MainActor @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) throws -> NativeObjCMethodHook {
        try unsafe hookMainActorMethod(selector: NSStringFromSelector(selector), as: signature, options: options, retaining: owner, onFailure: onFailure, body: body)
    }
}

extension ABIRuntime {
    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    public nonisolated func objcMethod<Result, each Argument>(
        on type: AnyClass, selector: Selector,
        as signature: ((repeat each Argument) -> Result).Type,
        classMethod: Bool = false, options: NativeMethodOptions = .init(),
        retaining owner: Any? = nil
    ) throws -> NativeObjCMethod<Result, repeat each Argument> {
        try objcMethod(on: type, selector: NSStringFromSelector(selector), as: signature, classMethod: classMethod, options: options, retaining: owner)
    }

    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    public nonisolated func objcImplementation<Result, each Argument>(
        on type: AnyClass, selector: Selector,
        as signature: ((repeat each Argument) -> Result).Type,
        classMethod: Bool = false, options: NativeMethodOptions = .init(),
        retaining owner: Any? = nil
    ) throws -> NativeObjCImplementation<Result, repeat each Argument> {
        try objcImplementation(on: type, selector: NSStringFromSelector(selector), as: signature, classMethod: classMethod, options: options, retaining: owner)
    }

    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    @unsafe public nonisolated func hookInitializer<Result, each Argument>(
        on type: AnyClass, selector: Selector, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        transformingArguments: (@Sendable (repeat each Argument) throws -> (repeat each Argument))? = nil,
        before: (@Sendable (repeat each Argument) throws -> Void)? = nil,
        after: @escaping @Sendable (Result) throws -> Void = { _ in }
    ) throws -> NativeObjCMethodHook {
        try unsafe hookInitializer(on: type, selector: NSStringFromSelector(selector), as: signature, options: options, retaining: owner, onFailure: onFailure, transformingArguments: transformingArguments, before: before, after: after)
    }

    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    @unsafe @MainActor public func hookMainActorInitializer<Result, each Argument>(
        on type: AnyClass, selector: Selector, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        transformingArguments: (@MainActor @Sendable (repeat each Argument) throws -> (repeat each Argument))? = nil,
        before: (@MainActor @Sendable (repeat each Argument) throws -> Void)? = nil,
        after: @escaping @MainActor @Sendable (Result) throws -> Void = { _ in }
    ) throws -> NativeObjCMethodHook {
        try unsafe hookMainActorInitializer(on: type, selector: NSStringFromSelector(selector), as: signature, options: options, retaining: owner, onFailure: onFailure, transformingArguments: transformingArguments, before: before, after: after)
    }

    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    @unsafe public nonisolated func hookMethod<Result, each Argument>(
        on type: AnyClass, selector: Selector, as signature: ((repeat each Argument) -> Result).Type,
        classMethod: Bool = false, options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) throws -> NativeObjCMethodHook {
        try unsafe hookMethod(on: type, selector: NSStringFromSelector(selector), as: signature, classMethod: classMethod, options: options, retaining: owner, onFailure: onFailure, body: body)
    }

    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    @unsafe @MainActor public func hookMainActorMethod<Result, each Argument>(
        on type: AnyClass, selector: Selector, as signature: ((repeat each Argument) -> Result).Type,
        classMethod: Bool = false, options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @MainActor @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) throws -> NativeObjCMethodHook {
        try unsafe hookMainActorMethod(on: type, selector: NSStringFromSelector(selector), as: signature, classMethod: classMethod, options: options, retaining: owner, onFailure: onFailure, body: body)
    }
}

extension NativeObjCHookRequest {
    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    @unsafe public static func method<Result, each Argument>(
        on type: AnyClass, selector: Selector, as signature: ((repeat each Argument) -> Result).Type,
        classMethod: Bool = false, options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) -> Self {
        unsafe method(on: type, selector: NSStringFromSelector(selector), as: signature, classMethod: classMethod, options: options, retaining: owner, onFailure: onFailure, body: body)
    }

    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    @unsafe public static func initializer<Result, each Argument>(
        on type: AnyClass, selector: Selector, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        transformingArguments: (@Sendable (repeat each Argument) throws -> (repeat each Argument))? = nil,
        before: (@Sendable (repeat each Argument) throws -> Void)? = nil,
        after: @escaping @Sendable (Result) throws -> Void = { _ in }
    ) -> Self {
        unsafe initializer(on: type, selector: NSStringFromSelector(selector), as: signature, options: options, retaining: owner, onFailure: onFailure, transformingArguments: transformingArguments, before: before, after: after)
    }

    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    @unsafe public static func objectMethod<Result, each Argument>(
        on object: AnyObject, selector: Selector, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) -> Self {
        unsafe objectMethod(on: object, selector: NSStringFromSelector(selector), as: signature, options: options, retaining: owner, onFailure: onFailure, body: body)
    }

    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    @unsafe @MainActor public static func mainActorMethod<Result, each Argument>(
        on type: AnyClass, selector: Selector, as signature: ((repeat each Argument) -> Result).Type,
        classMethod: Bool = false, options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @MainActor @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) -> Self {
        unsafe mainActorMethod(on: type, selector: NSStringFromSelector(selector), as: signature, classMethod: classMethod, options: options, retaining: owner, onFailure: onFailure, body: body)
    }

    /// Accepts a Selector with the same dispatch, ownership, and isolation contract.
    @unsafe @MainActor public static func mainActorInitializer<Result, each Argument>(
        on type: AnyClass, selector: Selector, as signature: ((repeat each Argument) -> Result).Type,
        options: NativeMethodOptions = .init(), retaining owner: Any? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        transformingArguments: (@MainActor @Sendable (repeat each Argument) throws -> (repeat each Argument))? = nil,
        before: (@MainActor @Sendable (repeat each Argument) throws -> Void)? = nil,
        after: @escaping @MainActor @Sendable (Result) throws -> Void = { _ in }
    ) -> Self {
        unsafe mainActorInitializer(on: type, selector: NSStringFromSelector(selector), as: signature, options: options, retaining: owner, onFailure: onFailure, transformingArguments: transformingArguments, before: before, after: after)
    }
}

