import ABIBridgeCore
import Foundation

/// Restricts lookup to loaded images. Specifying a path never loads a missing image.
public enum ImageSelector: Hashable, Sendable {
    case automatic
    case framework(named: String)
    case path(URL)
}

/// A loaded image retained for the lifetime of this handle and its symbols.
public struct NativeImage: Hashable, Sendable {
    public let identity: NativeImageIdentity
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
            return path.hasSuffix("/\(name).framework/\(name)")
                || path.hasSuffix("/\(name).framework/Versions/A/\(name)")
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

/// A resolved native address. Storage validation does not validate a calling convention.
public struct ResolvedSymbol: Sendable {
    public enum Source: String, Sendable {
        case image
        case sharedCache
    }

    public let declaration: NativeDeclaration
    public let image: NativeImage
    public let sectionRange: Range<UInt64>
    public let source: Source
    let address: UInt64

    /// Borrows the address while retaining its image. The address must not escape
    /// the closure, and calling it requires a compatible ABI and live arguments.
    @unsafe public func withUnsafeAddress<Result>(
        _ body: (UnsafeRawPointer) throws -> Result
    ) rethrows -> Result {
        try withExtendedLifetime(image) {
            try body(UnsafeRawPointer(bitPattern: UInt(address))!)
        }
    }
}
