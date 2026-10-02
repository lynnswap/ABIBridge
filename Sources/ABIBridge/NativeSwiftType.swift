import Foundation
import ObjectiveC

enum SwiftTypeCacheKey: Hashable {
    case declaration(name: String, image: NativeImageIdentity, representation: ObjectIdentifier?, arguments: [NativeSwiftGenericArgument.Identity])
    case metadata(ObjectIdentifier, image: NativeImageIdentity)
}

struct SwiftMetadataResponse: BitwiseCopyable, ABIBridgeValue {
    let address: UInt
    let state: UInt
    static let abiType = try! NativeType.structure(
        named: "Swift.MetadataResponse", fields: [.uint, .uint]
    )
    init(nativeValue: NativeValue) throws {
        self = try unsafe nativeValue.read(as: Self.self)
    }
    static func nativeValue(from value: Self) throws -> NativeValue {
        try .init(copying: value, as: abiType)
    }
}

/// A cached concrete Swift type and its retained implementation image.
///
/// Type lookup requests complete metadata without constructing an instance.
/// Generic arguments are validated by the Swift runtime. Member lookups reuse
/// the image's existing symbol index.
public actor NativeSwiftType {
    /// The qualified source-level name of the nominal type.
    public nonisolated let name: String
    /// The image defining the nominal type descriptor.
    public nonisolated let image: NativeImage

    let metadata: Any.Type
    let representation: Any.Type?
    let resolver: SymbolResolver
    let genericMetadata: SwiftGenericTypeMetadata?
    var genericArguments: [NativeSwiftGenericArgument] { genericMetadata?.arguments ?? [] }
    private var cachedReceiver: SwiftReceiverCodec?

    init(name: String, image: NativeImage, metadata: Any.Type,
         representation: Any.Type?, resolver: SymbolResolver,
         genericMetadata: SwiftGenericTypeMetadata? = nil) {
        self.name = name
        self.image = image
        self.metadata = metadata
        self.representation = representation
        self.resolver = resolver
        self.genericMetadata = genericMetadata
    }

    func receiverPlan(mutating isMutating: Bool, consuming isConsuming: Bool = false) throws -> SwiftReceiverPlan {
        if cachedReceiver == nil {
            cachedReceiver = try SwiftReceiverCodec.make(for: representation ?? metadata)
        }
        return try SwiftReceiverPlan(
            codec: cachedReceiver!, metadata: metadata, isMutating: isMutating, isConsuming: isConsuming,
            validateClass: representation != nil && representation != metadata
        )
    }

    private func resolveDeclaredMember(
        _ declaration: NativeDeclaration, in image: NativeImage,
        genericContext: () throws -> SwiftGenericContext? = { nil }
    ) throws -> ResolvedSymbol {
        do { return try resolver.resolve(declaration, in: image, loading: .loadedOnly) }
        catch ABIResolutionError.declarationNotFound {
            return try resolver.resolveSwiftExtension(declaration, genericContext: genericContext())
        }
    }

    private func resolveMember(
        _ declaration: (String) throws -> NativeDeclaration
    ) throws -> ResolvedSymbol {
        let originalRequest = try declaration(name)
        var request = originalRequest
        var ownerClass: AnyClass? = metadata as? AnyClass
        var ownerImage = image
        var ownerName = name
        var hasUnavailableExtensions = false
        var unsupported: ABIResolutionError?
        while true {
            do {
                return try resolveDeclaredMember(request, in: ownerImage) {
                    try ownerClass.flatMap { try SwiftGenericContext($0, owner: ownerName) }
                }
            } catch ABIResolutionError.declarationNotFound {
            } catch ABIResolutionError.unsupportedDeclaration(let reason) {
                unsupported = .unsupportedDeclaration(reason)
            } catch ABIResolutionError.imageUnavailable {
                // An incomplete extension search must not hide an available
                // superclass member. Preserve uncertainty if no owner matches.
                hasUnavailableExtensions = true
            }
            guard let current = ownerClass, let parent = class_getSuperclass(current) else {
                if hasUnavailableExtensions { throw ABIResolutionError.imageUnavailable }
                if let unsupported { throw unsupported }
                throw ABIResolutionError.declarationNotFound(originalRequest)
            }
            let runtimeName = try swiftFunctionTypeName(parent)
            ownerClass = parent
            ownerImage = try swiftClassImage(parent, named: runtimeName, resolver: resolver)
            ownerName = try swiftClassDeclarationName(parent, in: ownerImage, suggestedName: runtimeName, resolver: resolver)
            request = try declaration(ownerName)
        }
    }

    /// Resolves a concrete instance implementation using a function-type metatype.
    ///
    /// The signature excludes self. Mutating value members require an explicit
    /// mutating flag because their source-level symbol does not encode it.
    /// Consuming members similarly require consuming: true; the call transfers
    /// a receiver copy and preserves the caller's original value.
    /// - Parameters:
    ///   - name: A relative label-only or complete member declaration.
    ///   - signature: Explicit arguments and result.
    ///   - isMutating: Whether a value receiver is passed inout.
    ///   - isConsuming: Whether the member consumes its receiver copy.
    /// - Returns: A reusable method with an explicit receiver.
    /// - Throws: A lookup, representation, or preparation error.
    public func method<Signature>(
        named name: String, as signature: Signature.Type,
        mutating isMutating: Bool = false, consuming isConsuming: Bool = false
    ) throws -> NativeSwiftMethod<Signature> {
        let symbol = try resolveMember { try swiftFunctionDeclaration(named: $0 + "." + name, as: signature) }
        return try NativeSwiftMethod(
            symbol: symbol, type: self,
            receiver: receiverPlan(mutating: isMutating, consuming: isConsuming)
        )
    }
    /// Resolves a nonmutating member with formally indirect borrowed self.
    ///
    /// Use for a runtime-only resilient value received through
    /// NativeSwiftBorrowingClosure. The caller establishes this self convention;
    /// metadata size alone does not imply it. The signature excludes self.
    public func borrowedMethod<Result, each Argument>(
        named name: String, as signature: ((repeat each Argument) -> Result).Type
    ) throws -> NativeSwiftBorrowedMethod<Result, repeat each Argument> {
        let symbol = try resolveMember { try swiftFunctionDeclaration(named: $0 + "." + name, as: signature) }
        return try NativeSwiftBorrowedMethod(symbol: symbol, type: self)
    }

    /// Resolves a nonmutating getter with formally indirect borrowed self.
    ///
    /// The getter must be synchronous, nonthrowing and nonconsuming. Its value
    /// uses the supported concrete Swift result representations.
    public func borrowedGetter<Value>(named name: String, as value: Value.Type) throws -> NativeSwiftBorrowedMethod<Value> {
        let symbol = try resolveMember {
            try accessorDeclaration(named: name, ownerName: $0, valueType: value, setter: false, isStatic: false)
        }
        return try NativeSwiftBorrowedMethod(symbol: symbol, type: self)
    }

    /// Resolves a concrete allocating initializer.
    ///
    /// Ordinary initializer arguments transfer ownership to the callee. The
    /// native metadata is supplied automatically, and the result uses the
    /// requested Swift class or fixed-layout value adapter. NativeSwiftBorrowing
    /// selects an explicitly borrowed initializer parameter.
    /// - Parameters:
    ///   - name: The relative initializer name, such as init(text:).
    ///   - signature: Explicit arguments and constructed result.
    /// - Returns: A reusable initializer retaining its type and implementation.
    /// - Throws: A lookup, representation, or preparation error.
    public func initializer<Signature>(
        named name: String, as signature: Signature.Type
    ) throws -> NativeSwiftFunction<Signature> {
        guard name.hasPrefix("init(") else {
            throw ABIResolutionError.unsupportedDeclaration("An initializer name must start with init(.")
        }
        let member = metadata is AnyClass ? "__allocating_" + name : name
        let resultName = try SwiftFunctionSignature(signature).result is any NativeOptionalValue.Type ? "Swift.Optional<" + self.name + ">" : self.name
        let declaration = try swiftFunctionDeclaration(
            named: self.name + "." + member, as: signature, resultName: resultName, defaultConsuming: true
        )
        return try NativeSwiftFunction(
            symbol: resolveDeclaredMember(declaration, in: image), metadata: metadata, owner: self,
            consumesArguments: true
        )
    }

    /// Resolves a concrete static or class implementation.
    ///
    /// The declaring type's metadata is supplied as the Swift context.
    /// - Parameters:
    ///   - name: A relative Swift member declaration or argument-label name.
    ///   - signature: Explicit arguments and result.
    /// - Returns: A reusable function retaining its type and implementation.
    /// - Throws: A lookup, representation, or preparation error.
    public func staticMethod<Signature>(
        named name: String, as signature: Signature.Type
    ) throws -> NativeSwiftFunction<Signature> {
        let symbol = try resolveMember { try swiftFunctionDeclaration(named: "static " + $0 + "." + name, as: signature) }
        return try NativeSwiftFunction(symbol: symbol, metadata: metadata, owner: self)
    }

    private func accessorDeclaration(
        named name: String, ownerName: String, valueType: Any.Type, setter: Bool, isStatic: Bool
    ) throws -> NativeDeclaration {
        let accessor = setter ? ".setter : " : ".getter : "
        let prefix = (isStatic ? "static " : "") + ownerName + "."
        let member: String
        if name.contains(accessor) {
            member = name
        } else {
            let valueName = valueType == (representation ?? metadata) ? self.name : try swiftFunctionTypeName(valueType)
            member = name + accessor + valueName
        }
        return .init(name: prefix + member, language: .swift)
    }

    /// Resolves a property setter that consumes its incoming value.
    ///
    /// Class receivers are references. Ordinary value setters receive self
    /// inout; consuming setters transfer a copy. An explicitly nonmutating
    /// setter can use mutating: false.
    /// - Parameters:
    ///   - name: A property name or complete relative setter declaration.
    ///   - valueType: The incoming value representation.
    ///   - isMutating: An inout override. Nil selects inout unless consuming is true.
    ///   - isConsuming: Whether the setter consumes its receiver copy.
    /// - Returns: A reusable method with one explicit value argument.
    /// - Throws: A lookup or unsupported-representation error.
    public func setter<Value>(
        named name: String, as valueType: Value.Type, mutating isMutating: Bool? = nil,
        consuming isConsuming: Bool = false
    ) throws -> NativeSwiftMethod<(Value) -> Void> {
        let symbol = try resolveMember {
            try accessorDeclaration(named: name, ownerName: $0, valueType: valueType, setter: true, isStatic: false)
        }
        return try NativeSwiftMethod(
            symbol: symbol, type: self,
            receiver: receiverPlan(mutating: isMutating ?? !isConsuming, consuming: isConsuming),
            consumesArguments: true
        )
    }

    /// Resolves a static property setter that consumes its incoming value.
    ///
    /// - Parameters:
    ///   - name: A property name or complete relative setter declaration.
    ///   - valueType: The incoming value representation.
    /// - Returns: A one-argument function with bound type metadata.
    /// - Throws: A lookup or unsupported-representation error.
    public func staticSetter<Value>(
        named name: String, as valueType: Value.Type
    ) throws -> NativeSwiftFunction<(Value) -> Void> {
        let symbol = try resolveMember {
            try accessorDeclaration(named: name, ownerName: $0, valueType: valueType, setter: true, isStatic: true)
        }
        return try NativeSwiftFunction(
            symbol: symbol, metadata: metadata, owner: self,
            consumesArguments: true
        )
    }

}

func swiftClassImage(_ type: AnyClass, named name: String, resolver: SymbolResolver) throws -> NativeImage {
    // A live class has one defining image. Retaining that image also prevents
    // class-address reuse; this does not cache user-supplied filesystem selectors.
    try resolver.image(forSwiftClass: type) {
        guard let path = class_getImageName(type) else {
            throw ABIResolutionError.declarationNotFound(
                .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data)
            )
        }
        let images = try resolver.images(matching: .path(URL(fileURLWithPath: String(cString: path))))
        guard let image = images.first else { throw ABIResolutionError.imageNotLoaded }
        return image
    }
}

func swiftClassDeclarationName(
    _ type: AnyClass, in image: NativeImage, suggestedName: String, resolver: SymbolResolver
) throws -> String {
    guard let descriptor = try SwiftClassDispatch.nominalDescriptor(of: type) else { return suggestedName }
    return try resolver.swiftNominalTypeName(at: UInt64(descriptor), in: image, suggestedName: suggestedName) ?? suggestedName
}

extension ABIRuntime {
    func swiftType(for objectType: AnyClass) throws -> NativeSwiftType {
        let runtimeName = try swiftFunctionTypeName(objectType)
        let image = try swiftClassImage(objectType, named: runtimeName, resolver: resolver)
        let key = SwiftTypeCacheKey.metadata(ObjectIdentifier(objectType), image: image.identity)
        if let cached = swiftTypes[key] { return cached }
        let name = try swiftClassDeclarationName(objectType, in: image, suggestedName: runtimeName, resolver: resolver)
        let type = NativeSwiftType(name: name, image: image, metadata: objectType,
                                   representation: nil, resolver: resolver)
        swiftTypes[key] = type
        return type
    }

    /// Resolves a concrete Swift class, struct, or enum and caches its metadata.
    ///
    /// - Parameters:
    ///   - name: A module-qualified nominal type name.
    ///   - scope: Images to search; automatic scope stays loaded-only.
    ///   - loading: Whether an explicit target may be acquired and initialized.
    ///   - genericArguments: Type arguments in outer-to-inner declaration order.
    /// - Returns: A reusable type handle retaining its defining image.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public func swiftType(
        named name: String, in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) throws -> NativeSwiftType {
        try makeSwiftType(named: name, descriptor: resolver.resolve(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data), in: scope, loading: loading
        ), representation: nil, genericArguments: genericArguments)
    }

    /// Resolves a concrete Swift type within an already retained image.
    ///
    /// - Parameters:
    ///   - name: A module-qualified nominal type name.
    ///   - image: The image whose symbol index is reused.
    ///   - loading: Whether to ask dyld to acquire and initialize the image.
    ///   - genericArguments: Type arguments in outer-to-inner declaration order.
    /// - Returns: A reusable type handle retaining the image.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public func swiftType(
        named name: String, in image: NativeImage, loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) throws -> NativeSwiftType {
        try makeSwiftType(named: name, descriptor: resolver.resolve(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data), in: image, loading: loading
        ), representation: nil, genericArguments: genericArguments)
    }

    /// Resolves a Swift type with an explicit receiver representation.
    ///
    /// Use an ABIBridgeValue adapter when the native type cannot be imported.
    /// The representation describes fixed storage and ownership; it does not
    /// establish ABI compatibility with a resilient or generic declaration.
    /// - Parameters:
    ///   - name: The qualified native type name.
    ///   - representation: A Swift type or adapter for receiver values.
    ///   - scope: Images to search; automatic scope stays loaded-only.
    ///   - loading: Whether an explicit target may be acquired and initialized.
    /// - Returns: A reusable type handle with the chosen receiver representation.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public func swiftType<Representation>(
        named name: String, as representation: Representation.Type,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) throws -> NativeSwiftType {
        try makeSwiftType(named: name, descriptor: resolver.resolve(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data), in: scope, loading: loading
        ), representation: representation, genericArguments: genericArguments)
    }

    /// Resolves a Swift type and receiver adapter within a retained image.
    ///
    /// - Parameters:
    ///   - name: The qualified native type name.
    ///   - representation: A Swift type or fixed-layout receiver adapter.
    ///   - image: The image whose symbol index is reused.
    ///   - loading: Whether to ask dyld to acquire and initialize the image.
    /// - Returns: A reusable type handle with the chosen representation.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public func swiftType<Representation>(
        named name: String, as representation: Representation.Type, in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded,
        genericArguments: [NativeSwiftGenericArgument] = []
    ) throws -> NativeSwiftType {
        try makeSwiftType(named: name, descriptor: resolver.resolve(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data), in: image, loading: loading
        ), representation: representation, genericArguments: genericArguments)
    }

    private func makeSwiftType(
        named name: String, descriptor: ResolvedSymbol, representation: Any.Type?,
        genericArguments: [NativeSwiftGenericArgument]
    ) throws -> NativeSwiftType {
        let key = SwiftTypeCacheKey.declaration(
            name: name, image: descriptor.image.identity,
            representation: representation.map(ObjectIdentifier.init),
            arguments: genericArguments.map(\.identity))
        if let cached = swiftTypes[key],
           zip(cached.genericMetadata?.arguments ?? [], genericArguments)
            .allSatisfy({ $0.retainsOwners(of: $1) }) {
            return cached
        }
        guard descriptor.sectionRange.upperBound - descriptor.address >= 4 else {
            throw ABIResolutionError.metadataUnavailable("Incomplete Swift type descriptor for " + name)
        }
        let metadata = try SwiftGenericTypeMetadata(descriptor: descriptor, arguments: genericArguments)
        let type = NativeSwiftType(
            name: name, image: descriptor.image, metadata: metadata.value,
            representation: representation, resolver: resolver, genericMetadata: metadata)
        swiftTypes[key] = type
        return type
    }
}

extension NativeSwiftType {
    /// Resolves a property getter using its complete zero-argument function type.
    ///
    /// Use (() -> Value).self for a synchronous nonthrowing getter. Include its
    /// native throws type, async effect, and isolation convention when present.
    /// Receiver ownership and writeback follow the ordinary member contract.
    public func getter<Signature>(
        named name: String, as signature: Signature.Type,
        mutating isMutating: Bool = false, consuming isConsuming: Bool = false
    ) throws -> NativeSwiftMethod<Signature> {
        let result = try getterResult(signature)
        let symbol = try resolveMember {
            try accessorDeclaration(named: name, ownerName: $0, valueType: result, setter: false, isStatic: false)
        }
        return try NativeSwiftMethod(symbol: symbol, type: self,
            receiver: receiverPlan(mutating: isMutating, consuming: isConsuming))
    }

    /// Resolves a static getter using its complete zero-argument function type.
    /// Native error, async, and isolation effects remain part of the signature.
    public func staticGetter<Signature>(
        named name: String, as signature: Signature.Type
    ) throws -> NativeSwiftFunction<Signature> {
        let result = try getterResult(signature)
        let symbol = try resolveMember {
            try accessorDeclaration(named: name, ownerName: $0, valueType: result, setter: false, isStatic: true)
        }
        return try NativeSwiftFunction(symbol: symbol, metadata: metadata, owner: self)
    }

    private func getterResult(_ signature: Any.Type) throws -> Any.Type {
        let description = try SwiftFunctionSignature(signature)
        guard description.parameters.isEmpty else {
            throw ABIResolutionError.signatureMismatch(.init(expected: "A zero-argument getter signature", found: [String(reflecting: signature)]))
        }
        return description.result
    }
}
