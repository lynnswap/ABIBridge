import ABIBridgeRuntime
import ABIBridgeCore
import Foundation
import Synchronization

/// Selects images for declaration lookup or loaded-image inspection.
///
/// Resolution may acquire an explicitly selected image according to its loading
/// policy. Catalog enumeration always remains loaded-only.
public enum ImageSelector: Hashable, Sendable {
    /// Search loaded images whose lifetime can currently be retained.
    /// Competing available definitions are reported as ambiguous.
    case automatic
    /// Match a framework by its name without the framework suffix.
    case framework(named: String)
    /// Match an executable image path, resolving filesystem symlinks when available.
    case path(URL)
    /// A dyld path spelling, including @rpath, @loader_path, or @executable_path.
    /// Relative loader paths use the image containing ABIBridge's native loader
    /// call, not the source location of an async Swift caller.
    case installName(String)

    func validateTarget() throws { try withRuntimeErrors { try runtimeValue.validateTarget() } }

}

/// Controls whether resolution can acquire an explicitly selected image.
public enum ImageLoadingPolicy: Int32, Hashable, Sendable {
    /// Use dyld to acquire and initialize an explicit target. Automatic search
    /// still considers only images already present in the catalog.
    case ifNeeded = 0
    /// Search existing images without requesting loading or initialization.
    case loadedOnly = 1
}

/// A loaded image retained for the lifetime of this handle and its symbols.
public struct NativeImage: Hashable, Sendable {
    /// The identity of this particular load.
    public let identity: NativeImageIdentity
    /// The executable path reported by dyld.
    public let path: String
    let lease: RuntimeImageLease

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    public func hash(into hasher: inout Hasher) { hasher.combine(identity) }

    init(_ value: RuntimeImage) {
        identity = NativeImageIdentity(value.identity); path = value.path; lease = value.lease
    }

    var runtimeValue: RuntimeImage {
        .init(identity: identity.runtimeValue, path: path, lease: lease)
    }

    static func opening(path: String, loading: ImageLoadingPolicy) throws -> Self {
        try withRuntimeErrors {
            Self(try RuntimeImage.opening(path: path, loading: loading.runtimeValue))
        }
    }

    func opened() throws -> Self { try withRuntimeErrors { Self(try runtimeValue.opened()) } }

    static func retaining(generation: UInt64) throws -> Self? {
        try withRuntimeErrors { try RuntimeImage.retaining(generation: generation).map(Self.init) }
    }
}

struct ImageSnapshot: Sendable {
    let value: RuntimeImageSnapshot
    var identity: NativeImageIdentity { NativeImageIdentity(value.identity) }
    var path: String { value.path }
    init(_ value: RuntimeImageSnapshot) { self.value = value }
    init(_ info: ABIImageInfo) { value = RuntimeImageSnapshot(info) }
    static func matching(_ selector: ImageSelector, in snapshots: [Self]) throws -> [Self] {
        try withRuntimeErrors {
            try RuntimeImageSnapshot.matching(selector.runtimeValue, in: snapshots.map(\.value))
                .map(Self.init)
        }
    }
    func retain() throws -> NativeImage {
        try withRuntimeErrors { NativeImage(try value.retain()) }
    }
    static func current() throws -> [Self] {
        try withRuntimeErrors { try RuntimeImageSnapshot.current().map(Self.init) }
    }
}

/// A native symbol together with the image that keeps its address valid.
///
/// Resolution establishes the containing storage and image identity. It does
/// not establish a function signature, object layout, or ownership convention.
/// See <doc:SymbolLookup> for lookup precedence and lifetime rules.
public struct ResolvedSymbol: Sendable {
    /// The symbol metadata source used for this result.
    public enum Source: String, Sendable {
        /// The loaded image's symbol table or exports.
        case image
        /// Local symbol metadata from the matching dyld shared cache.
        case sharedCache
    }

    /// The declaration whose name and storage requirements matched.
    public let declaration: NativeDeclaration
    /// The retained image containing the symbol.
    public let image: NativeImage
    /// The containing section; this is not the size of the function or value.
    public let sectionRange: Range<UInt64>
    /// Where the resolver found the symbol metadata.
    public let source: Source
    let address: UInt64
    let linkageName: String

    init(
        declaration: NativeDeclaration,
        image: NativeImage,
        sectionRange: Range<UInt64>,
        source: Source,
        address: UInt64,
        linkageName: String
    ) {
        self.declaration = declaration; self.image = image; self.sectionRange = sectionRange
        self.source = source; self.address = address; self.linkageName = linkageName
    }

    init(_ value: RuntimeSymbol) {
        self.init(
            declaration: NativeDeclaration(value.declaration),
            image: NativeImage(value.image),
            sectionRange: value.sectionRange,
            source: Source(rawValue: value.source.rawValue)!,
            address: value.address,
            linkageName: value.linkageName
        )
    }

    var runtimeValue: RuntimeSymbol {
        .init(
            declaration: declaration.runtimeValue,
            image: image.runtimeValue,
            sectionRange: sectionRange,
            source: RuntimeSymbol.Source(rawValue: source.rawValue)!,
            address: address,
            linkageName: linkageName
        )
    }

    /// Borrows the symbol address while retaining its image.
    ///
    /// The address must not escape the closure. Calling it requires a compatible
    /// ABI, argument lifetimes, and function-pointer authentication where required.
    /// This method supplies a raw address and does not perform authentication.
    /// Reading data requires knowledge of the actual value's layout and size.
    ///
    /// - Parameter body: A synchronous operation using the borrowed address.
    /// - Returns: The result produced by the closure.
    /// - Throws: Any error thrown by the closure.
    @unsafe public func withUnsafeAddress<Result: ~Copyable>(
        _ body: (UnsafeRawPointer) throws -> Result
    ) rethrows -> Result {
        try withExtendedLifetime(image) {
            try body(UnsafeRawPointer(bitPattern: UInt(address))!)
        }
    }
}
