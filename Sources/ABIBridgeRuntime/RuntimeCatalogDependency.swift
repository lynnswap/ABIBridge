import Synchronization

/// The loaded-image catalog observed while deriving a result.
package enum RuntimeCatalogDependency: Equatable, Sendable {
    case none
    case revision(UInt64)
    case unstable

    private final class Recorder: Sendable {
        let parent: Recorder?
        let value = Mutex<RuntimeCatalogDependency>(.none)

        init(parent: Recorder?) { self.parent = parent }

        func record(_ dependency: RuntimeCatalogDependency) {
            value.withLock { current in
                switch (current, dependency) {
                case (_, .none): break
                case (.none, _): current = dependency
                case (.revision(let first), .revision(let second)) where first == second: break
                default: current = .unstable
                }
            }
            parent?.record(dependency)
        }
    }

    @TaskLocal private static var recorder: Recorder?

    package static func recording<Value>(
        _ operation: () throws -> Value
    ) rethrows -> (value: Value, dependency: Self) {
        let current = Recorder(parent: recorder)
        let value = try $recorder.withValue(current, operation: operation)
        return (value, current.value.withLock { $0 })
    }

    package func record() { Self.recorder?.record(self) }

    package var isCurrent: Bool {
        switch self {
        case .none: true
        case .revision(let revision): (try? RuntimeImageSnapshot.catalog().revision) == revision
        case .unstable: false
        }
    }
}
