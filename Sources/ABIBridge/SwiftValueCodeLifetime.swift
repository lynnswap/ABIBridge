import Foundation

// Native values can share references, and a later call can install code-bearing
// values through any alias. Their code dependencies must therefore grow together.
// Only image leases live here: payloads and access leases keep their own lifetimes.
final class SwiftValueCodeLifetime: @unchecked Sendable {
    @TaskLocal static var current: SwiftValueCodeLifetime?
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

    // A host callback can pass an ordinary Swift reference into another native
    // call. Carry its code dependencies across that call and async suspension.
    static func withCurrent<Result>(_ lifetime: SwiftValueCodeLifetime?,
                                    _ operation: () throws -> Result) rethrows -> Result {
        let previous = current
        guard let lifetime, lifetime !== previous else { return try operation() }
        let connected = previous.map { connect([lifetime, $0], retaining: [])! } ?? lifetime
        return try $current.withValue(connected, operation: operation)
    }

    static func withCurrent<Result>(_ lifetime: SwiftValueCodeLifetime?,
                                    isolation: isolated (any Actor)? = #isolation,
                                    _ operation: nonisolated(nonsending) () async throws -> Result) async rethrows -> Result {
        let previous = current
        guard let lifetime, lifetime !== previous else { return try await operation() }
        let connected = previous.map { connect([lifetime, $0], retaining: [])! } ?? lifetime
        return try await $current.withValue(connected) {
            // Explicitly capture the isolated parameter so the closure keeps
            // the native caller's actor when converted to TaskLocal's body type.
            _ = isolation
            return try await operation()
        }
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
