import Synchronization

/// The image changes that could affect a completed lookup.
package struct RuntimeCatalogDependency: Equatable, Sendable {
    private let observations: [Observation]
    private let unstable: Bool

    package static let none = Self(observations: [], unstable: false)
    package static let unstable = Self(observations: [], unstable: true)

    private final class Observation: Sendable, Equatable {
        private struct State: Sendable {
            var revision: UInt64
            var images: Set<RuntimeImageIdentity>
        }
        private let state: Mutex<State>
        private let requiredImages: Set<RuntimeImageIdentity>
        private let affectsResult: @Sendable ([RuntimeImageSnapshot]) throws -> Bool

        init(
            catalog: RuntimeImageCatalogSnapshot,
            requiredImages: Set<RuntimeImageIdentity>,
            affectsResult: @escaping @Sendable ([RuntimeImageSnapshot]) throws -> Bool
        ) {
            state = Mutex(
                State(revision: catalog.revision, images: Set(catalog.images.map(\.identity)))
            )
            self.requiredImages = requiredImages
            self.affectsResult = affectsResult
        }

        static func == (lhs: Observation, rhs: Observation) -> Bool { lhs === rhs }

        func isCurrent(in catalog: RuntimeImageCatalogSnapshot) -> Bool {
            let previous = state.withLock { $0 }
            if previous.revision == catalog.revision { return true }
            // A load generation's symbols do not change. Retained results keep
            // their defining images alive; only new generations need searching.
            let images = Set(catalog.images.map(\.identity))
            guard requiredImages.isSubset(of: images) else { return false }
            let added = catalog.images.filter { !previous.images.contains($0.identity) }
            do {
                if !added.isEmpty, try Self.withoutRecording({ try affectsResult(added) }) {
                    return false
                }
                guard try RuntimeImageSnapshot.catalog().revision == catalog.revision else {
                    return false
                }
            } catch { return false }
            state.withLock { current in
                if current.revision < catalog.revision {
                    current = State(revision: catalog.revision, images: images)
                }
            }
            return true
        }

        private static func withoutRecording<Value>(_ body: () throws -> Value) rethrows -> Value {
            try RuntimeCatalogDependency.$recorder.withValue(nil, operation: body)
        }
    }

    package static func observing(
        _ catalog: RuntimeImageCatalogSnapshot,
        requiredImages: Set<RuntimeImageIdentity>,
        affectsResult: @escaping @Sendable ([RuntimeImageSnapshot]) throws -> Bool
    ) -> Self {
        Self(
            observations: [
                Observation(
                    catalog: catalog,
                    requiredImages: requiredImages,
                    affectsResult: affectsResult
                )
            ],
            unstable: false
        )
    }

    private final class Recorder: Sendable {
        let parent: Recorder?
        let value = Mutex<RuntimeCatalogDependency>(.none)

        init(parent: Recorder?) { self.parent = parent }

        func record(_ dependency: RuntimeCatalogDependency) {
            value.withLock { current in
                current = Self.merge(current, dependency)
            }
            parent?.record(dependency)
        }

        private static func merge(
            _ first: RuntimeCatalogDependency,
            _ second: RuntimeCatalogDependency
        ) -> RuntimeCatalogDependency {
            RuntimeCatalogDependency(
                observations: first.observations
                    + second.observations.filter { !first.observations.contains($0) },
                unstable: first.unstable || second.unstable
            )
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
        guard !unstable else { return false }
        guard !observations.isEmpty else { return true }
        guard let catalog = try? RuntimeImageSnapshot.catalog() else { return false }
        return observations.allSatisfy { $0.isCurrent(in: catalog) }
    }
}
