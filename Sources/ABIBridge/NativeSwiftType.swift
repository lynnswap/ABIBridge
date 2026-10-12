import ABIBridgeRuntime
import ABIBridgeCore
import Foundation
import ObjectiveC
import Synchronization

enum SwiftTypeCacheKey: Hashable, Sendable {
    case declaration(
        name: String,
        image: NativeImageIdentity,
        representation: ObjectIdentifier?,
        arguments: [NativeSwiftGenericArgument.Identity]
    )
    case metadata(ObjectIdentifier, image: NativeImageIdentity)
}

final class SwiftTypeCache: Sendable {
    private struct State: Sendable {
        var revision: UInt64 = 0
        var types: [SwiftTypeCacheKey: NativeSwiftType] = [:]
    }
    private let state = Mutex(State())

    var revision: UInt64 { state.withLock { $0.revision } }

    func value(
        for key: SwiftTypeCacheKey,
        retaining arguments: [NativeSwiftGenericArgument]? = nil
    ) -> NativeSwiftType? {
        state.withLock { state in
            guard let cached = state.types[key], retainsOwners(cached, of: arguments) else {
                return nil
            }
            return cached
        }
    }

    func insert(
        _ type: NativeSwiftType,
        for key: SwiftTypeCacheKey,
        revision: UInt64,
        retaining arguments: [NativeSwiftGenericArgument]? = nil
    ) -> NativeSwiftType {
        let (result, displaced) = state.withLock { state in
            if let cached = state.types[key], retainsOwners(cached, of: arguments) {
                return (cached, nil as NativeSwiftType?)
            }
            guard state.revision == revision else { return (type, nil) }
            return (type, state.types.updateValue(type, forKey: key))
        }
        withExtendedLifetime(displaced) {}
        return result
    }

    func removeCachedResults() {
        let removed = state.withLock { state in
            state.revision &+= 1
            let removed = state.types
            state.types = [:]
            return removed
        }
        // Type destruction can release loader references and reenter lookup.
        withExtendedLifetime(removed) {}
    }

    private func retainsOwners(
        _ type: NativeSwiftType,
        of arguments: [NativeSwiftGenericArgument]?
    ) -> Bool {
        guard let arguments else { return true }
        return zip(type.genericMetadata?.arguments ?? [], arguments)
            .allSatisfy { $0.retainsOwners(of: $1) }
    }
}

struct SwiftMetadataResponse: BitwiseCopyable, ABIBridgeValue {
    let address: UInt
    let state: UInt
    static let abiType = try! NativeType.structure(
        named: "Swift.MetadataResponse",
        fields: [.uint, .uint]
    )
    init(nativeValue: NativeValue) throws {
        self = try unsafe nativeValue.read(as: Self.self)
    }
    static func nativeValue(from value: Self) throws -> NativeValue {
        try .init(copying: value, as: abiType)
    }
}

/// A concrete Swift type and its retained implementation images.
///
/// Type lookup requests complete metadata without constructing an instance. Generic arguments are validated by the Swift runtime. Member lookups reuse the image's existing symbol index. See <doc:SwiftMemberInvocation> for lookup and invocation conventions.
public actor NativeSwiftType: Hashable {
    /// Type handles compare by their concrete Swift metadata identity.
    public nonisolated static func == (lhs: NativeSwiftType, rhs: NativeSwiftType) -> Bool {
        lhs.metadata == rhs.metadata
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(metadata))
    }

    /// The qualified type name. Runtime values can include instantiated generic arguments.
    public nonisolated let name: String
    /// An image retained with this type's metadata and implementations.
    public nonisolated let image: NativeImage

    let metadata: Any.Type
    let representation: Any.Type?
    let resolver: SymbolResolver
    let genericMetadata: SwiftGenericTypeMetadata?
    nonisolated let codeLifetime: SwiftValueCodeLifetime
    nonisolated var codeImages: [NativeImage] { codeLifetime.images }
    nonisolated var genericArguments: [NativeSwiftGenericArgument] {
        genericMetadata?.arguments ?? []
    }
    private nonisolated let cachedReceiver = Mutex<SwiftReceiverCodec?>(nil)
    private nonisolated let cachedDeclarationName = Mutex<String?>(nil)

    init(
        name: String,
        image: NativeImage,
        metadata: Any.Type,
        representation: Any.Type?,
        resolver: SymbolResolver,
        genericMetadata: SwiftGenericTypeMetadata? = nil,
        codeLifetime: SwiftValueCodeLifetime? = nil
    ) {
        self.name = name
        self.image = image
        self.metadata = metadata
        self.representation = representation
        self.resolver = resolver
        self.genericMetadata = genericMetadata
        self.codeLifetime =
            codeLifetime ?? SwiftValueCodeLifetime([image] + (genericMetadata?.images ?? []))
    }

    nonisolated func retainingCode(_ lifetime: SwiftValueCodeLifetime) -> NativeSwiftType {
        NativeSwiftType(
            name: name,
            image: image,
            metadata: metadata,
            representation: representation,
            resolver: resolver,
            genericMetadata: genericMetadata,
            codeLifetime: lifetime
        )
    }

    private nonisolated func declarationName() throws -> String {
        if let cached = cachedDeclarationName.withLock({ $0 }) { return cached }
        // Runtime value construction retains metadata without scanning symbols.
        // A member lookup needs the declaration's uninstantiated owner name.
        let resolved = try swiftTypeDeclarationName(
            metadata,
            in: image,
            suggestedName: name,
            resolver: resolver
        )
        return cachedDeclarationName.withLock { cached in
            if let cached { return cached }
            cached = resolved
            return resolved
        }
    }

    nonisolated func receiverPlan(
        mutating isMutating: Bool,
        consuming isConsuming: Bool = false,
        generic: SwiftGenericCallPlan? = nil,
        receiverABI: NativeType? = nil
    ) throws -> SwiftReceiverPlan {
        let (plan, codec) = try prepareReceiverPlan(
            mutating: isMutating,
            consuming: isConsuming,
            generic: generic,
            receiverABI: receiverABI,
            cachedReceiver: cachedReceiver.withLock { $0 }
        )
        if let codec {
            cachedReceiver.withLock { cached in
                if cached == nil { cached = codec }
            }
        }
        return plan
    }

    private nonisolated func prepareReceiverPlan(
        mutating isMutating: Bool,
        consuming isConsuming: Bool,
        generic: SwiftGenericCallPlan?,
        receiverABI: NativeType?,
        cachedReceiver: SwiftReceiverCodec?
    ) throws -> (SwiftReceiverPlan, SwiftReceiverCodec?) {
        let codec: SwiftReceiverCodec
        let cachedCodec: SwiftReceiverCodec?
        if let receiverABI {
            let formalType = try explicitSwiftValueType(metadata, abi: receiverABI)
            codec = SwiftReceiverCodec(runtimeType: metadata, formalType: formalType)
            cachedCodec = nil
        } else if (representation == nil || representation == metadata),
            let formalType = try generic?.receiverType()
        {
            codec = SwiftReceiverCodec(runtimeType: metadata, formalType: formalType)
            cachedCodec = nil
        } else {
            codec = try cachedReceiver ?? SwiftReceiverCodec.make(for: representation ?? metadata)
            cachedCodec = codec
        }
        return (
            try SwiftReceiverPlan(
                codec: codec,
                metadata: metadata,
                isMutating: isMutating,
                isConsuming: isConsuming,
                validateClass: representation != nil && representation != metadata
            ),
            cachedCodec
        )
    }

    private nonisolated func resolveDeclaredMember(
        _ declaration: NativeDeclaration,
        in image: NativeImage,
        exact: Bool = false,
        genericContext: () throws -> SwiftGenericContext? = { nil }
    ) throws -> ResolvedSymbol {
        do {
            return try resolver.resolve(declaration, in: image, loading: .loadedOnly)
        } catch ABIResolutionError.declarationNotFound {
            if exact {
                let key = DeclarationKey.make(declaration.name, language: .swift)
                let matches = try resolver.swiftDeclarationCandidates(
                    declaration,
                    in: nil,
                    extensionsOnly: true
                ).filter {
                    let name = $0.declaration.name
                    return DeclarationKey.make(name, language: .swift) == key
                        || SymbolIndex.extensionMemberName(name).map {
                            DeclarationKey.make($0, language: .swift) == key
                        } == true
                }
                guard matches.count == 1 else {
                    if matches.isEmpty { throw ABIResolutionError.declarationNotFound(declaration) }
                    throw ABIResolutionError.ambiguousDeclaration(
                        declaration,
                        candidates: matches.map(\.linkageName)
                    )
                }
                return matches[0]
            }
            return try resolver.resolveSwiftExtension(declaration, genericContext: genericContext())
        }
    }

    // Generic packs expand caller arguments without changing the source labels.
    // Their requests keep those labels until declaration binding determines arity.
    private typealias ResolvedMember = (
        symbol: ResolvedSymbol, metadata: Any.Type, generic: SwiftGenericCallPlan?
    )

    private nonisolated func resolveMember(
        signature: Any.Type? = nil,
        genericArguments: [NativeSwiftGenericArgument] = [],
        inherited: Bool = true,
        exact: Bool = false,
        explicitSignature: Bool = false,
        declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        _ declaration: @Sendable (String, Bool) throws -> NativeDeclaration
    ) throws -> ResolvedMember {
        var originalRequest: NativeDeclaration?
        var ownerClass: AnyClass? = metadata as? AnyClass
        var ownerImage = image
        var ownerName = try declarationName()
        var hasUnavailableExtensions = false
        var preparationFailure: (any Error)?
        while true {
            let owner: Any.Type = ownerClass ?? metadata
            let enclosing =
                try owner == metadata ? genericMetadata : SwiftGenericTypeMetadata(metadata: owner)
            let usesBinding =
                try signature != nil
                && (!(enclosing?.arguments.isEmpty ?? true) || !genericArguments.isEmpty
                    || declaredSignature != nil || !valueABIs.isEmpty
                    || SwiftFunctionSignature(signature!).requiresValueDeclaration)
            let request = try declaration(ownerName, usesBinding)
            if originalRequest == nil { originalRequest = request }
            let belongs = !exact || SwiftMemberLookup.belongs(request.name, to: ownerName)
            if belongs && (!usesBinding || exact || explicitSignature) {
                do {
                    let symbol: ResolvedSymbol
                    if usesBinding && explicitSignature && !exact {
                        // Extensions still need candidate binding to preserve constraints and their declaration names.
                        symbol = try resolver.resolve(request, in: ownerImage, loading: .loadedOnly)
                    } else {
                        symbol = try resolveDeclaredMember(request, in: ownerImage, exact: exact) {
                            try ownerClass.flatMap { try SwiftGenericContext($0, owner: ownerName) }
                        }
                    }
                    let generic: SwiftGenericCallPlan?
                    if usesBinding, let signature {
                        generic = try genericPlan(
                            (symbol, owner),
                            signature: signature,
                            arguments: genericArguments,
                            declaredSignature: declaredSignature,
                            valueABIs: valueABIs
                        )
                    } else {
                        generic = nil
                    }
                    return (symbol, owner, generic)
                } catch ABIResolutionError.declarationNotFound {
                } catch ABIResolutionError.signatureMismatch
                    where usesBinding && explicitSignature && !exact
                {
                    // Preserve candidate filtering and diagnostics when the direct match cannot bind.
                } catch ABIResolutionError.unsupportedDeclaration(let reason) {
                    preparationFailure = ABIResolutionError.unsupportedDeclaration(reason)
                } catch ABIResolutionError.imageUnavailable {
                    hasUnavailableExtensions = true
                }
            }
            if belongs && usesBinding && !exact, let signature {
                do {
                    for extensionsOnly in [false, true] {
                        let candidates = try resolver.swiftDeclarationCandidates(
                            request,
                            in: extensionsOnly ? nil : ownerImage,
                            extensionsOnly: extensionsOnly
                        )
                        let matches = candidates.compactMap { symbol -> ResolvedMember? in
                            if explicitSignature,
                                ![
                                    symbol.declaration.name,
                                    SymbolIndex.operatorAlias(symbol.declaration.name),
                                ].compactMap({ $0 }).contains(where: {
                                    SwiftMemberLookup.signatureKey($0)
                                        == SwiftMemberLookup.signatureKey(request.name)
                                })
                            {
                                return nil
                            }
                            do {
                                guard
                                    let plan = try genericPlan(
                                        (symbol, owner),
                                        signature: signature,
                                        arguments: genericArguments,
                                        declaredSignature: declaredSignature,
                                        valueABIs: valueABIs
                                    )
                                else { return nil }
                                guard
                                    try explicitSignature
                                        || plan.matches(SwiftFunctionSignature(signature))
                                else { return nil }
                                return (symbol, owner, plan)
                            } catch ABIResolutionError.signatureMismatch { return nil } catch {
                                preparationFailure = error
                                return nil
                            }
                        }
                        if matches.count > 1 {
                            throw ABIResolutionError.ambiguousDeclaration(
                                request,
                                candidates: matches.map { $0.symbol.linkageName }
                            )
                        }
                        if let match = matches.first { return match }
                    }
                } catch ABIResolutionError.imageUnavailable {
                    hasUnavailableExtensions = true
                } catch ABIResolutionError.unsupportedDeclaration(let reason) {
                    preparationFailure = ABIResolutionError.unsupportedDeclaration(reason)
                }
            }
            guard inherited, let current = ownerClass, let parent = class_getSuperclass(current)
            else {
                if hasUnavailableExtensions { throw ABIResolutionError.imageUnavailable }
                if let preparationFailure { throw preparationFailure }
                throw ABIResolutionError.declarationNotFound(originalRequest!)
            }
            let runtimeName = try swiftFunctionTypeName(parent)
            ownerClass = parent
            ownerImage = try swiftClassImage(parent, named: runtimeName, resolver: resolver)
            ownerName = try swiftTypeDeclarationName(
                parent,
                in: ownerImage,
                suggestedName: runtimeName,
                resolver: resolver
            )
        }
    }

    /// Resolves a concrete instance implementation using a function-type metatype.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// The signature excludes self. Mutating value members require an explicit mutating flag because their source-level symbol does not encode it. Consuming members similarly require consuming: true. Typed receivers transfer a copy; NativeSwiftValue transfers its owned value. Borrowed views allow nonconsuming calls within their active scope; only native inout callback borrows permit mutation.
    ///
    /// For runtime-only self, receiverABI supplies established fixed components or an opaque descriptor for formally indirect self. Metadata supplies storage dimensions, not the declaration's passing convention.
    /// - Parameters:
    ///   - name: A relative member name or a complete qualified declaration.
    ///   - signature: Explicit arguments and result.
    ///   - genericArguments: Type arguments introduced by the member.
    ///   - valueABIs: Formal ABIs for runtime-only closed nominal values in this lookup.
    ///   - declaredSignature: The formal function type and optional canonical generic signature when binary metadata is insufficient.
    ///   - receiverABI: Explicit self ABI; nil uses the type representation or generic declaration.
    ///   - isMutating: Whether a value receiver is passed inout.
    ///   - isConsuming: Whether the member consumes its receiver.
    /// - Returns: A reusable method with an explicit receiver.
    /// - Throws: A lookup, representation, or preparation error.
    public nonisolated func resolveMethodAndWait<Signature>(
        named name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        receiverABI: NativeType? = nil,
        mutating isMutating: Bool = false,
        consuming isConsuming: Bool = false
    ) throws -> NativeSwiftMethod<Signature> {
        let symbol = try resolveMember(
            signature: signature,
            genericArguments: genericArguments,
            exact: SwiftMemberLookup.isQualified(name),
            explicitSignature: SwiftMemberLookup.hasSignature(name),
            declaredSignature: declaredSignature,
            valueABIs: valueABIs
        ) { owner, usesBinding in
            let member = try SwiftMemberLookup.qualifiedName(name, owner: owner)
            return try usesBinding
                ? NativeDeclaration(name: member, language: .swift)
                : swiftFunctionDeclaration(named: member, as: signature)
        }
        let generic = symbol.generic
        let receiver = try receiverPlan(
            mutating: isMutating,
            consuming: isConsuming,
            generic: generic,
            receiverABI: receiverABI
        )
        return try prepareMethod(symbol, receiver: receiver)
    }

    /// Resolves and prepares a method without blocking the caller's executor.
    ///
    /// Lookup and preparation run on a worker. Receivers remain with the caller, and lookup does not invoke the member.
    /// - Returns: A reusable handle retaining its type and implementation.
    /// - Throws: The same lookup, representation, and preparation errors.
    public nonisolated func resolveMethod<Signature>(
        named name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        receiverABI: NativeType? = nil,
        mutating isMutating: Bool = false,
        consuming isConsuming: Bool = false
    ) async throws -> NativeSwiftMethod<Signature> {
        try await NativePreparation.run {
            try self.resolveMethodAndWait(
                named: name,
                as: signature,
                genericArguments: genericArguments,
                declaredAs: declaredSignature,
                valueABIs: valueABIs,
                receiverABI: receiverABI,
                mutating: isMutating,
                consuming: isConsuming
            )
        }
    }

    private nonisolated func genericPlan(
        _ member: (symbol: ResolvedSymbol, metadata: Any.Type),
        signature: Any.Type,
        arguments: [NativeSwiftGenericArgument] = [],
        receiver: SwiftReceiverMode? = nil,
        declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) throws -> SwiftGenericCallPlan? {
        let enclosing =
            try member.metadata == metadata
            ? genericMetadata : SwiftGenericTypeMetadata(metadata: member.metadata)
        guard
            try !(enclosing?.arguments.isEmpty ?? true) || !arguments.isEmpty
                || declaredSignature != nil || !valueABIs.isEmpty
                || SwiftFunctionSignature(signature).requiresValueDeclaration
        else { return nil }
        return try SwiftGenericCallPlan(
            symbol: member.symbol,
            genericArguments: arguments,
            signature: SwiftFunctionSignature(signature),
            resolver: resolver,
            enclosing: enclosing,
            receiver: receiver,
            declaredSignature: declaredSignature,
            valueABIs: valueABIs
        )
    }

    private nonisolated func prepareMethod<Signature>(
        _ member: ResolvedMember,
        receiver: SwiftReceiverPlan,
        consumesArguments: Bool = false
    ) throws -> NativeSwiftMethod<Signature> {
        try NativeSwiftMethod(
            symbol: member.symbol,
            type: self,
            receiver: receiver,
            consumesArguments: consumesArguments,
            generic: member.generic?.includingReceiver(receiver.mode)
        )
    }

    private nonisolated func prepareFunction<Signature>(
        _ member: ResolvedMember,
        consumesArguments: Bool = false,
        classReceiver: Bool
    ) throws -> NativeSwiftFunction<Signature> {
        try NativeSwiftFunction(
            symbol: member.symbol,
            metadata: metadata,
            owner: self,
            consumesArguments: consumesArguments,
            generic: classReceiver
                ? member.generic.map { try $0.includingReceiver(.object) } : member.generic
        )
    }

    private nonisolated func initializerResultName(
        _ signature: Any.Type
    ) throws -> String {
        let name = try declarationName()
        return try SwiftFunctionSignature(signature).result is any NativeOptionalValue.Type
            ? "Swift.Optional<" + name + ">" : name
    }
    /// Resolves a concrete allocating initializer.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// Ordinary initializer arguments transfer ownership to the callee. The native metadata is supplied automatically, and the result uses the requested Swift class or fixed-layout value adapter. NativeSwiftBorrowing selects an explicitly borrowed initializer parameter.
    /// - Parameters:
    ///   - name: The relative initializer name, such as init(text:).
    ///   - signature: Explicit arguments and constructed result.
    ///   - genericArguments: Type arguments introduced by the initializer.
    ///   - valueABIs: Formal ABIs for runtime-only closed nominal values in this lookup.
    ///   - declaredSignature: The formal function type and optional canonical generic signature when binary metadata is insufficient.
    /// - Returns: A reusable initializer retaining its type and implementation.
    /// - Throws: A lookup, representation, or preparation error.
    public nonisolated func resolveInitializerAndWait<Signature>(
        named name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) throws -> NativeSwiftFunction<Signature> {
        guard name.hasPrefix("init(") || name.hasPrefix("init<") else {
            throw ABIResolutionError.unsupportedDeclaration(
                "An initializer name must start with init( or init<."
            )
        }
        let member = metadata is AnyClass ? "__allocating_" + name : name
        let resultName = try initializerResultName(signature)
        let symbol = try resolveMember(
            signature: signature,
            genericArguments: genericArguments,
            inherited: false,
            explicitSignature: SwiftMemberLookup.hasSignature(name),
            declaredSignature: declaredSignature,
            valueABIs: valueABIs
        ) { owner, usesBinding in
            try usesBinding
                ? NativeDeclaration(name: owner + "." + member, language: .swift)
                : swiftFunctionDeclaration(
                    named: owner + "." + member,
                    as: signature,
                    resultName: resultName,
                    defaultConsuming: true
                )
        }
        return try prepareFunction(
            symbol,
            consumesArguments: true,
            classReceiver: metadata is AnyClass
        )
    }

    /// Resolves and prepares an initializer without blocking the caller's executor.
    ///
    /// Lookup and preparation run on a worker; native invocation is a separate operation.
    /// - Returns: A reusable handle retaining its type and implementation.
    /// - Throws: The same lookup, representation, and preparation errors.
    public nonisolated func resolveInitializer<Signature>(
        named name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) async throws -> NativeSwiftFunction<Signature> {
        try await NativePreparation.run {
            try self.resolveInitializerAndWait(
                named: name,
                as: signature,
                genericArguments: genericArguments,
                declaredAs: declaredSignature,
                valueABIs: valueABIs
            )
        }
    }

    /// Resolves a concrete static or class implementation.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// The declaring type's metadata is supplied as the Swift context.
    /// - Parameters:
    ///   - name: A relative member name or a complete qualified declaration.
    ///   - signature: Explicit arguments and result.
    ///   - genericArguments: Type arguments introduced by the member.
    ///   - valueABIs: Formal ABIs for runtime-only closed nominal values in this lookup.
    ///   - declaredSignature: The formal function type and optional canonical generic signature when binary metadata is insufficient.
    /// - Returns: A reusable function retaining its type and implementation.
    /// - Throws: A lookup, representation, or preparation error.
    public nonisolated func resolveStaticMethodAndWait<Signature>(
        named name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) throws -> NativeSwiftFunction<Signature> {
        let symbol = try resolveMember(
            signature: signature,
            genericArguments: genericArguments,
            exact: SwiftMemberLookup.isQualified(name),
            explicitSignature: SwiftMemberLookup.hasSignature(name),
            declaredSignature: declaredSignature,
            valueABIs: valueABIs
        ) { owner, usesBinding in
            let member = try SwiftMemberLookup.qualifiedName(name, owner: owner, isStatic: true)
            return try usesBinding
                ? NativeDeclaration(name: member, language: .swift)
                : swiftFunctionDeclaration(named: member, as: signature)
        }
        return try prepareFunction(symbol, classReceiver: symbol.metadata is AnyClass)
    }

    /// Resolves and prepares a static or class method without blocking the caller's executor.
    ///
    /// Lookup and preparation run on a worker; native invocation is a separate operation.
    /// - Returns: A reusable handle retaining its type and implementation.
    /// - Throws: The same lookup, representation, and preparation errors.
    public nonisolated func resolveStaticMethod<Signature>(
        named name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) async throws -> NativeSwiftFunction<Signature> {
        try await NativePreparation.run {
            try self.resolveStaticMethodAndWait(
                named: name,
                as: signature,
                genericArguments: genericArguments,
                declaredAs: declaredSignature,
                valueABIs: valueABIs
            )
        }
    }

    private nonisolated func accessorDeclaration(
        named name: String,
        ownerName: String,
        valueType: Any.Type,
        setter: Bool,
        isStatic: Bool
    ) throws -> NativeDeclaration {
        let accessor = setter ? ".setter : " : ".getter : "
        let member: String
        if name.contains(accessor) {
            member = name
        } else {
            let valueName =
                valueType == (representation ?? metadata)
                ? try declarationName() : try swiftFunctionTypeName(valueType)
            member = name + accessor + valueName
        }
        return .init(
            name: try SwiftMemberLookup.qualifiedName(member, owner: ownerName, isStatic: isStatic),
            language: .swift
        )
    }

    /// Resolves a property setter that consumes its incoming value.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// Class receivers are references. Ordinary value setters receive self inout; consuming setters transfer a typed copy or NativeSwiftValue's owned value. An explicitly nonmutating setter can use mutating: false.
    /// - Parameters:
    ///   - name: A property name or complete relative setter declaration.
    ///   - valueType: The incoming value representation.
    ///   - valueABIs: Formal ABIs for runtime-only closed nominal values in this lookup.
    ///   - declaredSignature: The formal setter type and optional canonical generic signature.
    ///   - receiverABI: Explicit self ABI; nil uses the type representation or generic declaration.
    ///   - isMutating: An inout override. Nil selects inout unless consuming is true.
    ///   - isConsuming: Whether the setter consumes its receiver.
    /// - Returns: A reusable method with one explicit value argument.
    /// - Throws: A lookup or unsupported-representation error.
    public nonisolated func resolveSetterAndWait<Value>(
        named name: String,
        as valueType: Value.Type,
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        receiverABI: NativeType? = nil,
        mutating isMutating: Bool? = nil,
        consuming isConsuming: Bool = false
    ) throws -> NativeSwiftMethod<(Value) -> Void> {
        let symbol = try resolveMember(
            signature: ((Value) -> Void).self,
            exact: SwiftMemberLookup.isQualified(name),
            explicitSignature: SwiftMemberLookup.hasSignature(name),
            declaredSignature: declaredSignature,
            valueABIs: valueABIs
        ) { owner, _ in
            try accessorDeclaration(
                named: name,
                ownerName: owner,
                valueType: valueType,
                setter: true,
                isStatic: false
            )
        }
        let generic = symbol.generic
        let receiver = try receiverPlan(
            mutating: isMutating ?? !isConsuming,
            consuming: isConsuming,
            generic: generic,
            receiverABI: receiverABI
        )
        return try prepareMethod(symbol, receiver: receiver, consumesArguments: true)
    }

    /// Resolves and prepares a property setter without blocking the caller's executor.
    ///
    /// Lookup and preparation run on a worker; native invocation is a separate operation.
    /// - Returns: A reusable handle retaining its type and implementation.
    /// - Throws: The same lookup, representation, and preparation errors.
    public nonisolated func resolveSetter<Value>(
        named name: String,
        as valueType: Value.Type,
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        receiverABI: NativeType? = nil,
        mutating isMutating: Bool? = nil,
        consuming isConsuming: Bool = false
    ) async throws -> NativeSwiftMethod<(Value) -> Void> {
        try await NativePreparation.run {
            try self.resolveSetterAndWait(
                named: name,
                as: valueType,
                declaredAs: declaredSignature,
                valueABIs: valueABIs,
                receiverABI: receiverABI,
                mutating: isMutating,
                consuming: isConsuming
            )
        }
    }

    /// Resolves a static property setter that consumes its incoming value.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// - Parameters:
    ///   - name: A property name or complete relative setter declaration.
    ///   - valueType: The incoming value representation.
    ///   - valueABIs: Formal ABIs for runtime-only closed nominal values in this lookup.
    ///   - declaredSignature: The formal setter type and optional canonical generic signature.
    /// - Returns: A one-argument function with bound type metadata.
    /// - Throws: A lookup or unsupported-representation error.
    public nonisolated func resolveStaticSetterAndWait<Value>(
        named name: String,
        as valueType: Value.Type,
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) throws -> NativeSwiftFunction<(Value) -> Void> {
        let symbol = try resolveMember(
            signature: ((Value) -> Void).self,
            exact: SwiftMemberLookup.isQualified(name),
            explicitSignature: SwiftMemberLookup.hasSignature(name),
            declaredSignature: declaredSignature,
            valueABIs: valueABIs
        ) { owner, _ in
            try accessorDeclaration(
                named: name,
                ownerName: owner,
                valueType: valueType,
                setter: true,
                isStatic: true
            )
        }
        return try prepareFunction(
            symbol,
            consumesArguments: true,
            classReceiver: symbol.metadata is AnyClass
        )
    }

    /// Resolves and prepares a static property setter without blocking the caller's executor.
    ///
    /// Lookup and preparation run on a worker; native invocation is a separate operation.
    /// - Returns: A reusable handle retaining its type and implementation.
    /// - Throws: The same lookup, representation, and preparation errors.
    public nonisolated func resolveStaticSetter<Value>(
        named name: String,
        as valueType: Value.Type,
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) async throws -> NativeSwiftFunction<(Value) -> Void> {
        try await NativePreparation.run {
            try self.resolveStaticSetterAndWait(
                named: name,
                as: valueType,
                declaredAs: declaredSignature,
                valueABIs: valueABIs
            )
        }
    }

}

func swiftClassImage(
    _ type: AnyClass,
    named name: String,
    resolver: SymbolResolver
) throws -> NativeImage {
    try withRuntimeErrors {
        NativeImage(try runtimeClassImage(type, named: name, resolver: resolver.runtime))
    }
}

func swiftTypeDeclarationName(
    _ type: Any.Type,
    in image: NativeImage,
    suggestedName: String,
    resolver: SymbolResolver
) throws -> String {
    try withRuntimeErrors {
        try runtimeTypeDeclarationName(
            type,
            in: image.runtimeValue,
            suggestedName: suggestedName,
            resolver: resolver.runtime
        )
    }
}

extension ABIRuntime {
    nonisolated func swiftType(for objectType: AnyClass) throws -> NativeSwiftType {
        let revision = swiftTypeCache.revision
        let (runtimeName, image) = try swiftTypeImage(for: objectType)
        let key = SwiftTypeCacheKey.metadata(ObjectIdentifier(objectType), image: image.identity)
        if let cached = swiftTypeCache.value(for: key) { return cached }
        let type = try prepareSwiftType(
            for: objectType,
            in: image,
            suggestedName: runtimeName
        )
        return swiftTypeCache.insert(type, for: key, revision: revision)
    }

    private nonisolated func swiftTypeImage(
        for objectType: AnyClass
    ) throws -> (String, NativeImage) {
        let runtimeName = try swiftFunctionTypeName(objectType)
        let image = try swiftClassImage(objectType, named: runtimeName, resolver: resolver)
        return (runtimeName, image)
    }

    private nonisolated func prepareSwiftType(
        for objectType: AnyClass,
        in image: NativeImage,
        suggestedName: String
    ) throws -> NativeSwiftType {
        let name = try swiftTypeDeclarationName(
            objectType,
            in: image,
            suggestedName: suggestedName,
            resolver: resolver
        )
        return NativeSwiftType(
            name: name,
            image: image,
            metadata: objectType,
            representation: nil,
            resolver: resolver,
            genericMetadata: try SwiftGenericTypeMetadata(metadata: objectType)
        )
    }

    /// Resolves a concrete Swift class, struct, or enum and caches its metadata.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// - Parameters:
    ///   - name: A module-qualified nominal type name.
    ///   - scope: Images to search; automatic scope stays loaded-only.
    ///   - loading: Whether an explicit target may be acquired and initialized.
    ///   - genericArguments: Type arguments in outer-to-inner declaration order.
    /// - Returns: A reusable type handle retaining its defining image.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public nonisolated func resolveSwiftTypeAndWait(
        named name: String,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) throws -> NativeSwiftType {
        let revision = swiftTypeCache.revision
        let descriptor = try resolve(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data),
            in: scope,
            loading: loading
        )
        return try makeSwiftType(
            named: name,
            descriptor: descriptor,
            representation: nil,
            genericArguments: genericArguments,
            revision: revision
        )
    }

    /// Resolves a Swift type without blocking the caller's executor.
    ///
    /// Image acquisition, search, and metadata discovery run on a worker.
    /// - Returns: A reusable type handle retaining its implementation images.
    /// - Throws: The same lookup and metadata errors.
    public nonisolated func resolveSwiftType(
        named name: String,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) async throws -> NativeSwiftType {
        try await prepare { runtime in
            try runtime.resolveSwiftTypeAndWait(
                named: name,
                in: scope,
                loading: loading,
                genericArguments: genericArguments
            )
        }
    }

    /// Resolves a concrete Swift type within an already retained image.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// - Parameters:
    ///   - name: A module-qualified nominal type name.
    ///   - image: The image whose symbol index is reused.
    ///   - loading: Whether to ask dyld to acquire and initialize the image.
    ///   - genericArguments: Type arguments in outer-to-inner declaration order.
    /// - Returns: A reusable type handle retaining the image.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public nonisolated func resolveSwiftTypeAndWait(
        named name: String,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) throws -> NativeSwiftType {
        let revision = swiftTypeCache.revision
        let descriptor = try resolve(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data),
            in: image,
            loading: loading
        )
        return try makeSwiftType(
            named: name,
            descriptor: descriptor,
            representation: nil,
            genericArguments: genericArguments,
            revision: revision
        )
    }

    /// Resolves a Swift type without blocking the caller's executor.
    ///
    /// Image acquisition, search, and metadata discovery run on a worker.
    /// - Returns: A reusable type handle retaining its implementation images.
    /// - Throws: The same lookup and metadata errors.
    public nonisolated func resolveSwiftType(
        named name: String,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) async throws -> NativeSwiftType {
        try await prepare { runtime in
            try runtime.resolveSwiftTypeAndWait(
                named: name,
                in: image,
                loading: loading,
                genericArguments: genericArguments
            )
        }
    }

    /// Resolves a Swift type with an explicit receiver representation.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// Use an ABIBridgeValue adapter when the native type cannot be imported. The representation describes fixed storage and ownership; it does not establish ABI compatibility with a resilient or generic declaration.
    /// - Parameters:
    ///   - name: The qualified native type name.
    ///   - representation: A Swift type or adapter for receiver values.
    ///   - genericArguments: Type arguments in outer-to-inner declaration order.
    ///   - scope: Images to search; automatic scope stays loaded-only.
    ///   - loading: Whether an explicit target may be acquired and initialized.
    /// - Returns: A reusable type handle with the chosen receiver representation.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public nonisolated func resolveSwiftTypeAndWait<Representation>(
        named name: String,
        as representation: Representation.Type,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) throws -> NativeSwiftType {
        let revision = swiftTypeCache.revision
        let descriptor = try resolve(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data),
            in: scope,
            loading: loading
        )
        return try makeSwiftType(
            named: name,
            descriptor: descriptor,
            representation: representation,
            genericArguments: genericArguments,
            revision: revision
        )
    }

    /// Resolves a Swift type without blocking the caller's executor.
    ///
    /// Image acquisition, search, and metadata discovery run on a worker.
    /// - Returns: A reusable type handle retaining its implementation images.
    /// - Throws: The same lookup and metadata errors.
    public nonisolated func resolveSwiftType<Representation>(
        named name: String,
        as representation: Representation.Type,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) async throws -> NativeSwiftType {
        try await prepare { runtime in
            try runtime.resolveSwiftTypeAndWait(
                named: name,
                as: representation,
                in: scope,
                loading: loading,
                genericArguments: genericArguments
            )
        }
    }

    /// Resolves a Swift type and receiver adapter within a retained image.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// - Parameters:
    ///   - name: The qualified native type name.
    ///   - representation: A Swift type or fixed-layout receiver adapter.
    ///   - genericArguments: Type arguments in outer-to-inner declaration order.
    ///   - image: The image whose symbol index is reused.
    ///   - loading: Whether to ask dyld to acquire and initialize the image.
    /// - Returns: A reusable type handle with the chosen representation.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public nonisolated func resolveSwiftTypeAndWait<Representation>(
        named name: String,
        as representation: Representation.Type,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) throws -> NativeSwiftType {
        let revision = swiftTypeCache.revision
        let descriptor = try resolve(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data),
            in: image,
            loading: loading
        )
        return try makeSwiftType(
            named: name,
            descriptor: descriptor,
            representation: representation,
            genericArguments: genericArguments,
            revision: revision
        )
    }

    /// Resolves a Swift type without blocking the caller's executor.
    ///
    /// Image acquisition, search, and metadata discovery run on a worker.
    /// - Returns: A reusable type handle retaining its implementation images.
    /// - Throws: The same lookup and metadata errors.
    public nonisolated func resolveSwiftType<Representation>(
        named name: String,
        as representation: Representation.Type,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) async throws -> NativeSwiftType {
        try await prepare { runtime in
            try runtime.resolveSwiftTypeAndWait(
                named: name,
                as: representation,
                in: image,
                loading: loading,
                genericArguments: genericArguments
            )
        }
    }

    private nonisolated func makeSwiftType(
        named name: String,
        descriptor: ResolvedSymbol,
        representation: Any.Type?,
        genericArguments: [NativeSwiftGenericArgument],
        revision: UInt64
    ) throws -> NativeSwiftType {
        let key = SwiftTypeCacheKey.declaration(
            name: name,
            image: descriptor.image.identity,
            representation: representation.map(ObjectIdentifier.init),
            arguments: genericArguments.map(\.identity)
        )
        if let cached = swiftTypeCache.value(for: key, retaining: genericArguments) {
            return cached
        }
        let type = try prepareSwiftType(
            named: name,
            descriptor: descriptor,
            representation: representation,
            genericArguments: genericArguments
        )
        return swiftTypeCache.insert(
            type,
            for: key,
            revision: revision,
            retaining: genericArguments
        )
    }

    private nonisolated func prepareSwiftType(
        named name: String,
        descriptor: ResolvedSymbol,
        representation: Any.Type?,
        genericArguments: [NativeSwiftGenericArgument]
    ) throws -> NativeSwiftType {
        guard descriptor.sectionRange.upperBound - descriptor.address >= 4 else {
            throw ABIResolutionError.metadataUnavailable(
                "Incomplete Swift type descriptor for " + name
            )
        }
        let metadata = try SwiftGenericTypeMetadata(
            descriptor: descriptor,
            arguments: genericArguments
        )
        return NativeSwiftType(
            name: name,
            image: descriptor.image,
            metadata: metadata.value,
            representation: representation,
            resolver: resolver,
            genericMetadata: metadata
        )
    }
}

extension NativeSwiftType {
    /// Resolves a property getter using its complete zero-argument function type.
    ///
    /// Search and preparation run synchronously on the caller's thread.
    ///
    /// Use (() -> Value).self for a synchronous nonthrowing getter. Include its native throws type, async effect, and isolation convention when present.
    ///
    /// For a throwing generic getter, declaredAs supplies the source function type, such as "() throws(B) -> A". Getter symbols omit the formal error type; A and B refer to the enclosing declaration's generic parameters. valueABIs supplies formal ABIs for runtime-only closed nominal values. Receiver ownership and writeback follow the ordinary member contract. receiverABI can describe runtime-only fixed components or formally indirect self, as for method lookup.
    public nonisolated func resolveGetterAndWait<Signature>(
        named name: String,
        as signature: Signature.Type,
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        receiverABI: NativeType? = nil,
        mutating isMutating: Bool = false,
        consuming isConsuming: Bool = false
    ) throws -> NativeSwiftMethod<Signature> {
        let result = try getterResult(signature)
        let symbol = try resolveMember(
            signature: signature,
            exact: SwiftMemberLookup.isQualified(name),
            explicitSignature: SwiftMemberLookup.hasSignature(name),
            declaredSignature: declaredSignature,
            valueABIs: valueABIs
        ) { owner, _ in
            try accessorDeclaration(
                named: name,
                ownerName: owner,
                valueType: result,
                setter: false,
                isStatic: false
            )
        }
        let generic = symbol.generic
        let receiver = try receiverPlan(
            mutating: isMutating,
            consuming: isConsuming,
            generic: generic,
            receiverABI: receiverABI
        )
        return try prepareMethod(symbol, receiver: receiver)
    }

    /// Resolves and prepares a getter without blocking the caller's executor.
    ///
    /// Lookup and preparation run on a worker. Receivers remain with the caller, and lookup does not invoke the member.
    /// - Returns: A reusable handle retaining its type and implementation.
    /// - Throws: The same lookup, representation, and preparation errors.
    public nonisolated func resolveGetter<Signature>(
        named name: String,
        as signature: Signature.Type,
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        receiverABI: NativeType? = nil,
        mutating isMutating: Bool = false,
        consuming isConsuming: Bool = false
    ) async throws -> NativeSwiftMethod<Signature> {
        try await NativePreparation.run {
            try self.resolveGetterAndWait(
                named: name,
                as: signature,
                declaredAs: declaredSignature,
                valueABIs: valueABIs,
                receiverABI: receiverABI,
                mutating: isMutating,
                consuming: isConsuming
            )
        }
    }

    /// Resolves a static getter using its complete zero-argument function type.
    ///
    /// Search and preparation run synchronously on the caller's thread. Native error, async, and isolation effects remain part of the signature. Throwing generic getters also require their source type in declaredAs. valueABIs supplies formal ABIs for runtime-only closed nominal values.
    public nonisolated func resolveStaticGetterAndWait<Signature>(
        named name: String,
        as signature: Signature.Type,
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) throws -> NativeSwiftFunction<Signature> {
        let result = try getterResult(signature)
        let symbol = try resolveMember(
            signature: signature,
            exact: SwiftMemberLookup.isQualified(name),
            explicitSignature: SwiftMemberLookup.hasSignature(name),
            declaredSignature: declaredSignature,
            valueABIs: valueABIs
        ) { owner, _ in
            try accessorDeclaration(
                named: name,
                ownerName: owner,
                valueType: result,
                setter: false,
                isStatic: true
            )
        }
        return try prepareFunction(symbol, classReceiver: symbol.metadata is AnyClass)
    }

    /// Resolves and prepares a static or class property getter without blocking the caller's executor.
    ///
    /// Lookup and preparation run on a worker; native invocation is a separate operation.
    /// - Returns: A reusable handle retaining its type and implementation.
    /// - Throws: The same lookup, representation, and preparation errors.
    public nonisolated func resolveStaticGetter<Signature>(
        named name: String,
        as signature: Signature.Type,
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) async throws -> NativeSwiftFunction<Signature> {
        try await NativePreparation.run {
            try self.resolveStaticGetterAndWait(
                named: name,
                as: signature,
                declaredAs: declaredSignature,
                valueABIs: valueABIs
            )
        }
    }

    private nonisolated func getterResult(_ signature: Any.Type) throws -> Any.Type {
        let description = try SwiftFunctionSignature(signature)
        guard description.parameters.isEmpty else {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    expected: "A zero-argument getter signature",
                    found: [String(reflecting: signature)]
                )
            )
        }
        return description.result
    }
}
