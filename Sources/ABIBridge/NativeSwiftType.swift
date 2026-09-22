import Foundation
import ObjectiveC

struct SwiftTypeCacheKey: Hashable {
    let name: String
    let image: NativeImageIdentity
    let representation: ObjectIdentifier?
}

private struct SwiftMetadataResponse: BitwiseCopyable, ABIBridgeValue {
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
/// Generic metadata construction and resilient value layout synthesis require
/// separate adapters. Member lookups reuse the image's existing symbol index.
public actor NativeSwiftType {
    /// The qualified source-level name of the nominal type.
    public nonisolated let name: String
    /// The image defining the nominal type descriptor.
    public nonisolated let image: NativeImage

    let metadata: Any.Type
    let representation: Any.Type?
    let resolver: SymbolResolver
    private var cachedReceiver: SwiftReceiverCodec?

    init(name: String, image: NativeImage, metadata: Any.Type,
         representation: Any.Type?, resolver: SymbolResolver) {
        self.name = name
        self.image = image
        self.metadata = metadata
        self.representation = representation
        self.resolver = resolver
    }

    func receiverPlan(mutating isMutating: Bool) throws -> SwiftReceiverPlan {
        if cachedReceiver == nil {
            cachedReceiver = try SwiftReceiverCodec.make(for: representation ?? metadata)
        }
        return try SwiftReceiverPlan(
            codec: cachedReceiver!, metadata: metadata, isMutating: isMutating,
            validateClass: representation != nil && representation != metadata
        )
    }

    private func resolveDeclaredMember(_ declaration: NativeDeclaration, in image: NativeImage) throws -> ResolvedSymbol {
        do { return try resolver.resolve(declaration, in: image) }
        catch ABIResolutionError.declarationNotFound {
            return try resolver.resolveSwiftExtension(declaration)
        }
    }

    private func resolveMember(
        _ declaration: (String) throws -> NativeDeclaration
    ) throws -> ResolvedSymbol {
        var ownerName = name
        var ownerClass: AnyClass? = metadata as? AnyClass
        var ownerImage: NativeImage? = image
        while true {
            let request = try declaration(ownerName)
            do {
                if let ownerImage { return try resolveDeclaredMember(request, in: ownerImage) }
                do { return try resolver.resolve(request, in: .automatic) }
                catch ABIResolutionError.declarationNotFound {
                    return try resolver.resolveSwiftExtension(request)
                }
            } catch ABIResolutionError.declarationNotFound {
                guard let current = ownerClass, let parent = class_getSuperclass(current) else {
                    throw ABIResolutionError.declarationNotFound(request)
                }
                ownerName = try swiftFunctionTypeName(parent)
                guard !ownerName.contains("<") else {
                    throw ABIResolutionError.unsupportedDeclaration("Generic superclass members require a native adapter.")
                }
                ownerClass = parent
                ownerImage = nil
            }
        }
    }

    /// Resolves a concrete instance implementation using a function-type metatype.
    ///
    /// The signature excludes self. Mutating value members require an explicit
    /// mutating flag because their source-level symbol does not encode it.
    /// - Parameters:
    ///   - name: A relative label-only or complete member declaration.
    ///   - signature: Explicit arguments and result.
    ///   - isMutating: Whether a value receiver is passed inout.
    /// - Returns: A reusable method with an explicit receiver.
    /// - Throws: A lookup, representation, or preparation error.
    public func method<Result, each Argument>(
        named name: String, as signature: ((repeat each Argument) -> Result).Type,
        mutating isMutating: Bool = false
    ) throws -> NativeSwiftMethod<Result, repeat each Argument> {
        let symbol = try resolveMember { try swiftFunctionDeclaration(named: $0 + "." + name, as: signature) }
        return try NativeSwiftMethod(
            symbol: symbol, type: self,
            receiver: receiverPlan(mutating: isMutating)
        )
    }
    /// Resolves a concrete allocating initializer.
    ///
    /// Ordinary initializer arguments transfer ownership to the callee. The
    /// native metadata is supplied automatically, and the result uses the
    /// requested Swift class or fixed-layout value adapter.
    /// - Parameters:
    ///   - name: The relative initializer name, such as init(text:).
    ///   - signature: Explicit arguments and constructed result.
    /// - Returns: A reusable initializer retaining its type and implementation.
    /// - Throws: A lookup, representation, or preparation error.
    public func initializer<Result, each Argument>(
        named name: String, as signature: ((repeat each Argument) -> Result).Type
    ) throws -> NativeSwiftFunction<Result, repeat each Argument> {
        guard name.hasPrefix("init(") else {
            throw ABIResolutionError.unsupportedDeclaration("An initializer name must start with init(.")
        }
        let member = metadata is AnyClass ? "__allocating_" + name : name
        let resultName = Result.self is any NativeOptionalValue.Type ? "Swift.Optional<" + self.name + ">" : self.name
        let declaration = try swiftFunctionDeclaration(
            named: self.name + "." + member, as: signature, resultName: resultName
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
    public func staticMethod<Result, each Argument>(
        named name: String, as signature: ((repeat each Argument) -> Result).Type
    ) throws -> NativeSwiftFunction<Result, repeat each Argument> {
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

    /// Resolves a synchronous, nonthrowing instance property getter.
    ///
    /// Getter symbols do not establish effect or value-self conventions. Set
    /// mutating for a mutating value getter and honor the actual declaration.
    /// - Parameters:
    ///   - name: A property name or complete relative getter declaration.
    ///   - valueType: The result representation.
    ///   - isMutating: Whether the value getter receives self inout.
    /// - Returns: A method called with unsafeInvoke(on:).
    /// - Throws: A lookup or unsupported-representation error.
    public func getter<Value>(
        named name: String, as valueType: Value.Type, mutating isMutating: Bool = false
    ) throws -> NativeSwiftMethod<Value> {
        let symbol = try resolveMember {
            try accessorDeclaration(named: name, ownerName: $0, valueType: valueType, setter: false, isStatic: false)
        }
        return try NativeSwiftMethod(
            symbol: symbol, type: self,
            receiver: receiverPlan(mutating: isMutating)
        )
    }

    /// Resolves a property setter that consumes its incoming value.
    ///
    /// Class receivers are references. Value setters receive self inout by
    /// default; set mutating to false for an explicitly nonmutating setter.
    /// - Parameters:
    ///   - name: A property name or complete relative setter declaration.
    ///   - valueType: The incoming value representation.
    ///   - isMutating: Whether a value setter receives self inout.
    /// - Returns: A reusable method with one explicit value argument.
    /// - Throws: A lookup or unsupported-representation error.
    public func setter<Value>(
        named name: String, as valueType: Value.Type, mutating isMutating: Bool = true
    ) throws -> NativeSwiftMethod<Void, Value> {
        let symbol = try resolveMember {
            try accessorDeclaration(named: name, ownerName: $0, valueType: valueType, setter: true, isStatic: false)
        }
        return try NativeSwiftMethod(
            symbol: symbol, type: self,
            receiver: receiverPlan(mutating: isMutating), consumesArguments: true
        )
    }

    /// Resolves a synchronous, nonthrowing static property getter.
    ///
    /// - Parameters:
    ///   - name: A property name or complete relative getter declaration.
    ///   - valueType: The result representation.
    /// - Returns: A zero-argument function with bound type metadata.
    /// - Throws: A lookup or unsupported-representation error.
    public func staticGetter<Value>(
        named name: String, as valueType: Value.Type
    ) throws -> NativeSwiftFunction<Value> {
        let symbol = try resolveMember {
            try accessorDeclaration(named: name, ownerName: $0, valueType: valueType, setter: false, isStatic: true)
        }
        return try NativeSwiftFunction(
            symbol: symbol, metadata: metadata, owner: self
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
    ) throws -> NativeSwiftFunction<Void, Value> {
        let symbol = try resolveMember {
            try accessorDeclaration(named: name, ownerName: $0, valueType: valueType, setter: true, isStatic: true)
        }
        return try NativeSwiftFunction(
            symbol: symbol, metadata: metadata, owner: self,
            consumesArguments: true
        )
    }

}

extension ABIRuntime {
    func swiftType(for objectType: AnyClass) throws -> NativeSwiftType {
        let name = try swiftFunctionTypeName(objectType)
        guard !name.contains("<") else {
            throw ABIResolutionError.unsupportedDeclaration("Generic Swift class members require a native adapter.")
        }
        guard let path = class_getImageName(objectType) else {
            throw ABIResolutionError.declarationNotFound(
                .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data)
            )
        }
        let images = try resolver.images(matching: .path(URL(fileURLWithPath: String(cString: path))))
        guard let image = images.first else { throw ABIResolutionError.imageNotLoaded }
        let key = SwiftTypeCacheKey(name: name, image: image.identity, representation: nil)
        if let cached = swiftTypes[key] { return cached }
        let type = NativeSwiftType(name: name, image: image, metadata: objectType,
                                   representation: nil, resolver: resolver)
        swiftTypes[key] = type
        return type
    }

    /// Resolves a concrete Swift class, struct, or enum and caches its metadata.
    ///
    /// - Parameters:
    ///   - name: A module-qualified nominal type name.
    ///   - scope: Loaded images to search; defaults to all loaded images.
    /// - Returns: A reusable type handle retaining its defining image.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public func swiftType(
        named name: String, in scope: ImageSelector = .automatic
    ) throws -> NativeSwiftType {
        try makeSwiftType(named: name, descriptor: resolver.resolve(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data), in: scope
        ), representation: nil)
    }

    /// Resolves a concrete Swift type within an already retained image.
    ///
    /// - Parameters:
    ///   - name: A module-qualified nominal type name.
    ///   - image: The image whose symbol index is reused.
    /// - Returns: A reusable type handle retaining the image.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public func swiftType(named name: String, in image: NativeImage) throws -> NativeSwiftType {
        try makeSwiftType(named: name, descriptor: resolver.resolve(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data), in: image
        ), representation: nil)
    }

    /// Resolves a Swift type with an explicit receiver representation.
    ///
    /// Use an ABIBridgeValue adapter when the native type cannot be imported.
    /// The representation describes fixed storage and ownership; it does not
    /// establish ABI compatibility with a resilient or generic declaration.
    /// - Parameters:
    ///   - name: The qualified native type name.
    ///   - representation: A Swift type or adapter for receiver values.
    ///   - scope: Loaded images to search.
    /// - Returns: A reusable type handle with the chosen receiver representation.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public func swiftType<Representation>(
        named name: String, as representation: Representation.Type,
        in scope: ImageSelector = .automatic
    ) throws -> NativeSwiftType {
        try makeSwiftType(named: name, descriptor: resolver.resolve(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data), in: scope
        ), representation: representation)
    }

    /// Resolves a Swift type and receiver adapter within a retained image.
    ///
    /// - Parameters:
    ///   - name: The qualified native type name.
    ///   - representation: A Swift type or fixed-layout receiver adapter.
    ///   - image: The image whose symbol index is reused.
    /// - Returns: A reusable type handle with the chosen representation.
    /// - Throws: A lookup error or unavailable/unsupported metadata.
    public func swiftType<Representation>(
        named name: String, as representation: Representation.Type, in image: NativeImage
    ) throws -> NativeSwiftType {
        try makeSwiftType(named: name, descriptor: resolver.resolve(
            .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data), in: image
        ), representation: representation)
    }

    private func makeSwiftType(
        named name: String, descriptor: ResolvedSymbol, representation: Any.Type?
    ) throws -> NativeSwiftType {
        let key = SwiftTypeCacheKey(name: name, image: descriptor.image.identity,
                                    representation: representation.map(ObjectIdentifier.init))
        if let cached = swiftTypes[key] { return cached }
        // Bare generic names also have accessors, but those require additional
        // metadata/witness arguments. Inspect the descriptor before calling one.
        guard descriptor.sectionRange.upperBound - descriptor.address >= 4 else {
            throw ABIResolutionError.metadataUnavailable("Incomplete Swift type descriptor for " + name)
        }
        let flags = unsafe descriptor.withUnsafeAddress { $0.loadUnaligned(as: UInt32.self) }
        guard flags & 0x80 == 0 else {
            throw ABIResolutionError.unsupportedDeclaration("Generic Swift type metadata requires a native adapter.")
        }
        guard (16...18).contains(flags & 0x1f) else {
            throw ABIResolutionError.metadataUnavailable("Expected a Swift nominal type descriptor for " + name)
        }
        let accessor = try resolver.resolve(
            .init(name: "type metadata accessor for " + name, language: .swift), in: descriptor.image
        )
        let function = try NativeSwiftFunction<SwiftMetadataResponse, UInt>(symbol: accessor)
        // MetadataRequest.Complete is zero and requests blocking completion.
        let response = try unsafe function.unsafeInvoke(0)
        guard response.address != 0, response.state == 0 else {
            throw ABIResolutionError.metadataUnavailable("Complete Swift metadata is unavailable for " + name)
        }
        let metadata = unsafeBitCast(response.address, to: Any.Type.self)
        let type = NativeSwiftType(name: name, image: descriptor.image, metadata: metadata,
                                   representation: representation, resolver: resolver)
        swiftTypes[key] = type
        return type
    }
}
