import ABIBridgeRuntime
import ABIBridgeCore
import Synchronization

func swiftFunctionTypeName(_ type: Any.Type) throws -> String {
    if type == NativeSwiftValue.self || type == NativeSwiftBorrowedValue.self { return "some" }
    if let closure = type as? any SwiftClosureValue.Type {
        return try swiftFunctionTypeName(closure.swiftFunctionType)
    }
    var name = try swiftNativeTypeName(type)
    if runtimeMetadataKind(type) == .function {
        let function = try SwiftFunctionSignature(type)
        for child in function.parameters {
            let native = try swiftNativeTypeName(child)
            let adapted = try swiftArgumentTypeName(child, defaultConsuming: false)
            if native != adapted { name = name.replacingOccurrences(of: native, with: adapted) }
        }
        let nativeResult = try swiftNativeTypeName(function.result)
        let adaptedResult = try swiftFunctionTypeName(function.result)
        if nativeResult != adaptedResult {
            name = name.replacingOccurrences(of: nativeResult, with: adaptedResult)
        }
    }
    return name
}

func swiftNativeTypeName(_ type: Any.Type) throws -> String {
    if let syntax = try SwiftSyntax.extendedMetadataType(type) { return try syntax.name() }
    // Objective-C metatypes can print an unqualified runtime name (NSString),
    // while Swift declarations use their imported identity (__C.NSString).
    // The runtime mangler has no spelling for Objective-C superclass
    // existentials or containers containing them; their qualified runtime
    // descriptions still name the valid Swift types.
    guard let mangled = _mangledTypeName(type) else { return String(reflecting: type) }
    guard let name = DeclarationKey.demangle("$s" + mangled, language: .swift) else {
        throw ABIResolutionError.metadataUnavailable(
            "No canonical Swift name for \(String(reflecting: type))."
        )
    }
    return name
}

func swiftFunctionDeclaration<Signature>(
    named name: String,
    as signature: Signature.Type,
    resultName: String? = nil,
    defaultConsuming: Bool = false
) throws -> NativeDeclaration {
    let description = try SwiftFunctionSignature(signature)
    return try swiftFunctionDeclaration(
        named: name,
        parameterTypes: description.parameters,
        resultType: description.result,
        failureType: description.failure,
        isAsync: description.isAsync,
        resultName: resultName,
        defaultConsuming: defaultConsuming
    )
}

func swiftFunctionDeclaration(
    named name: String,
    parameterTypes: [Any.Type],
    resultType: Any.Type,
    failureType: Any.Type,
    isAsync: Bool,
    resultName: String? = nil,
    defaultConsuming: Bool = false
) throws -> NativeDeclaration {
    let throwing =
        failureType == Never.self
        ? ""
        : failureType == (any Error).self
            ? " throws" : " throws(" + (try swiftFunctionTypeName(failureType)) + ")"
    let effects = (isAsync ? " async" : "") + throwing
    var declaration = name
    // A full demangled declaration is useful when a foreign wrapper's Swift
    // type name differs from the native type. Label-only names infer types.
    if SwiftFormalSyntax.topLevelArrow(in: name) == nil, name.last == ")",
        let opening = name.lastIndex(of: "(")
    {
        let text = name[name.index(after: opening)..<name.index(before: name.endIndex)]
        let labels = text.split(separator: ":").map(String.init)
        let labelsOnly =
            text.isEmpty
            || (text.last == ":"
                && labels.allSatisfy {
                    !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
                })
        if labelsOnly {
            let parameters = try parameterTypes.map {
                try swiftArgumentTypeName($0, defaultConsuming: defaultConsuming)
            }
            guard labels.count == parameters.count else {
                throw ABIResolutionError.signatureMismatch(
                    .init(
                        expected: "\(parameters.count) argument labels",
                        found: [name]
                    )
                )
            }
            let omitLabels = labels.allSatisfy { $0 == "_" }
            let fields = zip(labels, parameters).map { label, type in
                omitLabels ? type : label + ": " + type
            }
            declaration =
                String(name[..<opening]) + "(" + fields.joined(separator: ", ") + ")" + effects
                + " -> " + (try resultName ?? swiftFunctionTypeName(resultType))
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
    let generic =
        prefix.last(where: { !$0.isWhitespace }) == ">"
        && member.contains { $0.isLetter || $0.isNumber || $0 == "_" }
    guard !generic, (isAsync || !effectWords.contains("async")),
        (failureType != Never.self || !effectWords.contains("throws"))
    else {
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
        if parentheses == 0, generics == 0, arrow,
            SwiftFormalSyntax.isResultArrow(in: declaration, at: previous!)
        {
            result = declaration[declaration.index(after: index)...]
            text.removeAll(keepingCapacity: true)
            index = previous!
            continue
        }
        if character == ")" {
            parentheses += 1
        } else if character == "(" {
            parentheses -= 1
        } else if parentheses == 0 {
            if character == ">", !arrow {
                generics += 1
            } else if character == "<", generics > 0 {
                generics -= 1
            }
            text.append(character)
        }
    }
    return (String(text.reversed()), result)
}

final class SwiftCallInterface: @unchecked Sendable {
    let runtime: RuntimeSwiftCallInterface
    var handle: OpaquePointer { runtime.handle }
    init(_ runtime: RuntimeSwiftCallInterface) { self.runtime = runtime }

    func closureEntry() throws -> SwiftClosureCallbackOwner {
        try SwiftClosureCallbackOwner(interface: self)
    }

    init(result: CValueType, parameters: [CValueType], errorPlan: SwiftErrorPlan? = nil) throws {
        runtime = try withRuntimeErrors {
            try RuntimeSwiftCallInterface.cached(
                result: result.runtime,
                parameters: parameters.map(\.runtime),
                errorPlan: errorPlan.map {
                    RuntimeErrorConvention(type: $0.type.runtime, isTyped: $0.isTyped)
                }
            )
        }
    }
}

extension SwiftCallInterface {
    static func cached(
        result: CValueType,
        parameters: [CValueType],
        errorPlan: SwiftErrorPlan? = nil
    ) throws -> SwiftCallInterface {
        try withRuntimeErrors {
            SwiftCallInterface(
                try RuntimeSwiftCallInterface.cached(
                    result: result.runtime,
                    parameters: parameters.map(\.runtime),
                    errorPlan: errorPlan.map {
                        RuntimeErrorConvention(type: $0.type.runtime, isTyped: $0.isTyped)
                    }
                )
            )
        }
    }
}

/// A prepared native Swift function with explicit error and async conventions.
///
/// Calls use the platform Swift convention. Async signatures preserve the native task across suspension; throwing signatures surface native errors as `NativeSwiftError`. Use `NativeSwiftClosure` for callbacks and `NativeSwiftInout`, `NativeSwiftBorrowing`, or `NativeSwiftConsuming` for explicit argument conventions.
///
/// See <doc:SwiftFunctionInvocation> for supported value representations and <doc:GenericSwiftValues> for generic calls. Undescribed resilient values and ordinary unwrapped closures need separate representations.
public struct NativeSwiftFunction<Signature>: Sendable {
    /// The exported symbol that names this function's declaration.
    public var symbol: ResolvedSymbol { entry.symbol }
    /// The selected declaration, as written in source.
    public var declaration: NativeDeclaration { entry.declaration }

    private(set) var entry: SwiftEntry
    let call: SwiftCallablePlan
    private let context: UInt
    private let typeOwner: NativeSwiftType?
    let consumesArguments: Bool
    let isGeneric: Bool
    var errorPlan: SwiftErrorPlan? { call.errorPlan }

    init(
        symbol: ResolvedSymbol,
        metadata: Any.Type? = nil,
        owner: NativeSwiftType? = nil,
        consumesArguments: Bool = false,
        resolver: SymbolResolver? = nil,
        generic: SwiftGenericCallPlan? = nil
    ) throws {
        try self.init(
            entry: SwiftEntry(symbol: symbol),
            metadata: metadata,
            owner: owner,
            consumesArguments: consumesArguments,
            resolver: resolver,
            generic: generic
        )
    }

    init(
        entry: SwiftEntry,
        metadata: Any.Type? = nil,
        owner: NativeSwiftType? = nil,
        consumesArguments: Bool = false,
        resolver: SymbolResolver? = nil,
        generic: SwiftGenericCallPlan? = nil
    ) throws {
        self.entry = entry
        self.consumesArguments = consumesArguments
        isGeneric = generic?.binding.declaration.parameters.isEmpty == false
        context = metadata.map { unsafeBitCast($0, to: UInt.self) } ?? 0
        typeOwner = owner
        call = try SwiftCallablePlan(
            signature: Signature.self,
            entry: entry,
            resolver: resolver ?? owner?.resolver,
            consumesArguments: consumesArguments,
            generic: generic
        )
    }

    func capturing(_ implementation: SwiftImplementation) -> Self {
        var result = self
        result.entry.implementation = implementation
        return result
    }

    /// Calls the Swift entry point using its prepared declaration-level signature.
    ///
    /// The signature must match the declaration's Swift ABI and ordinary ownership selected by lookup. Initializers transfer ordinary arguments to the callee; free/static functions borrow them. The caller satisfies actor/thread requirements. Managed object, String, and Array results transfer Swift ownership to the caller; custom native wrappers must establish their own value contract.
    ///
    /// - Parameter values: Fixed arguments in declaration order.
    /// - Returns: The result with its Swift ownership, or a custom native wrapper.
    /// - Throws: A NativeSwiftError from native code, or a conversion/invocation error. An incorrect ABI
    ///   description can corrupt memory and is not a recoverable Swift error.
    @unsafe public func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) throws -> Result
    where Signature == (repeat each Argument) throws(Failure) -> Result {
        guard case .synchronous(let call) = call else {
            preconditionFailure("A synchronous signature has a synchronous call plan.")
        }
        return try unsafe call.unsafeInvoke(
            entry: entry,
            context: UnsafeRawPointer(bitPattern: context),
            retaining: (entry.symbol, typeOwner),
            retainingCode: typeOwner?.image,
            repeat each values
        )
    }

    @unsafe public func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) throws -> Result
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        guard case .synchronous(let call) = call else {
            preconditionFailure("A synchronous signature has a synchronous call plan.")
        }
        return try unsafe call.unsafeInvoke(
            entry: entry,
            context: UnsafeRawPointer(bitPattern: context),
            retaining: (entry.symbol, typeOwner),
            retainingCode: typeOwner?.image,
            repeat each values
        )
    }

    // Swift 6.3 mismanages async task allocations when a same-type requirement
    // decomposes Signature into a parameter pack. Transparent entry thunks keep
    // that requirement out of the implementation frame, including in Debug builds.

    /// Awaits the native implementation on the original task and resumes on the caller's executor. The signature and caller must satisfy the native ABI, ownership, and isolation contracts. Native failures use NativeSwiftError; bridge failures retain their original types.
    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result
    where Signature == (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result
    where Signature == @Sendable (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    /// Awaits an implementation using the concurrent convention, without a hidden caller-isolation argument.
    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result
    where Signature == @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result
    where Signature == @Sendable @concurrent (repeat each Argument) async throws(Failure) -> Result
    {
        try unsafe await invokeAsync(repeat each values)
    }

    @unsafe @usableFromInline nonisolated(nonsending) func invokeAsync<Result, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result {
        guard case .asynchronous(let call, let implementation) = call else {
            preconditionFailure("An async signature has an async call plan.")
        }
        return try unsafe await call.unsafeInvoke(
            implementation: implementation,
            context: UnsafeRawPointer(bitPattern: context),
            retaining: (implementation, typeOwner),
            retainingCode: typeOwner?.image,
            repeat each values
        )
    }

    /// Uses the native result while its return storage and input lifetimes remain active. The borrowed view expires and the native result is destroyed before writeback.
    @unsafe public func unsafeInvoke<Output: ~Copyable, Failure: Error, each Argument>(
        _ values: repeat each Argument,
        withResult body: (NativeSwiftBorrowedValue) throws -> Output
    ) throws -> Output
    where Signature == (repeat each Argument) throws(Failure) -> NativeSwiftBorrowedValue {
        guard case .synchronous(let call) = call else {
            preconditionFailure("A synchronous signature has a synchronous call plan.")
        }
        return try unsafe call.unsafeInvoke(
            entry: entry,
            context: UnsafeRawPointer(bitPattern: context),
            retaining: (entry.symbol, typeOwner),
            retainingCode: typeOwner?.image,
            repeat each values,
            withResult: body
        )
    }

    /// Uses the native result while its return storage and input lifetimes remain active. The borrowed view expires and the native result is destroyed before writeback.
    @unsafe public func unsafeInvoke<Output: ~Copyable, Failure: Error, each Argument>(
        _ values: repeat each Argument,
        withResult body: (NativeSwiftBorrowedValue) throws -> Output
    ) throws -> Output
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> NativeSwiftBorrowedValue
    {
        guard case .synchronous(let call) = call else {
            preconditionFailure("A synchronous signature has a synchronous call plan.")
        }
        return try unsafe call.unsafeInvoke(
            entry: entry,
            context: UnsafeRawPointer(bitPattern: context),
            retaining: (entry.symbol, typeOwner),
            retainingCode: typeOwner?.image,
            repeat each values,
            withResult: body
        )
    }

    @_transparent
    @unsafe
    public nonisolated(nonsending) func unsafeInvoke<
        Output: ~Copyable,
        Failure: Error,
        each Argument
    >(
        _ values: repeat each Argument,
        withResult body: (NativeSwiftBorrowedValue) async throws -> Output
    ) async throws -> Output
    where Signature == (repeat each Argument) async throws(Failure) -> NativeSwiftBorrowedValue {
        try unsafe await invokeAsync(repeat each values, withResult: body)
    }

    @_transparent
    @unsafe
    public nonisolated(nonsending) func unsafeInvoke<
        Output: ~Copyable,
        Failure: Error,
        each Argument
    >(
        _ values: repeat each Argument,
        withResult body: (NativeSwiftBorrowedValue) async throws -> Output
    ) async throws -> Output
    where
        Signature
            == @Sendable (repeat each Argument) async throws(Failure) -> NativeSwiftBorrowedValue
    {
        try unsafe await invokeAsync(repeat each values, withResult: body)
    }

    @_transparent
    @unsafe
    public nonisolated(nonsending) func unsafeInvoke<
        Output: ~Copyable,
        Failure: Error,
        each Argument
    >(
        _ values: repeat each Argument,
        withResult body: (NativeSwiftBorrowedValue) async throws -> Output
    ) async throws -> Output
    where
        Signature
            == @concurrent (repeat each Argument) async throws(Failure) -> NativeSwiftBorrowedValue
    {
        try unsafe await invokeAsync(repeat each values, withResult: body)
    }

    @_transparent
    @unsafe
    public nonisolated(nonsending) func unsafeInvoke<
        Output: ~Copyable,
        Failure: Error,
        each Argument
    >(
        _ values: repeat each Argument,
        withResult body: (NativeSwiftBorrowedValue) async throws -> Output
    ) async throws -> Output
    where
        Signature
            == @Sendable @concurrent (repeat each Argument) async throws(Failure) ->
            NativeSwiftBorrowedValue
    {
        try unsafe await invokeAsync(repeat each values, withResult: body)
    }

    @unsafe @usableFromInline
    nonisolated(nonsending) func invokeAsync<Output: ~Copyable, each Argument>(
        _ values: repeat each Argument,
        withResult body: (NativeSwiftBorrowedValue) async throws -> Output
    ) async throws -> Output {
        guard case .asynchronous(let call, let implementation) = call else {
            preconditionFailure("An async signature has an async call plan.")
        }
        return try unsafe await call.unsafeInvoke(
            implementation: implementation,
            context: UnsafeRawPointer(bitPattern: context),
            retaining: (implementation, typeOwner),
            retainingCode: typeOwner?.image,
            repeat each values,
            withResult: body
        )
    }

}

/// The binding a selected function needs, when its call is not concrete.
private struct SelectedFunctionPlan {
    let plan: SwiftGenericCallPlan?
}

extension ABIRuntime {
    // A complete declaration names the native function, so its spelling
    // selects candidates and the requested types may adapt them. A label-only
    // name selects the candidates whose native signatures the requested
    // types are compatible with.
    private nonisolated func prepareSwiftFunction<Signature>(
        named name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument],
        declaredSignature: String?,
        valueABIs: [NativeSwiftType: NativeType],
        candidates: (
            _ declaration: NativeDeclaration, _ extensionsOnly: Bool, _ includingSharedCache: Bool
        ) throws -> [SwiftCandidate]
    ) throws -> NativeSwiftFunction<Signature> {
        let description = try SwiftFunctionSignature(signature)
        let usesBinding =
            !genericArguments.isEmpty || declaredSignature != nil || !valueABIs.isEmpty
            || description.requiresValueDeclaration
        let declaration = NativeDeclaration(name: name, language: .swift)
        let complete = SwiftMemberLookup.hasSignature(name)
        // Without a binding, a complete declaration must not be generic and
        // must have the requested effects.
        if complete && !usesBinding { _ = try swiftFunctionDeclaration(named: name, as: signature) }
        let key = DeclarationKey.make(name, language: .swift)
        let extensionsOnly = SymbolIndex.extensionMemberName(name) != nil
        func select(includingSharedCache: Bool) throws -> SwiftCandidateSelection<SelectedFunctionPlan> {
            try SwiftCandidateSelection(
                candidates(declaration, extensionsOnly, includingSharedCache),
                namesDeclaration: complete
            ) { candidate, entry -> SelectedFunctionPlan? in
                if complete {
                    let names = [candidate.declaration.name, candidate.memberName]
                    guard
                        (names + names.compactMap(SymbolIndex.operatorAlias)).contains(where: {
                            DeclarationKey.make($0, language: .swift) == key
                        })
                    else { return nil }
                    guard usesBinding else { return SelectedFunctionPlan(plan: nil) }
                }
                let plan = try SwiftGenericCallPlan(
                    entry: entry,
                    genericArguments: genericArguments,
                    signature: description,
                    resolver: resolver,
                    declaredSignature: declaredSignature,
                    valueABIs: valueABIs
                )
                if !complete { try plan.check(description) }
                // A concrete call needs no binding, but a handle that converts
                // class references keeps its plan so hooks can reject it.
                return SelectedFunctionPlan(
                    plan: usesBinding || plan.convertsReferences(description) ? plan : nil
                )
            }
        }
        var selection = try select(includingSharedCache: false)
        // The images can hold other overloads while only the shared cache's
        // local symbols describe the requested one.
        if selection.accepted.isEmpty && selection.failure == nil {
            selection = try select(includingSharedCache: true)
        }
        if let (entry, prepared) = try selection.selected(for: declaration) {
            return try NativeSwiftFunction(entry: entry, resolver: resolver, generic: prepared.plan)
        }
        if let failure = selection.failure ?? selection.mismatch { throw failure }
        throw ABIResolutionError.declarationNotFound(declaration)
    }

    /// Resolves a concrete Swift free function by its source-level name.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// - Parameters:
    ///   - name: A qualified label-only name, such as Example.decorate(_:), or a complete demangled declaration.
    ///   - signature: The complete Swift function type, including native error and async isolation conventions.
    ///   - scope: Images to search; automatic scope considers only loaded images.
    ///   - genericArguments: Scalar types and packs in declaration parameter order.
    ///   - valueABIs: Formal ABIs for runtime-only closed nominal values in this lookup.
    ///   - declaredSignature: The formal function type and optional canonical generic signature when binary metadata is insufficient.
    ///   - loading: Whether an explicit image may be acquired and initialized.
    /// - Returns: A reusable handle retaining its image and prepared Swift ABI.
    /// - Throws: A resolution, unsupported representation, or call preparation error.
    public nonisolated func resolveSwiftFunctionAndWait<Signature>(
        named name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftFunction<Signature> {
        try prepareSwiftFunction(
            named: name,
            as: signature,
            genericArguments: genericArguments,
            declaredSignature: declaredSignature,
            valueABIs: valueABIs,
            candidates: {
                try resolver.swiftDeclarationCandidates(
                    $0,
                    in: scope,
                    loading: loading,
                    extensionsOnly: $1,
                    includingSharedCache: $2
                )
            }
        )
    }

    /// Resolves and prepares a Swift function without blocking the caller's executor.
    ///
    /// Image acquisition, search, and ABI preparation run on a worker. Native invocation is a separate operation.
    /// - Returns: A reusable handle retaining its image and prepared Swift ABI.
    /// - Throws: The same resolution, representation, and preparation errors as synchronous lookup.
    public nonisolated func resolveSwiftFunction<Signature>(
        named name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) async throws -> NativeSwiftFunction<Signature> {
        try await prepare { runtime in
            try runtime.resolveSwiftFunctionAndWait(
                named: name,
                as: signature,
                genericArguments: genericArguments,
                declaredAs: declaredSignature,
                valueABIs: valueABIs,
                in: scope,
                loading: loading
            )
        }
    }

    /// Resolves a concrete Swift free function in an already retained image.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// - Parameters:
    ///   - name: The qualified demangled declaration.
    ///   - signature: The complete Swift function type, including native error and async isolation conventions.
    ///   - image: An image whose symbol index is reused.
    ///   - genericArguments: Scalar types and packs in declaration parameter order.
    ///   - valueABIs: Formal ABIs for runtime-only closed nominal values in this lookup.
    ///   - declaredSignature: The formal function type and optional canonical generic signature when binary metadata is insufficient.
    ///   - loading: Whether to ask dyld to acquire and initialize the image.
    /// - Returns: A reusable handle retaining its image and prepared Swift ABI.
    /// - Throws: A resolution, unsupported representation, or call preparation error.
    public nonisolated func resolveSwiftFunctionAndWait<Signature>(
        named name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> NativeSwiftFunction<Signature> {
        try prepareSwiftFunction(
            named: name,
            as: signature,
            genericArguments: genericArguments,
            declaredSignature: declaredSignature,
            valueABIs: valueABIs,
            candidates: {
                try resolver.swiftDeclarationCandidates(
                    $0,
                    in: image,
                    loading: loading,
                    extensionsOnly: $1,
                    includingSharedCache: $2
                )
            }
        )
    }

    /// Resolves and prepares a Swift function in a retained image on an independent worker.
    ///
    /// The caller suspends during lookup and preparation. Native invocation is a separate operation.
    /// - Returns: A reusable handle retaining its image and prepared Swift ABI.
    /// - Throws: The same resolution, representation, and preparation errors as synchronous lookup.
    public nonisolated func resolveSwiftFunction<Signature>(
        named name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) async throws -> NativeSwiftFunction<Signature> {
        try await prepare { runtime in
            try runtime.resolveSwiftFunctionAndWait(
                named: name,
                as: signature,
                genericArguments: genericArguments,
                declaredAs: declaredSignature,
                valueABIs: valueABIs,
                in: image,
                loading: loading
            )
        }
    }
}
