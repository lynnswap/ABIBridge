import Foundation

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

    init(name: String, image: NativeImage, metadata: Any.Type,
         representation: Any.Type?, resolver: SymbolResolver) {
        self.name = name
        self.image = image
        self.metadata = metadata
        self.representation = representation
        self.resolver = resolver
    }
}

extension ABIRuntime {
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
