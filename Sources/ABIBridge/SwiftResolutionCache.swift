import ABIBridgeRuntime
import Synchronization

struct SwiftResolutionTypeKey: Hashable, Sendable {
    let name: String
    let metadata: ObjectIdentifier
    let representation: ObjectIdentifier?
    let image: NativeImageIdentity

    init(_ type: NativeSwiftType) {
        name = type.name
        metadata = ObjectIdentifier(type.metadata)
        representation = type.representation.map(ObjectIdentifier.init)
        image = type.image.identity
    }
}

struct SwiftResolutionOptionsKey: Hashable, Sendable {
    let arguments: [NativeSwiftGenericArgument.Identity]
    let declaration: String?
    let valueABIs: [ObjectIdentifier: NativeType]

    init(_ options: SwiftLookupOptions) {
        arguments = options.genericArguments.map(\.identity)
        declaration = options.declaredSignature
        valueABIs = Dictionary(
            uniqueKeysWithValues: options.valueABIs.map {
                (ObjectIdentifier($0.key.metadata), $0.value)
            }
        )
    }
}

struct SwiftResolutionMemberKey: Hashable, Sendable {
    let role: SwiftMemberRequest.Role
    let isStatic: Bool
    let name: String
    let options: SwiftResolutionOptionsKey

    init(_ member: SwiftMemberRequest) {
        role = member.role
        isStatic = member.isStatic
        name = member.name
        options = SwiftResolutionOptionsKey(member.options)
    }
}

enum SwiftResolutionKey: Hashable, Sendable {
    enum Scope: Hashable, Sendable {
        case automatic
        case images([NativeImageIdentity])
    }

    case function(ObjectIdentifier, String, SwiftResolutionOptionsKey, Scope)
    case nominalType([UInt8], ObjectIdentifier?, [NativeSwiftGenericArgument.Identity], Scope)
    case instance(
        ObjectIdentifier,
        SwiftResolutionTypeKey,
        SwiftResolutionMemberKey,
        SwiftReceiverRequest
    )
    case typeMember(ObjectIdentifier, SwiftResolutionTypeKey, SwiftResolutionMemberKey)
    case keyPath(SwiftResolutionTypeKey, String, SwiftResolutionTypeKey, String?)

    var cache: ABIRuntime.Cache {
        if case .nominalType = self { return .swiftTypes }
        return .swiftResolutions
    }
}

/// Owns completed Swift resolutions independently of their retained types and resolvers.
final class SwiftResolutionCache: Sendable {
    static let shared = SwiftResolutionCache()

    private final class Entry: Sendable {
        let value: any Sendable
        // Keep every metadata identity in the key alive, including ABI overrides
        // that the selected declaration did not need during preparation.
        let request: any Sendable
        let owner: NativeSwiftType?
        let arguments: [NativeSwiftGenericArgument]
        let dependency: RuntimeCatalogDependency
        let slot: SwiftCapturedSlot?

        init<Value: Sendable, Request: Sendable>(
            _ value: Value,
            request: Request,
            owner: NativeSwiftType?,
            arguments: [NativeSwiftGenericArgument],
            dependency: RuntimeCatalogDependency,
            slot: SwiftCapturedSlot?
        ) {
            self.value = value
            self.request = request
            self.owner = owner
            self.arguments = arguments
            self.dependency = dependency
            self.slot = slot
        }

        func retainsOwners(of arguments: [NativeSwiftGenericArgument]) -> Bool {
            self.arguments.count == arguments.count
                && zip(self.arguments, arguments).allSatisfy { $0.retainsOwners(of: $1) }
        }
    }

    private struct State: Sendable {
        var generations: [ABIRuntime.Cache: UInt64] = [:]
        var entries: [SwiftResolutionKey: Entry] = [:]
    }
    private let state = Mutex(State())

    func resolve<Value: Sendable, Request: Sendable>(
        _ key: SwiftResolutionKey,
        request: Request,
        owner: NativeSwiftType? = nil,
        arguments: [NativeSwiftGenericArgument] = [],
        capturedSlot: (Value) -> SwiftCapturedSlot? = { _ in nil },
        prepare: () throws -> Value
    ) throws -> Value {
        let arguments = (owner?.genericArguments ?? []) + arguments
        let (cached, generation) = state.withLock {
            ($0.entries[key], $0.generations[key.cache, default: 0])
        }
        if let cached,
            let value: Value = value(of: cached, arguments: arguments, current: \.isCurrent)
        {
            return value
        }
        if let cached {
            let retired = state.withLock { state -> Entry? in
                guard state.entries[key] === cached else { return nil }
                return state.entries.removeValue(forKey: key)
            }
            withExtendedLifetime(retired) {}
        }

        // Preparation can invoke metadata accessors, codecs, and loader callbacks.
        // Only completed results are shared; waiting on the whole lookup can deadlock.
        let (value, dependency) = try RuntimeCatalogDependency.recording(prepare)
        guard dependency.isCurrent else { return value }
        let entry = Entry(
            value,
            request: request,
            owner: owner,
            arguments: arguments,
            dependency: dependency,
            slot: capturedSlot(value)
        )
        let (selected, displaced) = state.withLock { state -> (Entry, Entry?) in
            guard state.generations[key.cache, default: 0] == generation else {
                return (entry, nil)
            }
            if let existing = state.entries[key], existing.dependency == entry.dependency,
                existing.slot == entry.slot, existing.retainsOwners(of: arguments)
            {
                return (existing, nil)
            }
            return (entry, state.entries.updateValue(entry, forKey: key))
        }
        // Releasing a result can release images and reenter lookup.
        withExtendedLifetime(displaced) {}
        return selected.value as? Value ?? value
    }

    /// The completed result for `key` when validating it searches no image.
    func unchangedValue<Value: Sendable>(
        _ key: SwiftResolutionKey,
        owner: NativeSwiftType? = nil,
        arguments: [NativeSwiftGenericArgument] = []
    ) -> Value? {
        guard let cached = state.withLock({ $0.entries[key] }) else { return nil }
        return value(
            of: cached,
            arguments: (owner?.genericArguments ?? []) + arguments,
            current: \.isUnchanged
        )
    }

    private func value<Value>(
        of entry: Entry,
        arguments: [NativeSwiftGenericArgument],
        current: (RuntimeCatalogDependency) -> Bool
    ) -> Value? {
        guard entry.retainsOwners(of: arguments), current(entry.dependency),
            entry.slot?.isCurrent != false, let value = entry.value as? Value
        else { return nil }
        entry.dependency.record()
        return value
    }

    func removeCachedResults(in caches: Set<ABIRuntime.Cache>) {
        let removed = state.withLock { state in
            for cache in caches { state.generations[cache, default: 0] &+= 1 }
            let removed = state.entries.filter { caches.contains($0.key.cache) }
            for key in removed.keys { state.entries.removeValue(forKey: key) }
            return removed
        }
        withExtendedLifetime(removed) {}
    }
}

extension SymbolResolver {
    func resolveSwift<Value: Sendable, Request: Sendable>(
        _ key: SwiftResolutionKey,
        request: Request,
        owner: NativeSwiftType? = nil,
        arguments: [NativeSwiftGenericArgument] = [],
        capturedSlot: (Value) -> SwiftCapturedSlot? = { _ in nil },
        prepare: () throws -> Value
    ) throws -> Value {
        guard let resolutionCache else { return try withCachedLookups(prepare) }
        // Without an image search, a completed result needs no lookup batch,
        // so returning it takes no resolver lock and releases no index.
        if let value: Value = resolutionCache.unchangedValue(
            key,
            owner: owner,
            arguments: arguments
        ) {
            return value
        }
        return try withCachedLookups {
            try resolutionCache.resolve(
                key,
                request: request,
                owner: owner,
                arguments: arguments,
                capturedSlot: capturedSlot,
                prepare: prepare
            )
        }
    }
}
