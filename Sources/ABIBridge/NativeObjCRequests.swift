import Foundation
import ObjectiveC

extension NativeRequest {
    /// Describes an Objective-C method called through ordinary message dispatch.
    ///
    /// Resolve on a ``NativeObject`` to bind its receiver, or with an `ABIRuntime`
    /// and class to take a receiver at each call.
    public static func objc<Result, each Argument>(
        _ declaration: NativeObjCMethodRequest<Result, repeat each Argument>
    ) -> Self where Declaration == NativeObjCMethodRequest<Result, repeat each Argument> {
        Self(declaration: declaration)
    }

    /// Describes an Objective-C implementation to capture during resolution.
    ///
    /// Resolve with an `ABIRuntime` and class for an unbound fixed IMP, or on
    /// a ``NativeObject`` to retain that receiver. Subsequent replacement
    /// does not change the captured implementation.
    public static func objc<Result, each Argument>(
        _ declaration: NativeObjCImplementationRequest<Result, repeat each Argument>
    ) -> Self where Declaration == NativeObjCImplementationRequest<Result, repeat each Argument> {
        Self(declaration: declaration)
    }
}

/// The selector, convention, and ownership of an Objective-C message request.
struct ObjCMessageQuery: Sendable {
    let selector: String
    /// The index of the first anonymous argument, for a variadic method.
    let variadicFrom: Int?
    /// Whether the method reports failure through a trailing `NSError **`
    /// parameter that the Swift signature omits.
    let reportsErrors: Bool
    let options: NativeObjCMethodOptions
}

/// An Objective-C message to prepare for calls.
///
/// Wrap the declaration with `NativeRequest.objc`, then resolve on a
/// ``NativeObject`` to get a ``NativeBoundObjCMethod`` for that receiver, or
/// with `ABIRuntime`'s `resolveAndWait(_:on:classMethod:retaining:)` to get a
/// ``NativeObjCMethod`` that takes its receiver at each call. Both send the
/// message through ordinary dispatch.
///
/// The signature describes explicit arguments, including any anonymous tail,
/// and the result, excluding the receiver and selector. For structures, the
/// method's encoding supplies the native layout; the caller guarantees
/// compatible Swift storage and ownership. See <doc:ObjectiveCInvocation>.
public struct NativeObjCMethodRequest<Result, each Argument>: Sendable {
    let query: ObjCMessageQuery

    init(_ query: ObjCMessageQuery) {
        self.query = query
    }

    /// Describes a message with an ordinary Swift function type.
    ///
    /// - Parameters:
    ///   - selector: The selector, including argument colons.
    ///   - signature: Explicit arguments and result.
    ///   - variadicFrom: The index of the first anonymous argument, or nil for
    ///     a fixed signature.
    ///   - options: Ownership overrides absent from runtime encodings.
    public static func method(
        _ selector: String,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int? = nil,
        options: NativeObjCMethodOptions = .init()
    ) -> Self {
        Self(
            .init(
                selector: selector,
                variadicFrom: variadicFrom,
                reportsErrors: false,
                options: options
            )
        )
    }

    /// Describes a message that reports failure through a trailing
    /// `NSError **` parameter.
    ///
    /// The signature omits that parameter and declares `throws`, as the Swift
    /// importer does for Cocoa methods. A `Void` result corresponds to a
    /// `BOOL` method that fails with `NO`; another result corresponds to an
    /// object method that fails with `nil`. Invocation supplies the error slot
    /// and throws the method's `NSError`, or ``NativeObjCUnreportedFailure``
    /// when it failed without one.
    /// Object results must be nonoptional; nil represents failure. Variadic
    /// arguments cannot be combined with this error convention.
    ///
    /// - Parameters:
    ///   - selector: The selector, including argument colons and the error
    ///     parameter's.
    ///   - signature: Explicit arguments without the error parameter, and the
    ///     result.
    ///   - options: Ownership overrides absent from runtime encodings.
    public static func method(
        _ selector: String,
        as signature: ((repeat each Argument) throws -> Result).Type,
        options: NativeObjCMethodOptions = .init()
    ) -> Self {
        Self(.init(selector: selector, variadicFrom: nil, reportsErrors: true, options: options))
    }

    /// Describes a message with an ordinary Swift function type, by its
    /// `Selector`.
    public static func method(
        _ selector: Selector,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int? = nil,
        options: NativeObjCMethodOptions = .init()
    ) -> Self {
        .method(
            NSStringFromSelector(selector),
            as: signature,
            variadicFrom: variadicFrom,
            options: options
        )
    }

    /// Describes a message that reports failure through a trailing
    /// `NSError **` parameter, by its `Selector`.
    public static func method(
        _ selector: Selector,
        as signature: ((repeat each Argument) throws -> Result).Type,
        options: NativeObjCMethodOptions = .init()
    ) -> Self {
        .method(NSStringFromSelector(selector), as: signature, options: options)
    }
}

/// An Objective-C implementation to capture from a class.
///
/// Wrap the declaration with `NativeRequest.objc`, then use `ABIRuntime`'s
/// `resolveAndWait(_:on:classMethod:retaining:)` to get a
/// ``NativeObjCImplementation``, which calls the IMP found during lookup
/// instead of sending the message. Dynamic method resolution may run during
/// lookup, but forwarding-only selectors cannot be captured.
public struct NativeObjCImplementationRequest<Result, each Argument>: Sendable {
    let query: ObjCMessageQuery

    init(_ query: ObjCMessageQuery) {
        self.query = query
    }

    /// Describes an implementation with an ordinary Swift function type.
    ///
    /// - Parameters:
    ///   - selector: The selector, including argument colons.
    ///   - signature: Explicit arguments and result.
    ///   - variadicFrom: The index of the first anonymous argument, or nil for
    ///     a fixed signature.
    ///   - options: Ownership overrides absent from runtime encodings.
    public static func imp(
        _ selector: String,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int? = nil,
        options: NativeObjCMethodOptions = .init()
    ) -> Self {
        Self(
            NativeObjCMethodRequest.method(
                selector,
                as: signature,
                variadicFrom: variadicFrom,
                options: options
            ).query
        )
    }

    /// Describes an implementation that reports failure through a trailing
    /// `NSError **` parameter, with the convention of a throwing
    /// ``NativeObjCMethodRequest``.
    public static func imp(
        _ selector: String,
        as signature: ((repeat each Argument) throws -> Result).Type,
        options: NativeObjCMethodOptions = .init()
    ) -> Self {
        Self(NativeObjCMethodRequest.method(selector, as: signature, options: options).query)
    }

    /// Describes an implementation with an ordinary Swift function type, by
    /// its `Selector`.
    public static func imp(
        _ selector: Selector,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int? = nil,
        options: NativeObjCMethodOptions = .init()
    ) -> Self {
        .imp(
            NSStringFromSelector(selector),
            as: signature,
            variadicFrom: variadicFrom,
            options: options
        )
    }

    /// Describes an implementation that reports failure through a trailing
    /// `NSError **` parameter, by its `Selector`.
    public static func imp(
        _ selector: Selector,
        as signature: ((repeat each Argument) throws -> Result).Type,
        options: NativeObjCMethodOptions = .init()
    ) -> Self {
        .imp(NSStringFromSelector(selector), as: signature, options: options)
    }
}
