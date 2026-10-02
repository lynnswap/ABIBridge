import Foundation

// Native values can share references, and a later call can install code-bearing
// values through any alias. Their code dependencies must therefore grow together.
// Only image leases live here: payloads and access leases keep their own lifetimes.
final class SwiftValueCodeLifetime: @unchecked Sendable {
    private static let lock = NSLock()
    private var parent: SwiftValueCodeLifetime?
    private var rank = 0
    private var retainedImages: [NativeImageIdentity: NativeImage]

    init(_ images: [NativeImage]) {
        retainedImages = Dictionary(images.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var images: [NativeImage] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return Array(root.retainedImages.values)
    }

    // Called only with the shared lock held. Union by rank bounds both lookup
    // depth and the strong parent chain without introducing retention cycles.
    private var root: SwiftValueCodeLifetime { parent?.root ?? self }

    @discardableResult
    static func connect(_ lifetimes: [SwiftValueCodeLifetime], retaining images: @autoclosure () -> [NativeImage]) -> SwiftValueCodeLifetime? {
        guard let first = lifetimes.first else { return nil }
        let additions = images()
        var released: [[NativeImageIdentity: NativeImage]] = []
        lock.lock()
        var root = first.root
        for lifetime in lifetimes.dropFirst() {
            var other = lifetime.root
            guard root !== other else { continue }
            if root.rank < other.rank { swap(&root, &other) }
            if root.rank == other.rank { root.rank += 1 }
            for (identity, image) in other.retainedImages where root.retainedImages[identity] == nil {
                root.retainedImages[identity] = image
            }
            released.append(other.retainedImages)
            other.retainedImages = [:]
            other.parent = root
        }
        for image in additions where root.retainedImages[image.identity] == nil {
            root.retainedImages[image.identity] = image
        }
        lock.unlock()
        // dlclose can reenter native code; never release an image under the lock.
        withExtendedLifetime(released) {}
        return root
    }
}
