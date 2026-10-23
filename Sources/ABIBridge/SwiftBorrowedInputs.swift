import ABIBridgeCore

/// Checks the inputs of a call whose result can borrow from them.
///
/// Swift passes an input that a result has a scoped (`borrow`) dependency
/// on by address when its type sets the addressable-for-dependencies bit,
/// and a tuple then as one address instead of its elements. A `copy`
/// dependency changes nothing. No record shows which inputs a result depends
/// on: a function's mangled name, a closure's mangled function type, and
/// function type metadata omit lifetime dependencies. In a call with a
/// ``NativeSwiftBorrowedValue`` result, ABIBridge therefore passes an input
/// only where Swift passes it alike whether or not the result borrows from
/// it:
///
/// - Swift rejects a borrow dependency on a consuming input, and passes an
///   inout input by address either way.
/// - A value that already passes as one address, because it is address-only
///   or too large for registers, passes so either way, and so does an element
///   of a parameter pack, which passes through a buffer of addresses.
/// - A value whose type leaves the bit clear passes alike either way.
///
/// Any other input is undecided, and preparation names its type and why its
/// type sets the bit, or what does not show whether it does.
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/SIL/IR/SILFunctionType.cpp
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/AST/ASTMangler.cpp
enum SwiftBorrowedInputs {
    enum Input {
        /// A zero-based explicit argument.
        case argument(Int)
        case receiver
    }

    /// Requires that a borrowed input that ABIBridge passes directly passes
    /// so whether or not the call's result borrows from it.
    ///
    /// - Parameters:
    ///   - addressability: Whether the input's native type sets the bit.
    ///   - type: The input's native type, or its host type when nothing
    ///     names the native type.
    ///   - tuple: Whether ABIBridge passes the input's elements separately.
    static func require(
        _ addressability: SwiftInferredValue.Addressability,
        of type: Any.Type,
        input: Input,
        tuple: Bool
    ) throws {
        let detail: String
        switch addressability {
        case .clear: return
        case .sets(let reason): detail = reason
        case .unknown(let reason): detail = "nothing shows whether it does: " + reason
        }
        let subject =
            switch input {
            case .argument(let index): "argument \(index)"
            case .receiver: "self"
            }
        throw ABIResolutionError.metadataUnavailable(
            "Cannot decide how Swift passes \(subject) of type \(String(reflecting: type)), because the call's result can borrow from it. Swift passes an input that a result borrows from by address when its type sets the addressable-for-dependencies bit"
                + (tuple ? ", even a tuple, whose elements ABIBridge passes separately" : "")
                + ", and \(detail). No symbol or metadata records which inputs a result borrows from. Call the declaration through a compiled adapter."
        )
    }

    /// Requires that a borrowed argument that `conversion` passes directly,
    /// a whole value or a tuple's elements, passes so whether or not the
    /// call's result borrows from it.
    ///
    /// - Parameters:
    ///   - formal: The argument's type in the selected declaration, which
    ///     names the native type behind an adapter, and decides a tuple's
    ///     abstraction when it depends on generic parameters.
    ///   - binding: The declaration's generic binding.
    static func requireArgument(
        _ index: Int,
        conversion: SwiftHostConversion,
        formal: SwiftFormalType?,
        binding: SwiftGenericBinding?
    ) throws {
        let tuple = conversion.tuple != nil
        var native = nativeType(of: conversion)
        var formal = formal
        if case .borrowing(let value) = formal { formal = value }
        if let formal, let binding {
            if binding.dependsOnParameters(formal) {
                // Swift lowers such a tuple at the declaration's abstraction,
                // where an element of a type parameter that is not
                // class-bound sets the bit whatever its argument.
                if tuple {
                    return try require(
                        .unknown(
                            "its declared type depends on generic parameters, and ABIBridge does not decide whether Swift's lowering of that abstraction sets the bit"
                        ),
                        of: native ?? conversion.host,
                        input: .argument(index),
                        tuple: true
                    )
                }
            } else if let declared = try? binding.types(formal).first {
                native = declared
            }
        }
        guard let native else {
            return try require(
                .unknown(
                    "`\(String(reflecting: conversion.host))` is or holds an adapter, and no declaration names the native type it represents"
                ),
                of: conversion.host,
                input: .argument(index),
                tuple: tuple
            )
        }
        try require(
            SwiftInferredValue.addressability(of: native),
            of: native,
            input: .argument(index),
            tuple: tuple
        )
    }

    /// The native type that `conversion` passes, or nil when an adapter's
    /// representation stands for a native type that it does not name.
    private static func nativeType(of conversion: SwiftHostConversion) -> Any.Type? {
        switch conversion.kind {
        case .adapter: nil
        case .tuple(let plan): plan.hasAdapters ? nil : plan.nativeMetadata
        case .ownership(_, let value): nativeType(of: value)
        default: try? conversion.nativeType()
        }
    }
}
