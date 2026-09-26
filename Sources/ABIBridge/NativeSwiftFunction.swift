import ABIBridgeCore

func swiftFunctionTypeName(_ type: Any.Type) throws -> String {
    // Objective-C metatypes can print an unqualified runtime name (NSString),
    // while Swift declarations use their imported identity (__C.NSString).
    guard let mangled = _mangledTypeName(type),
          let name = DeclarationKey.demangle("$s" + mangled, language: .swift) else {
        throw ABIResolutionError.metadataUnavailable("No canonical Swift name for \(String(reflecting: type)).")
    }
    return name
}

func swiftFunctionDeclaration<Result, each Argument>(
    named name: String, as signature: ((repeat each Argument) -> Result).Type,
    resultName: String? = nil
) throws -> NativeDeclaration {
    var declaration = name
    // A full demangled declaration is useful when a foreign wrapper's Swift
    // type name differs from the native type. Label-only names infer types.
    if !name.contains("->"), name.last == ")", let opening = name.firstIndex(of: "(") {
        let text = name[name.index(after: opening)..<name.index(before: name.endIndex)]
        let labels = text.split(separator: ":").map(String.init)
        let labelsOnly = text.isEmpty || (text.last == ":" && labels.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        })
        if labelsOnly {
            var parameters: [String] = []
            for type in repeat (each Argument).self { parameters.append(try swiftFunctionTypeName(type)) }
            guard labels.count == parameters.count else {
                throw ABIResolutionError.signatureMismatch(
                    expected: "\(parameters.count) argument labels", found: [name]
                )
            }
            let fields = zip(labels, parameters).map { label, type in label == "_" ? type : label + ": " + type }
            declaration = String(name[..<opening]) + "(" + fields.joined(separator: ", ") + ") -> " + (try resultName ?? swiftFunctionTypeName(Result.self))
        }
    }
    let prefix = declaration.prefix { $0 != "(" }
    let member = prefix.split(separator: ".").last ?? prefix
    let generic = prefix.last(where: { !$0.isWhitespace }) == ">"
        && member.contains { $0.isLetter || $0.isNumber || $0 == "_" }
    guard !generic, !declaration.contains(" async "),
          !declaration.contains(" throws "), !declaration.contains(" throws("), !declaration.contains("inout "),
          !declaration.contains("__owned ") else {
        throw ABIResolutionError.unsupportedDeclaration(
            "Generic signatures, async/throwing effects, and inout/consuming parameters require a native adapter."
        )
    }
    return NativeDeclaration(name: declaration, language: .swift)
}

final class SwiftCallInterface: @unchecked Sendable {
    let handle: OpaquePointer

    init(result: CValueType, parameters: [CValueType]) throws {
        let handles: [OpaquePointer?] = parameters.map(\.handle)
        var failure: OpaquePointer?
        guard let handle = handles.withUnsafeBufferPointer({
            ABICreateSwiftCallInterface(result.handle, $0.baseAddress, $0.count, &failure)
        }) else { throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftInvocation") }
        self.handle = handle
    }
    deinit { ABIReleaseSwiftCallInterface(handle) }
}

/// A concrete synchronous, nonthrowing Swift function with a retained image.
///
/// The prepared call uses the platform Swift calling convention. Supported
/// representations include scalar values, pointers, class references, String,
/// standard C value types, and fixed trivial layouts supplied by ABIBridgeValue.
/// Generic declarations, resilient values, closures, inout and consumed
/// arguments, async functions, and throwing functions require separate adapters.
/// See <doc:SwiftFunctionInvocation>.
public struct NativeSwiftFunction<Result, each Argument>: Sendable {
    /// The declaration and image retained for this function.
    public let symbol: ResolvedSymbol

    private let call: SwiftCall<Result, repeat each Argument>
    private let context: UInt
    private let typeOwner: NativeSwiftType?

    init(symbol: ResolvedSymbol, metadata: Any.Type? = nil, owner: NativeSwiftType? = nil,
         consumesArguments: Bool = false) throws {
        self.symbol = symbol
        context = metadata.map { unsafeBitCast($0, to: UInt.self) } ?? 0
        typeOwner = owner
        call = try SwiftCall(consumesArguments: consumesArguments)
    }

    /// Calls the concrete Swift entry point using the prepared signature.
    ///
    /// The signature must match the declaration's Swift ABI and ordinary
    /// ownership selected by lookup. Initializers transfer ordinary arguments
    /// to the callee; free/static functions borrow them. The caller satisfies actor/thread
    /// requirements. Object and String results transfer Swift ownership to the
    /// caller; custom native wrappers must establish their own value contract.
    ///
    /// - Parameter values: Fixed arguments in declaration order.
    /// - Returns: The result with its Swift ownership, or a custom native wrapper.
    /// - Throws: An argument conversion or invocation error. An incorrect ABI
    ///   description can corrupt memory and is not a recoverable Swift error.
    @unsafe public func unsafeInvoke(_ values: repeat each Argument) throws -> Result {
        try unsafe call.unsafeInvoke(
            symbol: symbol, context: UnsafeRawPointer(bitPattern: context),
            retaining: (symbol, typeOwner), repeat each values
        )
    }
}

extension ABIRuntime {
    /// Resolves a concrete Swift free function by its source-level name.
    ///
    /// - Parameters:
    ///   - name: A qualified label-only name, such as Example.decorate(_:), or a complete demangled declaration.
    ///   - signature: A synchronous, nonthrowing function-type metatype.
    ///   - scope: Images to search; automatic scope considers only loaded images.
    ///   - loading: Whether an explicit image may be acquired and initialized.
    /// - Returns: A reusable handle retaining its image and prepared Swift ABI.
    /// - Throws: A resolution, unsupported representation, or call preparation error.
    public func swiftFunction<Result, each Argument>(
        named name: String,
        as signature: ((repeat each Argument) -> Result).Type,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftFunction<Result, repeat each Argument> {
        try NativeSwiftFunction(symbol: resolve(swiftFunctionDeclaration(named: name, as: signature), in: scope, loading: loading))
    }

    /// Resolves a concrete Swift free function in an already retained image.
    ///
    /// - Parameters:
    ///   - name: The qualified demangled declaration.
    ///   - signature: A synchronous, nonthrowing function-type metatype.
    ///   - image: An image whose symbol index is reused.
    ///   - loading: Whether to ask dyld to acquire and initialize the image.
    /// - Returns: A reusable handle retaining its image and prepared Swift ABI.
    /// - Throws: A resolution, unsupported representation, or call preparation error.
    public func swiftFunction<Result, each Argument>(
        named name: String,
        as signature: ((repeat each Argument) -> Result).Type,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftFunction<Result, repeat each Argument> {
        try NativeSwiftFunction(symbol: resolve(swiftFunctionDeclaration(named: name, as: signature), in: image, loading: loading))
    }
}
