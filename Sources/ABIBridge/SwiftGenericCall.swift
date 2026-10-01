import ABIBridgeCore
import Foundation

enum SwiftGenericArgument: Sendable { case concrete, parameter, closureResult }

protocol SwiftGenericResultClosure: SwiftClosureValue {
    static var resultType: Any.Type { get }
    static var parameterTypes: [Any.Type] { get }
    func encodeGenericResultClosure(retainingCode owner: Any?) throws -> NativeValueStorage
}

struct SwiftGenericCallPlan: Sendable {
    let metadata: UInt
    let arguments: [SwiftGenericArgument]
    let indirectResult: Bool

    init(name: String, substitution: Any.Type, parameters: [Any.Type], result: Any.Type) throws {
        func unsupported() -> ABIResolutionError {
            .unsupportedDeclaration("Generic calls require a complete synchronous free-function declaration with one unconstrained <A>; A may occur as an argument, result, or () -> A callback.")
        }
        guard let opening = name.firstIndex(of: "(") else { throw unsupported() }
        let head = String(name[..<opening]).trimmingCharacters(in: .whitespaces)
        guard head.hasSuffix("<A>"), head.dropLast(3).split(separator: ".").count == 2,
              !head.contains(where: \.isWhitespace), SwiftGenericSyntax.groups(in: head).count == 1 else { throw unsupported() }
        var depth = 0
        var closing: String.Index?
        for index in name[opening...].indices {
            if name[index] == "(" { depth += 1 }
            if name[index] == ")" { depth -= 1; if depth == 0 { closing = index; break } }
        }
        guard let closing else { throw unsupported() }
        let tail = name[name.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        guard tail.hasPrefix("->") else { throw unsupported() }
        let formalResult = tail.dropFirst(2).trimmingCharacters(in: .whitespaces)
        let contents = name[name.index(after: opening)..<closing]
        let fields = contents.trimmingCharacters(in: .whitespaces).isEmpty ? [] : SwiftGenericSyntax.split(contents)
        guard fields.count == parameters.count else {
            throw ABIResolutionError.signatureMismatch(.init(expected: "\(fields.count) generic arguments", found: ["\(parameters.count) typed arguments"]))
        }
        func mentionsParameter(_ text: String) -> Bool {
            SwiftGenericSyntax.names(in: text).contains { $0 == "A" || $0.hasPrefix("A.") }
        }
        func requireSubstitution(_ actual: Any.Type) throws {
            guard actual == substitution else {
                throw ABIResolutionError.signatureMismatch(.init(expected: String(reflecting: substitution), found: [String(reflecting: actual)]))
            }
            if actual is any ABIBridgeValue.Type, !(actual is any ABIBridgeSwiftValue.Type) {
                throw ABIResolutionError.unsupportedDeclaration("A generic substitution uses its actual Swift storage, not a foreign value conversion.")
            }
        }
        arguments = try zip(fields, parameters).map { field, actual in
            var formal = field.trimmingCharacters(in: .whitespaces)
            // A label's colon precedes any type group; dictionary/tuple colons do not.
            if let colon = formal.firstIndex(of: ":"), !formal[..<colon].contains(where: { "(<[".contains($0) }) {
                formal = formal[formal.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if formal == "A" { try requireSubstitution(actual); return .parameter }
            if mentionsParameter(formal) {
                guard formal.filter({ !$0.isWhitespace }) == "()->A",
                      let closure = actual as? any SwiftGenericResultClosure.Type,
                      closure.parameterTypes.isEmpty else { throw unsupported() }
                try requireSubstitution(closure.resultType)
                return .closureResult
            }
            return .concrete
        }
        if formalResult == "A" {
            try requireSubstitution(result)
            indirectResult = true
        } else {
            guard !mentionsParameter(formalResult) else { throw unsupported() }
            indirectResult = false
        }
        metadata = unsafeBitCast(substitution, to: UInt.self)
    }
}

extension ABIRuntime {
    /// Resolves a synchronous, nonthrowing free function with one unconstrained type parameter.
    ///
    /// Supply a complete source declaration using the demangler's parameter A,
    /// such as `Example.run<A>(() -> A) -> A`. A may occur directly as an
    /// argument/result or as the result of a zero-argument NativeSwiftClosure.
    /// Other positions use the existing concrete Swift representations. The
    /// concrete function-type metatype must agree with the explicit substitution.
    /// Protocol constraints, composed dependent types and additional effects are
    /// outside this subset. Use the retained-type overload for dynamically loaded
    /// substitution types whose implementation image needs an explicit owner.
    public func swiftFunction<Result, each Argument>(
        named name: String, as signature: ((repeat each Argument) -> Result).Type,
        substituting substitution: Any.Type,
        in scope: ImageSelector = .automatic, loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftFunction<Result, repeat each Argument> {
        try genericSwiftFunction(named: name, as: signature, substitution: substitution, owner: nil, in: scope, loading: loading)
    }

    /// Resolves a generic free function while retaining the substitution's type image.
    ///
    /// The supplied handle's actual metatype must match the typed signature at
    /// every occurrence of A. Calling conventions match the metatype overload.
    public func swiftFunction<Result, each Argument>(
        named name: String, as signature: ((repeat each Argument) -> Result).Type,
        substituting substitution: NativeSwiftType,
        in scope: ImageSelector = .automatic, loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftFunction<Result, repeat each Argument> {
        try genericSwiftFunction(named: name, as: signature, substitution: substitution.metadata, owner: substitution, in: scope, loading: loading)
    }

    private func genericSwiftFunction<Result, each Argument>(
        named name: String, as signature: ((repeat each Argument) -> Result).Type,
        substitution: Any.Type, owner: NativeSwiftType?, in scope: ImageSelector, loading: ImageLoadingPolicy
    ) throws -> NativeSwiftFunction<Result, repeat each Argument> {
        var parameters: [Any.Type] = []
        for type in repeat (each Argument).self { parameters.append(type) }
        let plan = try SwiftGenericCallPlan(name: name, substitution: substitution, parameters: parameters, result: Result.self)
        return try NativeSwiftFunction(symbol: resolve(.init(name: name, language: .swift), in: scope, loading: loading),
            owner: owner, resolver: resolver, generic: plan)
    }
}
