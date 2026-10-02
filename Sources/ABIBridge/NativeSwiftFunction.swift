import ABIBridgeCore
import Synchronization

func swiftFunctionTypeName(_ type: Any.Type) throws -> String {
    if type == NativeSwiftOpaqueValue.self { return "some" }
    if let closure = type as? any SwiftClosureValue.Type {
        guard !closure.requiresExplicitDeclaration else {
            throw ABIResolutionError.unsupportedDeclaration("Runtime-typed callbacks require a complete source-level declaration.")
        }
        return try swiftFunctionTypeName(closure.swiftFunctionType)
    }
    return try swiftNativeTypeName(type)
}

func swiftNativeTypeName(_ type: Any.Type) throws -> String {
    // Objective-C metatypes can print an unqualified runtime name (NSString),
    // while Swift declarations use their imported identity (__C.NSString).
    guard let mangled = _mangledTypeName(type),
          let name = DeclarationKey.demangle("$s" + mangled, language: .swift) else {
        throw ABIResolutionError.metadataUnavailable("No canonical Swift name for \(String(reflecting: type)).")
    }
    return name
}

func swiftFunctionDeclaration<Signature>(
    named name: String, as signature: Signature.Type,
    resultName: String? = nil, defaultConsuming: Bool = false
) throws -> NativeDeclaration {
    let description = try SwiftFunctionSignature(signature)
    return try swiftFunctionDeclaration(named: name, parameterTypes: description.parameters, resultType: description.result,
        failureType: description.failure, isAsync: description.isAsync, resultName: resultName, defaultConsuming: defaultConsuming)
}

func swiftFunctionDeclaration(
    named name: String, parameterTypes: [Any.Type], resultType: Any.Type,
    failureType: Any.Type, isAsync: Bool, resultName: String? = nil, defaultConsuming: Bool = false
) throws -> NativeDeclaration {
    let throwing = failureType == Never.self ? "" : failureType == (any Error).self
        ? " throws" : " throws(" + (try swiftFunctionTypeName(failureType)) + ")"
    let effects = (isAsync ? " async" : "") + throwing
    var declaration = name
    // A full demangled declaration is useful when a foreign wrapper's Swift
    // type name differs from the native type. Label-only names infer types.
    if !name.contains("->"), name.last == ")", let opening = name.lastIndex(of: "(") {
        let text = name[name.index(after: opening)..<name.index(before: name.endIndex)]
        let labels = text.split(separator: ":").map(String.init)
        let labelsOnly = text.isEmpty || (text.last == ":" && labels.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        })
        if labelsOnly {
            let parameters = try parameterTypes.map { try swiftArgumentTypeName($0, defaultConsuming: defaultConsuming) }
            guard labels.count == parameters.count else {
                throw ABIResolutionError.signatureMismatch(.init(
                    expected: "\(parameters.count) argument labels", found: [name]
                ))
            }
            let omitLabels = labels.allSatisfy { $0 == "_" }
            let fields = zip(labels, parameters).map { label, type in omitLabels ? type : label + ": " + type }
            declaration = String(name[..<opening]) + "(" + fields.joined(separator: ", ") + ")" + effects + " -> " + (try resultName ?? swiftFunctionTypeName(resultType))
        }
    }
    let outerSignature = swiftOuterSignature(declaration).text
    // Effects are trailing words after the parameter list. A module called
    // async or throws inside a generic requirement is part of the type name.
    var words = outerSignature.split(whereSeparator: \.isWhitespace)
    var effectWords: [Substring] = []
    while let last = words.last, last == "async" || last == "throws" {
        effectWords.append(words.removeLast())
    }
    let prefix = outerSignature[..<(effectWords.last?.startIndex ?? outerSignature.endIndex)]
    let member = prefix.split(separator: ".").last ?? prefix
    let generic = prefix.last(where: { !$0.isWhitespace }) == ">"
        && member.contains { $0.isLetter || $0.isNumber || $0 == "_" }
    guard !generic, (isAsync || !effectWords.contains("async")),
          (failureType != Never.self || !effectWords.contains("throws")) else {
        throw ABIResolutionError.unsupportedDeclaration(
            "Generic signatures require genericArguments; async and throwing calls require matching function types."
        )
    }
    return NativeDeclaration(name: declaration, language: .swift)
}

// Scan backward so a `<` operator before the parameter list cannot open a
// generic group. Closure and requirement arrows do not describe the result.
func swiftOuterSignature(_ declaration: String) -> (text: String, result: Substring?) {
    var parentheses = 0, generics = 0
    var text = ""
    var result: Substring?
    var index = declaration.endIndex
    while index > declaration.startIndex {
        index = declaration.index(before: index)
        let character = declaration[index]
        let previous = index > declaration.startIndex ? declaration.index(before: index) : nil
        let arrow = character == ">" && previous.map { declaration[$0] == "-" } == true
        if parentheses == 0, generics == 0, arrow {
            result = declaration[declaration.index(after: index)...]
            text.removeAll(keepingCapacity: true)
            index = previous!
            continue
        }
        if character == ")" { parentheses += 1 }
        else if character == "(" { parentheses -= 1 }
        else if parentheses == 0 {
            if character == ">", !arrow { generics += 1 }
            else if character == "<", generics > 0 { generics -= 1 }
            text.append(character)
        }
    }
    return (String(text.reversed()), result)
}

final class SwiftCallInterface: @unchecked Sendable {
    let handle: OpaquePointer

    init(result: CValueType, parameters: [CValueType], errorPlan: SwiftErrorPlan? = nil) throws {
        let handles: [OpaquePointer?] = parameters.map(\.handle)
        var failure: OpaquePointer?
        let handle = withExtendedLifetime((result, parameters, errorPlan)) {
            handles.withUnsafeBufferPointer { handles in
                if let errorPlan {
                    return ABICreateSwiftThrowingCallInterface(
                        result.handle, handles.baseAddress, handles.count,
                        errorPlan.type.handle, errorPlan.isTyped, &failure
                    )
                }
                return ABICreateSwiftCallInterface(result.handle, handles.baseAddress, handles.count, &failure)
            }
        }
        guard let handle else { throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftInvocation") }
        self.handle = handle
    }
    deinit { ABIReleaseSwiftCallInterface(handle) }
}

extension SwiftCallInterface {
    private struct Entry: Sendable {
        let result: CValueType
        let parameters: [CValueType]
        let error: CValueType?
        let typedError: Bool
        let interface: SwiftCallInterface

        func matches(result: CValueType, parameters: [CValueType], errorPlan: SwiftErrorPlan?) -> Bool {
            guard Self.equal(self.result, result), self.parameters.count == parameters.count,
                  typedError == (errorPlan?.isTyped ?? false) else { return false }
            switch (error, errorPlan?.type) {
            case (.none, .none): break
            case (.some(let first), .some(let second)):
                guard Self.equal(first, second) else { return false }
            default: return false
            }
            return zip(self.parameters, parameters).allSatisfy(Self.equal)
        }

        private static func equal(_ first: CValueType, _ second: CValueType) -> Bool {
            first === second || ABIValueTypesEqual(first.handle, second.handle)
        }
    }

    // Only native layouts are cached: no Swift metatypes, codecs, images or
    // callback bodies. Active handles retain interfaces independently of eviction.
    private static let cache = Mutex<[Entry]>([])

    static func cached(result: CValueType, parameters: [CValueType], errorPlan: SwiftErrorPlan? = nil) throws -> SwiftCallInterface {
        try cache.withLock { entries in
            if let entry = entries.last(where: { $0.matches(result: result, parameters: parameters, errorPlan: errorPlan) }) {
                return entry.interface
            }
            let interface = try SwiftCallInterface(result: result, parameters: parameters, errorPlan: errorPlan)
            if entries.count == 64 { entries.removeFirst() }
            entries.append(Entry(result: result, parameters: parameters, error: errorPlan?.type,
                                 typedError: errorPlan?.isTyped ?? false, interface: interface))
            return interface
        }
    }
}

/// A prepared native Swift function whose complete signature includes arguments, result, errors, and async effects.
///
/// The prepared call uses the platform Swift calling convention. Supported
/// representations include scalar values, pointers, class references, String,
/// Array, their supported optional forms, standard C value types, managed fixed
/// layouts supplied by ABIBridgeSwiftValue, and trivial ABIBridgeValue layouts.
/// Use NativeSwiftClosure for supported concrete callbacks. Inout and explicit
/// ownership use NativeSwiftInout, NativeSwiftBorrowing, and NativeSwiftConsuming.
/// Generic declarations use explicit genericArguments and preserve their formal
/// metadata, witness, and value conventions; see <doc:GenericSwiftValues>.
/// Undescribed resilient values and ordinary unwrapped closures require separate
/// representations. Async signatures preserve the native task and suspension. Throwing signatures
/// return native failures as NativeSwiftError.
/// See <doc:SwiftFunctionInvocation>.
public struct NativeSwiftFunction<Signature>: Sendable {
    /// The declaration and image retained for this function.
    public let symbol: ResolvedSymbol

    private var implementation: SwiftImplementation?
    private let call: SwiftCallablePlan
    private let context: UInt
    private let typeOwner: NativeSwiftType?
    let consumesArguments: Bool
    let isGeneric: Bool
    var errorPlan: SwiftErrorPlan? { call.errorPlan }

    init(symbol: ResolvedSymbol, metadata: Any.Type? = nil, owner: NativeSwiftType? = nil,
         consumesArguments: Bool = false, resolver: SymbolResolver? = nil,
         generic: SwiftGenericCallPlan? = nil) throws {
        self.symbol = symbol
        self.consumesArguments = consumesArguments
        isGeneric = generic != nil
        context = metadata.map { unsafeBitCast($0, to: UInt.self) } ?? 0
        typeOwner = owner
        call = try SwiftCallablePlan(signature: Signature.self, symbol: symbol, resolver: resolver ?? owner?.resolver,
            consumesArguments: consumesArguments, generic: generic)
    }

    func capturing(_ implementation: SwiftImplementation) -> Self {
        var result = self
        result.implementation = implementation
        return result
    }

    /// Calls the Swift entry point using its prepared declaration-level signature.
    ///
    /// The signature must match the declaration's Swift ABI and ordinary
    /// ownership selected by lookup. Initializers transfer ordinary arguments
    /// to the callee; free/static functions borrow them. The caller satisfies actor/thread
    /// requirements. Managed object, String, and Array results transfer Swift ownership to the
    /// caller; custom native wrappers must establish their own value contract.
    ///
    /// - Parameter values: Fixed arguments in declaration order.
    /// - Returns: The result with its Swift ownership, or a custom native wrapper.
    /// - Throws: A NativeSwiftError from native code, or a conversion/invocation error. An incorrect ABI
    ///   description can corrupt memory and is not a recoverable Swift error.
    @unsafe public func unsafeInvoke<Result, Failure: Error, each Argument>(_ values: repeat each Argument) throws -> Result
    where Signature == (repeat each Argument) throws(Failure) -> Result {
        guard case .synchronous(let call) = call else { preconditionFailure("A synchronous signature has a synchronous call plan.") }
        return try unsafe call.unsafeInvoke(
            symbol: symbol, context: UnsafeRawPointer(bitPattern: context),
            retaining: (symbol, typeOwner), retainingCode: typeOwner?.image,
            implementation: implementation, repeat each values
        )
    }

    @unsafe public func unsafeInvoke<Result, Failure: Error, each Argument>(_ values: repeat each Argument) throws -> Result
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        guard case .synchronous(let call) = call else { preconditionFailure("A synchronous signature has a synchronous call plan.") }
        return try unsafe call.unsafeInvoke(
            symbol: symbol, context: UnsafeRawPointer(bitPattern: context),
            retaining: (symbol, typeOwner), retainingCode: typeOwner?.image,
            implementation: implementation, repeat each values
        )
    }

    // Swift 6.3 mismanages async task allocations when a same-type requirement
    // decomposes Signature into a parameter pack. Transparent entry thunks keep
    // that requirement out of the implementation frame, including in Debug builds.

    /// Awaits the native implementation on the original task and resumes on the caller's executor.
    /// The signature and caller must satisfy the native ABI, ownership, and isolation contracts.
    /// Native failures use NativeSwiftError; bridge failures retain their original types.
    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result where Signature == (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result where Signature == @Sendable (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    /// Awaits an implementation using the concurrent convention, without a hidden caller-isolation argument.
    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result where Signature == @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result where Signature == @Sendable @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    @unsafe @usableFromInline nonisolated(nonsending) func invokeAsync<Result, each Argument>(_ values: repeat each Argument) async throws -> Result {
        guard case .asynchronous(let call, let entry) = call else { preconditionFailure("An async signature has an async call plan.") }
        return try unsafe await call.unsafeInvoke(implementation: entry,
            context: UnsafeRawPointer(bitPattern: context), retaining: (entry, typeOwner),
            retainingCode: typeOwner?.image, repeat each values)
    }

}

extension ABIRuntime {
    /// Resolves a concrete Swift free function by its source-level name.
    ///
    /// - Parameters:
    ///   - name: A qualified label-only name, such as Example.decorate(_:), or a complete demangled declaration.
    ///   - signature: The complete Swift function type, including native error and async isolation conventions.
    ///   - scope: Images to search; automatic scope considers only loaded images.
    ///   - genericArguments: Scalar types and packs in declaration parameter order.
    ///   - loading: Whether an explicit image may be acquired and initialized.
    /// - Returns: A reusable handle retaining its image and prepared Swift ABI.
    /// - Throws: A resolution, unsupported representation, or call preparation error.
    public func swiftFunction<Signature>(
        named name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftFunction<Signature> {
        let declaration = try genericArguments.isEmpty ? swiftFunctionDeclaration(named: name, as: signature)
            : NativeDeclaration(name: name, language: .swift)
        let symbol = try resolve(declaration, in: scope, loading: loading)
        if !genericArguments.isEmpty {
            return try preparedGenericFunction(symbol: symbol, signature: signature, genericArguments: genericArguments)
        }
        return try NativeSwiftFunction(symbol: symbol, resolver: resolver)
    }

    /// Resolves a concrete Swift free function in an already retained image.
    ///
    /// - Parameters:
    ///   - name: The qualified demangled declaration.
    ///   - signature: The complete Swift function type, including native error and async isolation conventions.
    ///   - image: An image whose symbol index is reused.
    ///   - genericArguments: Scalar types and packs in declaration parameter order.
    ///   - loading: Whether to ask dyld to acquire and initialize the image.
    /// - Returns: A reusable handle retaining its image and prepared Swift ABI.
    /// - Throws: A resolution, unsupported representation, or call preparation error.
    public func swiftFunction<Signature>(
        named name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftFunction<Signature> {
        let declaration = try genericArguments.isEmpty ? swiftFunctionDeclaration(named: name, as: signature)
            : NativeDeclaration(name: name, language: .swift)
        let symbol = try resolve(declaration, in: image, loading: loading)
        if !genericArguments.isEmpty {
            return try preparedGenericFunction(symbol: symbol, signature: signature, genericArguments: genericArguments)
        }
        return try NativeSwiftFunction(symbol: symbol, resolver: resolver)
    }
}
