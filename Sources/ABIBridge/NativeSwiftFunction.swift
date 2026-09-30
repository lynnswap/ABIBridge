import ABIBridgeCore

func swiftFunctionTypeName(_ type: Any.Type) throws -> String {
    if type == NativeSwiftOpaqueValue.self { return "some" }
    if let closure = type as? any SwiftClosureValue.Type { return try swiftFunctionTypeName(closure.swiftFunctionType) }
    // Objective-C metatypes can print an unqualified runtime name (NSString),
    // while Swift declarations use their imported identity (__C.NSString).
    guard let mangled = _mangledTypeName(type),
          let name = DeclarationKey.demangle("$s" + mangled, language: .swift) else {
        throw ABIResolutionError.metadataUnavailable("No canonical Swift name for \(String(reflecting: type)).")
    }
    return name
}

func swiftFunctionDeclaration<Result, Failure: Error, each Argument>(
    named name: String, as signature: ((repeat each Argument) throws(Failure) -> Result).Type,
    resultName: String? = nil, defaultConsuming: Bool = false
) throws -> NativeDeclaration {
    var parameters: [Any.Type] = []
    for type in repeat (each Argument).self { parameters.append(type) }
    return try swiftFunctionDeclaration(named: name, parameterTypes: parameters, resultType: Result.self,
        failureType: Failure.self, isAsync: false, resultName: resultName, defaultConsuming: defaultConsuming)
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
            "Generic signatures require a native adapter; async and throwing calls require matching function types."
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

/// A concrete synchronous Swift function with a retained image.
///
/// The prepared call uses the platform Swift calling convention. Supported
/// representations include scalar values, pointers, class references, String,
/// Array, their supported optional forms, standard C value types, managed fixed
/// layouts supplied by ABIBridgeSwiftValue, and trivial ABIBridgeValue layouts.
/// Use NativeSwiftClosure for supported concrete callbacks. Inout and explicit
/// ownership use NativeSwiftInout, NativeSwiftBorrowing, and NativeSwiftConsuming.
/// Generic declarations, undescribed resilient values, and ordinary unwrapped
/// closures require separate adapters. Async metatypes use NativeSwiftAsyncFunction. Throwing signatures
/// return native failures as NativeSwiftError.
/// See <doc:SwiftFunctionInvocation>.
public struct NativeSwiftFunction<Result, each Argument>: Sendable {
    /// The declaration and image retained for this function.
    public let symbol: ResolvedSymbol

    private var implementation: SwiftImplementation?
    private let call: SwiftCall<Result, repeat each Argument>
    private let context: UInt
    private let typeOwner: NativeSwiftType?
    let consumesArguments: Bool
    var errorPlan: SwiftErrorPlan? { call.errorPlan }

    init(symbol: ResolvedSymbol, metadata: Any.Type? = nil, owner: NativeSwiftType? = nil,
         consumesArguments: Bool = false, errorPlan: SwiftErrorPlan? = nil, resolver: SymbolResolver? = nil) throws {
        self.symbol = symbol
        self.consumesArguments = consumesArguments
        context = metadata.map { unsafeBitCast($0, to: UInt.self) } ?? 0
        typeOwner = owner
        call = try SwiftCall(consumesArguments: consumesArguments, errorPlan: errorPlan,
            opaqueResult: SwiftOpaqueResultPlan.make(for: Result.self, symbol: symbol, resolver: resolver ?? owner?.resolver))
    }

    func capturing(_ implementation: SwiftImplementation) -> Self {
        var result = self
        result.implementation = implementation
        return result
    }

    /// Calls the concrete Swift entry point using the prepared signature.
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
    @unsafe public func unsafeInvoke(_ values: repeat each Argument) throws -> Result {
        try unsafe call.unsafeInvoke(
            symbol: symbol, context: UnsafeRawPointer(bitPattern: context),
            retaining: (symbol, typeOwner), retainingCode: typeOwner?.image,
            implementation: implementation, repeat each values
        )
    }
}

extension ABIRuntime {
    /// Resolves a concrete Swift free function by its source-level name.
    ///
    /// - Parameters:
    ///   - name: A qualified label-only name, such as Example.decorate(_:), or a complete demangled declaration.
    ///   - signature: A synchronous function-type metatype, including its native throws type.
    ///   - scope: Images to search; automatic scope considers only loaded images.
    ///   - loading: Whether an explicit image may be acquired and initialized.
    /// - Returns: A reusable handle retaining its image and prepared Swift ABI.
    /// - Throws: A resolution, unsupported representation, or call preparation error.
    public func swiftFunction<Result, Failure: Error, each Argument>(
        named name: String,
        as signature: ((repeat each Argument) throws(Failure) -> Result).Type,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftFunction<Result, repeat each Argument> {
        let errorPlan = try SwiftErrorPlan.make(Failure.self)
        return try NativeSwiftFunction(
            symbol: resolve(swiftFunctionDeclaration(named: name, as: signature), in: scope, loading: loading),
            errorPlan: errorPlan, resolver: resolver
        )
    }

    /// Resolves a concrete Swift free function in an already retained image.
    ///
    /// - Parameters:
    ///   - name: The qualified demangled declaration.
    ///   - signature: A synchronous function-type metatype, including its native throws type.
    ///   - image: An image whose symbol index is reused.
    ///   - loading: Whether to ask dyld to acquire and initialize the image.
    /// - Returns: A reusable handle retaining its image and prepared Swift ABI.
    /// - Throws: A resolution, unsupported representation, or call preparation error.
    public func swiftFunction<Result, Failure: Error, each Argument>(
        named name: String,
        as signature: ((repeat each Argument) throws(Failure) -> Result).Type,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftFunction<Result, repeat each Argument> {
        let errorPlan = try SwiftErrorPlan.make(Failure.self)
        return try NativeSwiftFunction(
            symbol: resolve(swiftFunctionDeclaration(named: name, as: signature), in: image, loading: loading),
            errorPlan: errorPlan, resolver: resolver
        )
    }
}
