import Foundation
import ObjectiveC

/// The selector, convention, and ownership of an Objective-C message request.
struct ObjCMessageQuery: Sendable {
    let selector: String
    /// The index of the first anonymous argument, for a variadic method.
    let variadicFrom: Int?
    /// Whether the method reports failure through a trailing `NSError **`
    /// parameter that the Swift signature omits.
    let reportsErrors: Bool
    let options: NativeMethodOptions
}

/// An Objective-C message to prepare for calls.
///
/// Resolve a request on a ``NativeObject`` to get a ``NativeBoundObjCMethod``
/// for that receiver, or with `ABIRuntime`'s `resolveAndWait(_:on:classMethod:retaining:)`
/// to get a ``NativeObjCMethod`` that takes its receiver at each call. Both
/// send the message through ordinary dispatch.
///
/// The signature describes explicit arguments, including any anonymous tail,
/// and the result, excluding the receiver and selector. For structures, the
/// method's encoding supplies the native layout; the caller guarantees
/// compatible Swift storage and ownership. See <doc:ObjectiveCInvocation>.
public struct NativeObjCMessageRequest<Result, each Argument>: Sendable {
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
    public static func message(
        _ selector: String,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int? = nil,
        options: NativeMethodOptions = .init()
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
    ///
    /// - Parameters:
    ///   - selector: The selector, including argument colons and the error
    ///     parameter's.
    ///   - signature: Explicit arguments without the error parameter, and the
    ///     result.
    ///   - options: Ownership overrides absent from runtime encodings.
    public static func message(
        _ selector: String,
        as signature: ((repeat each Argument) throws -> Result).Type,
        options: NativeMethodOptions = .init()
    ) -> Self {
        Self(.init(selector: selector, variadicFrom: nil, reportsErrors: true, options: options))
    }

    /// Describes a message with an ordinary Swift function type, by its
    /// `Selector`.
    public static func message(
        _ selector: Selector,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int? = nil,
        options: NativeMethodOptions = .init()
    ) -> Self {
        .message(
            NSStringFromSelector(selector),
            as: signature,
            variadicFrom: variadicFrom,
            options: options
        )
    }

    /// Describes a message that reports failure through a trailing
    /// `NSError **` parameter, by its `Selector`.
    public static func message(
        _ selector: Selector,
        as signature: ((repeat each Argument) throws -> Result).Type,
        options: NativeMethodOptions = .init()
    ) -> Self {
        .message(NSStringFromSelector(selector), as: signature, options: options)
    }
}

/// An Objective-C implementation to capture from a class.
///
/// Resolve a request with `ABIRuntime`'s `resolveAndWait(_:on:classMethod:retaining:)`
/// to get a ``NativeObjCImplementation``, which calls the IMP found during
/// lookup instead of sending the message. Dynamic method resolution may run
/// during lookup, but forwarding-only selectors cannot be captured.
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
    public static func implementation(
        _ selector: String,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int? = nil,
        options: NativeMethodOptions = .init()
    ) -> Self {
        Self(
            NativeObjCMessageRequest.message(
                selector,
                as: signature,
                variadicFrom: variadicFrom,
                options: options
            ).query
        )
    }

    /// Describes an implementation that reports failure through a trailing
    /// `NSError **` parameter, with the convention of a throwing
    /// ``NativeObjCMessageRequest``.
    public static func implementation(
        _ selector: String,
        as signature: ((repeat each Argument) throws -> Result).Type,
        options: NativeMethodOptions = .init()
    ) -> Self {
        Self(NativeObjCMessageRequest.message(selector, as: signature, options: options).query)
    }

    /// Describes an implementation with an ordinary Swift function type, by
    /// its `Selector`.
    public static func implementation(
        _ selector: Selector,
        as signature: ((repeat each Argument) -> Result).Type,
        variadicFrom: Int? = nil,
        options: NativeMethodOptions = .init()
    ) -> Self {
        .implementation(
            NSStringFromSelector(selector),
            as: signature,
            variadicFrom: variadicFrom,
            options: options
        )
    }

    /// Describes an implementation that reports failure through a trailing
    /// `NSError **` parameter, by its `Selector`.
    public static func implementation(
        _ selector: Selector,
        as signature: ((repeat each Argument) throws -> Result).Type,
        options: NativeMethodOptions = .init()
    ) -> Self {
        .implementation(NSStringFromSelector(selector), as: signature, options: options)
    }
}
