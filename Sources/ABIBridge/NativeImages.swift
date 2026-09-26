import ABIBridgeCore
import Foundation

/// Selects images for declaration lookup or loaded-image inspection.
///
/// Resolution may acquire an explicitly selected image according to its loading
/// policy. Catalog enumeration always remains loaded-only.
public enum ImageSelector: Hashable, Sendable {
    /// Search all loaded images and report competing definitions as ambiguous.
    case automatic
    /// Match a framework by its name without the framework suffix.
    case framework(named: String)
    /// Match an executable image path, resolving filesystem symlinks when available.
    case path(URL)
    /// A dyld path spelling, including @rpath, @loader_path, or @executable_path.
    /// Relative loader paths use the image containing ABIBridge's native loader
    /// call, not the source location of an async Swift caller.
    case installName(String)
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
    let lease: ImageLease

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    public func hash(into hasher: inout Hasher) { hasher.combine(identity) }

    static func opening(path: String, loading: ImageLoadingPolicy = .ifNeeded) throws -> Self {
        var failure: OpaquePointer?
        let handle = path.withCString { ABIOpenImage($0, loading == .ifNeeded, &failure) }
        return try acquired(handle, failure: failure, target: path)
    }

    func opened() throws -> Self {
        var failure: OpaquePointer?
        let handle = ABIOpenLoadedImage(identity.loadGeneration, &failure)
        return try Self.acquired(handle, failure: failure, target: path)
    }

    private static func acquired(_ handle: OpaquePointer?, failure: OpaquePointer?, target: String) throws -> Self {
        guard let handle else {
            guard let failure else { throw ABIResolutionError.imageUnavailable }
            defer { ABIReleaseResolutionFailure(failure) }
            let message = String(cString: ABIResolutionFailureMessage(failure))
            switch ABIResolutionFailureCode(failure) {
            case Int32(ABIFailureImageNotLoaded): throw ABIResolutionError.imageNotLoaded
            case Int32(ABIFailureImageLoadFailed): throw ABIResolutionError.imageLoadFailed(target: target, message: message)
            case Int32(ABIFailureImageChanged): throw ABIResolutionError.imageChanged
            case Int32(ABIFailureImageUnavailable): throw ABIResolutionError.imageUnavailable
            default: throw ABIResolutionError.metadataUnavailable(message)
            }
        }
        let snapshot = ImageSnapshot(ABIImageLeaseGet(handle))
        return Self(identity: snapshot.identity, path: snapshot.path, lease: ImageLease(handle))
    }
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

    init(_ info: ABIImageInfo) {
        let uuid = UUID(uuid: info.uuid)
        identity = NativeImageIdentity(
            headerAddress: UInt64(info.header), slide: Int64(info.slide), loadGeneration: info.generation,
            uuid: uuid == UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) ? nil : uuid
        )
        path = String(cString: info.path)
    }

    static func matching(_ selector: ImageSelector, in snapshots: [Self]) throws -> [Self] {
        switch selector {
        case .automatic: return snapshots
        case .installName(let name):
            guard !name.isEmpty, !name.utf8.contains(0) else { throw ABIResolutionError.invalidImageTarget(name) }
            do {
                let image = try NativeImage.opening(path: name, loading: .loadedOnly)
                return snapshots.filter { $0.identity == image.identity }
            } catch ABIResolutionError.imageNotLoaded { return [] }
        case .path(let url):
            let resolved = url.resolvingSymlinksInPath()
            return snapshots.filter { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == resolved }
        case .framework(let name):
            return snapshots.filter {
                let url = URL(fileURLWithPath: $0.path)
                return url.lastPathComponent == name && url.pathComponents.contains("\(name).framework")
            }
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
            Self(ABIImageListGet(list, index))
        }
    }
}

enum FrameworkImages {
    static var bundleDirectories: [URL] {
        [Bundle.main.privateFrameworksURL, Bundle.main.sharedFrameworksURL].compactMap { $0 }
    }

    static func candidates(named name: String, bundleDirectories: [URL] = FrameworkImages.bundleDirectories) -> [URL] {
        var paths = bundleDirectories.map { $0.appendingPathComponent("\(name).framework/\(name)") }
        var systemPaths = ["/System/Library/Frameworks", "/System/Library/PrivateFrameworks"]
        #if targetEnvironment(macCatalyst)
        systemPaths += ["/System/iOSSupport/System/Library/Frameworks", "/System/iOSSupport/System/Library/PrivateFrameworks"]
        #endif
        paths += systemPaths.map { URL(fileURLWithPath: "\($0)/\(name).framework/\(name)") }
        return Array(Set(paths.filter { url in
            if url.path.withCString({ ABIImageIsInSharedCache($0) }) { return true }
            if FileManager.default.fileExists(atPath: url.path) { return true }
            #if targetEnvironment(simulator)
            if let root = ProcessInfo.processInfo.environment["SIMULATOR_ROOT"], url.path.hasPrefix("/System/") {
                return FileManager.default.fileExists(atPath: root + url.path)
            }
            #endif
            return false
        }.map { $0.resolvingSymlinksInPath() })).sorted { $0.path < $1.path }
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
