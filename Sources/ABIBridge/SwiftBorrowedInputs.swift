import ABIBridgeCore
import ABIBridgeRuntime
import Foundation

/// Plans inputs from the result dependencies stated by the caller, or checks
/// that missing dependencies cannot change their conventions.
///
/// Swift passes an input that a result has a scoped (`borrow`) dependency
/// on by address when its type sets the addressable-for-dependencies bit,
/// and a tuple then as one address instead of its elements. A `copy`
/// dependency changes nothing. No record shows which inputs a result depends
/// on: a function's mangled name, a closure's mangled function type, and
/// function type metadata omit lifetime dependencies. `declaredAs:` can state
/// them. Without that information, a call whose declared result can be
/// nonescapable therefore passes an input
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
    enum Input: Sendable, Hashable {
        /// A zero-based explicit argument.
        case argument(Int)
        case receiver
    }

    static func parse(
        _ attributes: [String],
        parameters: [String]
    ) throws -> (borrowed: Set<Input>, requiresReceiver: Bool) {
        let names = parameters.map { field -> String? in
            guard let colon = SwiftFormalSyntax.topLevelColon(in: field) else { return nil }
            return field[..<colon].split(whereSeparator: \.isWhitespace).last.map(String.init)
        }
        var result: Set<Input> = []
        var requiresReceiver = false
        for attribute in attributes {
            for field in SwiftFormalSyntax.fields(attribute[...]) {
                let source = field.trimmingCharacters(in: .whitespaces)
                if source == "immortal" { continue }
                let name: String
                let borrowing: Bool
                if source.hasPrefix("borrow ") {
                    name = String(source.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    borrowing = true
                } else if source.hasPrefix("copy ") {
                    name = String(source.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    borrowing = false
                } else if source.hasPrefix("&") {
                    name = String(source.dropFirst()).trimmingCharacters(in: .whitespaces)
                    borrowing = false
                } else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "declaredAs: requires a result dependency spelled borrow name, copy name, &name, or immortal: "
                            + source
                    )
                }
                let input: Input
                if name == "self" {
                    input = .receiver
                    requiresReceiver = true
                } else if name != "_", let index = names.firstIndex(where: { $0 == name }) {
                    input = .argument(index)
                } else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "Unknown @_lifetime input in declaredAs: " + name
                    )
                }
                if borrowing { result.insert(input) }
            }
            guard !attribute.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ABIResolutionError.unsupportedDeclaration("Empty @_lifetime in declaredAs:.")
            }
        }
        return (result, requiresReceiver)
    }

    /// Whether a stated borrow changes a directly passed input to one
    /// address. Missing dependency information requires an unchanged ABI.
    ///
    /// - Parameters:
    ///   - addressability: Whether the input's native type sets the bit.
    ///   - type: The input's native type, or its host type when nothing
    ///     names the native type.
    ///   - tuple: Whether ABIBridge passes the input's elements separately.
    static func passesByAddress(
        _ addressability: SwiftInferredValue.Addressability,
        of type: Any.Type,
        input: Input,
        tuple: Bool,
        borrowed: Bool? = nil
    ) throws -> Bool {
        if borrowed == false { return false }
        let detail: String
        switch addressability {
        case .clear: return false
        case .sets where borrowed == true: return true
        case .sets(let reason): detail = reason
        case .unknown(let reason): detail = "nothing shows whether it does: " + reason
        }
        let subject =
            switch input {
            case .argument(let index): "argument \(index)"
            case .receiver: "self"
            }
        if borrowed == true {
            throw ABIResolutionError.metadataUnavailable(
                "The declared result borrows \(subject) of type \(String(reflecting: type)), but ABIBridge cannot decide its addressable-for-dependencies bit: \(detail). State a type whose declaration establishes that bit or call through a compiled adapter."
            )
        }
        throw ABIResolutionError.metadataUnavailable(
            "Cannot decide how Swift passes \(subject) of type \(String(reflecting: type)), because the call's result can borrow from it. Swift passes an input that a result borrows from by address when its type sets the addressable-for-dependencies bit"
                + (tuple ? ", even a tuple, whose elements ABIBridge passes separately" : "")
                + ", and \(detail). No symbol or metadata records which inputs a result borrows from. State the result dependencies with declaredAs:, or call the declaration through a compiled adapter."
        )
    }

    /// Whether a directly passed argument needs one address, considering
    /// its declaration's generic abstraction rather than only its bound type.
    ///
    /// - Parameters:
    ///   - formal: The argument's type in the selected declaration, which
    ///     names the native type behind an adapter, and decides a tuple's
    ///     abstraction when it depends on generic parameters.
    ///   - binding: The declaration's generic binding.
    static func argumentPassesByAddress(
        _ index: Int,
        conversion: SwiftHostConversion,
        formal: SwiftFormalType?,
        binding: SwiftGenericBinding?,
        borrowed: Bool? = nil
    ) throws -> Bool {
        if borrowed == false { return false }
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
                    return try passesByAddress(
                        try addressability(of: formal, native: native, binding: binding),
                        of: native ?? conversion.host,
                        input: .argument(index),
                        tuple: true,
                        borrowed: borrowed
                    )
                }
            } else if let declared = try? binding.types(formal).first {
                native = declared
            }
        }
        guard let native else {
            return try passesByAddress(
                .unknown(
                    "`\(String(reflecting: conversion.host))` is or holds an adapter, and no declaration names the native type it represents"
                ),
                of: conversion.host,
                input: .argument(index),
                tuple: tuple,
                borrowed: borrowed
            )
        }
        return try passesByAddress(
            SwiftInferredValue.addressability(of: native),
            of: native,
            input: .argument(index),
            tuple: tuple,
            borrowed: borrowed
        )
    }

    /// A tuple uses the declaration's abstraction before generic substitution.
    static func addressability(
        of formal: SwiftFormalType,
        native: Any.Type?,
        binding: SwiftGenericBinding
    ) throws -> SwiftInferredValue.Addressability {
        let formal = try binding.canonicalType(of: formal)
        if binding.isArchetype(formal) {
            return try binding.isClassBound(formal)
                ? .clear
                : .sets("its declaration has an unconstrained type parameter")
        }
        if case .pack(let pattern, _) = formal {
            return try addressability(of: pattern, native: nil, binding: binding)
        }
        if case .tuple(let fields, _) = formal {
            let values = try fields.map { field in
                try addressability(
                    of: field,
                    native: try? binding.types(field)[0],
                    binding: binding
                )
            }
            if let sets = values.first(where: { if case .sets = $0 { true } else { false } }) {
                return sets
            }
            if let unknown = values.first(where: { if case .unknown = $0 { true } else { false } })
            {
                return unknown
            }
            return .clear
        }
        switch formal {
        case .objectiveCClass, .function, .foreignFunction, .metatype, .existentialMetatype,
            .constrainedExistential:
            return .clear
        default: break
        }
        if let native,
            native is AnyClass || native is any SwiftCollectionValue.Type
                || native is any NativePointerValue.Type
        {
            return .clear
        }
        if binding.dependsOnParameters(formal) {
            return .unknown("its declared abstraction depends on generic parameters")
        }
        guard let native else { return .unknown("no declaration names its native type") }
        return SwiftInferredValue.addressability(of: native)
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
