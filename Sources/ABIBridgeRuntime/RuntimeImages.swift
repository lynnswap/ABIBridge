import ABIBridgeCore
import Foundation
import Synchronization

package enum RuntimeImageSelector: Hashable, Sendable {
    case automatic
    case framework(named: String)
    case path(URL)
    case installName(String)

    package func validateTarget() throws {
        switch self {
        case .automatic: return
        case .framework(let name):
            guard !name.isEmpty, !name.utf8.contains(0), !name.contains("/"), name != ".",
                name != ".."
            else {
                throw RuntimeResolutionError.invalidImageTarget(name)
            }
        case .path(let url):
            guard url.isFileURL, !url.path.utf8.contains(0) else {
                throw RuntimeResolutionError.invalidImageTarget(url.absoluteString)
            }
        case .installName(let name):
            guard !name.isEmpty, !name.utf8.contains(0) else {
                throw RuntimeResolutionError.invalidImageTarget(name)
            }
        }
    }
}

package enum RuntimeImageLoadingPolicy: Int32, Hashable, Sendable {
    case ifNeeded = 0
    case loadedOnly = 1
}

package struct RuntimeImage: Hashable, Sendable {
    package init(identity: RuntimeImageIdentity, path: String, lease: RuntimeImageLease) {
        self.identity = identity; self.path = path; self.lease = lease
    }

    package let identity: RuntimeImageIdentity
    package let path: String
    package let lease: RuntimeImageLease

    package static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    package func hash(into hasher: inout Hasher) { hasher.combine(identity) }

    package static func opening(
        path: String,
        loading: RuntimeImageLoadingPolicy = .ifNeeded
    ) throws -> Self {
        var failure: OpaquePointer?
        let handle = path.withCString { ABIOpenImage($0, loading == .ifNeeded, &failure) }
        return try acquired(handle, failure: failure, target: path)
    }

    package func opened() throws -> Self {
        var failure: OpaquePointer?
        let handle = ABIOpenLoadedImage(identity.loadGeneration, &failure)
        return try Self.acquired(handle, failure: failure, target: path)
    }

    package static func retaining(generation: UInt64) throws -> Self? {
        guard generation != 0 else { return nil }
        guard let handle = ABIRetainLoadedImage(generation) else {
            throw RuntimeResolutionError.imageUnavailable
        }
        let snapshot = RuntimeImageSnapshot(ABIImageLeaseGet(handle))
        return Self(
            identity: snapshot.identity,
            path: snapshot.path,
            lease: RuntimeImageLease(handle)
        )
    }

    private static func acquired(
        _ handle: OpaquePointer?,
        failure: OpaquePointer?,
        target: String
    ) throws -> Self {
        guard let handle else {
            guard let failure else { throw RuntimeResolutionError.imageUnavailable }
            defer { ABIReleaseResolutionFailure(failure) }
            let message = String(cString: ABIResolutionFailureMessage(failure))
            switch ABIResolutionFailureCode(failure) {
            case Int32(ABIFailureImageNotLoaded): throw RuntimeResolutionError.imageNotLoaded
            case Int32(ABIFailureImageLoadFailed):
                throw RuntimeResolutionError.imageLoadFailed(target: target, message: message)
            case Int32(ABIFailureImageChanged): throw RuntimeResolutionError.imageChanged
            case Int32(ABIFailureImageUnavailable): throw RuntimeResolutionError.imageUnavailable
            default: throw RuntimeResolutionError.metadataUnavailable(message)
            }
        }
        let snapshot = RuntimeImageSnapshot(ABIImageLeaseGet(handle))
        return Self(
            identity: snapshot.identity,
            path: snapshot.path,
            lease: RuntimeImageLease(handle)
        )
    }
}

// Immutable native lease; dyld's reference counting is thread-safe. Releasing
// this reference never invalidates another RuntimeImage that shares the lease.
package final class RuntimeImageLease: @unchecked Sendable {
    package let handle: OpaquePointer
    package init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { ABIReleaseImage(handle) }
}

package struct RuntimeImageCatalogSnapshot: Sendable {
    package let revision: UInt64
    package let images: [RuntimeImageSnapshot]
}

package struct RuntimeImageSnapshot: Sendable {
    private static let cachedCatalog = Mutex<RuntimeImageCatalogSnapshot?>(nil)
    package let identity: RuntimeImageIdentity
    package let path: String

    package init(_ info: ABIImageInfo) {
        let uuid = UUID(uuid: info.uuid)
        identity = RuntimeImageIdentity(
            headerAddress: UInt64(info.header),
            slide: Int64(info.slide),
            loadGeneration: info.generation,
            uuid: uuid == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) ? nil : uuid
        )
        path = String(cString: info.path)
    }

    package static func matching(
        _ selector: RuntimeImageSelector,
        in snapshots: [Self]
    ) throws -> [Self] {
        switch selector {
        case .automatic: return snapshots
        case .installName(let name):
            guard !name.isEmpty, !name.utf8.contains(0) else {
                throw RuntimeResolutionError.invalidImageTarget(name)
            }
            do {
                let image = try RuntimeImage.opening(path: name, loading: .loadedOnly)
                return snapshots.filter { $0.identity == image.identity }
            } catch RuntimeResolutionError.imageNotLoaded { return [] }
        case .path(let url):
            let resolved = url.resolvingSymlinksInPath()
            return snapshots.filter {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == resolved
            }
        case .framework(let name):
            return snapshots.filter {
                let url = URL(fileURLWithPath: $0.path)
                return url.lastPathComponent == name
                    && url.pathComponents.contains("\(name).framework")
            }
        }
    }

    package func retain() throws -> RuntimeImage {
        guard let handle = ABIRetainLoadedImage(identity.loadGeneration) else {
            // Add-image notification precedes initializers. RTLD_NOLOAD on a
            // different thread may refuse that still-registered generation.
            if try Self.current().contains(where: { $0.identity == identity }) {
                throw RuntimeResolutionError.imageUnavailable
            }
            throw RuntimeResolutionError.imageChanged
        }
        return RuntimeImage(identity: identity, path: path, lease: RuntimeImageLease(handle))
    }

    package static func current() throws -> [Self] { try catalog().images }

    package static func catalog() throws -> RuntimeImageCatalogSnapshot {
        guard let list = ABICopyLoadedImages() else {
            throw RuntimeResolutionError.imageUnavailable
        }
        defer { ABIFreeImageList(list) }
        let revision = ABIImageListRevision(list)
        return cachedCatalog.withLock { cached in
            if let cached, cached.revision == revision { return cached }
            let snapshot = RuntimeImageCatalogSnapshot(
                revision: revision,
                images: (0..<ABIImageListCount(list)).map {
                    Self(ABIImageListGet(list, $0))
                }
            )
            // Another caller can have captured a newer native list before this
            // caller acquires the Swift lock. Its snapshot stays authoritative.
            if cached == nil || cached!.revision < revision { cached = snapshot }
            return snapshot
        }
    }

}

package enum FrameworkImages {
    package static var bundleDirectories: [URL] {
        [Bundle.main.privateFrameworksURL, Bundle.main.sharedFrameworksURL].compactMap { $0 }
    }

    package static func candidates(
        named name: String,
        bundleDirectories: [URL] = FrameworkImages.bundleDirectories
    ) -> [URL] {
        var paths = bundleDirectories.map { $0.appendingPathComponent("\(name).framework/\(name)") }
        var systemPaths = ["/System/Library/Frameworks", "/System/Library/PrivateFrameworks"]
        #if targetEnvironment(macCatalyst)
        systemPaths += [
            "/System/iOSSupport/System/Library/Frameworks",
            "/System/iOSSupport/System/Library/PrivateFrameworks",
        ]
        #endif
        paths += systemPaths.map { URL(fileURLWithPath: "\($0)/\(name).framework/\(name)") }
        return Array(
            Set(
                paths.filter { url in
                    if url.path.withCString({ ABIImageIsInSharedCache($0) }) { return true }
                    if FileManager.default.fileExists(atPath: url.path) { return true }
                    #if targetEnvironment(simulator)
                    if let root = ProcessInfo.processInfo.environment["SIMULATOR_ROOT"],
                        url.path.hasPrefix("/System/")
                    {
                        return FileManager.default.fileExists(atPath: root + url.path)
                    }
                    #endif
                    return false
                }.map { $0.resolvingSymlinksInPath() }
            )
        ).sorted { $0.path < $1.path }
    }
}

package struct RuntimeSymbol: Sendable {
    package init(
        declaration: RuntimeDeclaration,
        image: RuntimeImage,
        sectionRange: Range<UInt64>,
        source: Source,
        address: UInt64,
        linkageName: String
    ) {
        self.declaration = declaration; self.image = image; self.sectionRange = sectionRange
        self.source = source; self.address = address; self.linkageName = linkageName
    }

    package enum Source: String, Sendable {
        case image
        case sharedCache
    }

    package let declaration: RuntimeDeclaration
    package let image: RuntimeImage
    package let sectionRange: Range<UInt64>
    package let source: Source
    package let address: UInt64
    package let linkageName: String

    @unsafe package func withUnsafeAddress<Result: ~Copyable>(
        _ body: (UnsafeRawPointer) throws -> Result
    ) rethrows -> Result {
        try withExtendedLifetime(image) {
            try body(UnsafeRawPointer(bitPattern: UInt(address))!)
        }
    }
}
