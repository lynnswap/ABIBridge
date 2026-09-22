import ABIBridgeCore
import Foundation

/// Limits a lookup to images already loaded in the current process.
///
/// A selector is a search constraint, not a request to load code.
public enum ImageSelector: Hashable, Sendable {
    /// Search all loaded images and report competing definitions as ambiguous.
    case automatic
    /// Match a framework by its name without the framework suffix.
    case framework(named: String)
    /// Match an executable image path, resolving filesystem symlinks when available.
    case path(URL)
}

/// A loaded image retained for the lifetime of this handle and its symbols.
public struct NativeImage: Hashable, Sendable {
    /// The identity of this particular load.
    public let identity: NativeImageIdentity
    /// The executable path reported by dyld.
    public let path: String
    let lease: ImageLease

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    public func hash(into hasher: inout Hasher) { hasher.combine(identity) }
}

// Immutable native lease; dyld's reference counting is thread-safe. Releasing
// this reference never invalidates another NativeImage that shares the lease.
final class ImageLease: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { ABIReleaseImage(handle) }
}

struct ImageSnapshot {
    let identity: NativeImageIdentity
    let path: String

    func matches(_ selector: ImageSelector) -> Bool {
        switch selector {
        case .automatic: return true
        case .path(let url): return URL(fileURLWithPath: path).resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
        case .framework(let name):
            let url = URL(fileURLWithPath: path)
            return url.lastPathComponent == name && url.pathComponents.contains("\(name).framework")
        }
    }

    func retain() throws -> NativeImage {
        guard let handle = ABIRetainLoadedImage(identity.loadGeneration) else {
            throw ABIResolutionError.imageChanged
        }
        return NativeImage(identity: identity, path: path, lease: ImageLease(handle))
    }

    static func current() throws -> [Self] {
        guard let list = ABICopyLoadedImages() else { throw ABIResolutionError.imageUnavailable }
        defer { ABIFreeImageList(list) }
        return (0..<ABIImageListCount(list)).map { index in
            let info = ABIImageListGet(list, index)
            let uuid = UUID(uuid: info.uuid)
            return Self(
                identity: NativeImageIdentity(
                    headerAddress: UInt64(info.header),
                    slide: Int64(info.slide),
                    loadGeneration: info.generation,
                    uuid: uuid == UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) ? nil : uuid
                ),
                path: String(cString: info.path)
            )
        }
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
    @unsafe public func withUnsafeAddress<Result>(
        _ body: (UnsafeRawPointer) throws -> Result
    ) rethrows -> Result {
        try withExtendedLifetime(image) {
            try body(UnsafeRawPointer(bitPattern: UInt(address))!)
        }
    }
}
