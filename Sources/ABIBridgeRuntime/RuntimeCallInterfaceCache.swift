import ABIBridgeCore
import Foundation
import Synchronization

struct RuntimeCallInterfaceKey: Sendable, Equatable {
    let result: RuntimeValueType
    let parameters: [RuntimeValueType]
    var fixedParameterCount: Int? = nil
    var error: RuntimeValueType? = nil
    var typedError = false
    var inheritsCallerIsolation = false

    static func == (first: Self, second: Self) -> Bool {
        guard first.parameters.count == second.parameters.count,
            first.fixedParameterCount == second.fixedParameterCount,
            first.typedError == second.typedError,
            first.inheritsCallerIsolation == second.inheritsCallerIsolation,
            equal(first.result, second.result)
        else { return false }
        switch (first.error, second.error) {
        case (.none, .none): break
        case (.some(let first), .some(let second)):
            guard equal(first, second) else { return false }
        default: return false
        }
        return zip(first.parameters, second.parameters).allSatisfy(equal)
    }

    private static func equal(_ first: RuntimeValueType, _ second: RuntimeValueType) -> Bool {
        first === second || ABIValueTypesEqual(first.handle, second.handle)
    }
}

// Keys contain only native layouts. Codecs, metatypes, image discovery, and
// callback bodies are resolved before reaching this cache.
final class RuntimeCallInterfaceCache<Interface: Sendable>: Sendable {
    #if DEBUG
    private let beforeWaitingForPreparation: (@Sendable () -> Void)?

    init(beforeWaitingForPreparation: (@Sendable () -> Void)? = nil) {
        self.beforeWaitingForPreparation = beforeWaitingForPreparation
    }
    #endif

    private struct Entry: Sendable {
        let key: RuntimeCallInterfaceKey
        let preparation: Preparation
    }

    // The condition protects every access to state. The build only lowers
    // immutable native layouts and never calls a codec or loads an image.
    private final class Preparation: @unchecked Sendable {
        private enum State {
            case pending
            case running
            case completed(Result<Interface, any Error>)
        }

        private let condition = NSCondition()
        private var state = State.pending
        #if DEBUG
        private let beforeWaiting: (@Sendable () -> Void)?

        init(beforeWaiting: (@Sendable () -> Void)?) {
            self.beforeWaiting = beforeWaiting
        }
        #endif

        var isCompleted: Bool {
            condition.lock()
            defer { condition.unlock() }
            if case .completed = state { return true }
            return false
        }

        func result(build: () throws -> Interface) throws -> Interface {
            condition.lock()
            while true {
                switch state {
                case .pending:
                    state = .running
                    condition.unlock()
                    let result = Result { try build() }
                    condition.lock()
                    state = .completed(result)
                    condition.broadcast()
                    condition.unlock()
                    return try result.get()
                case .running:
                    #if DEBUG
                    // Notify under the condition lock so completion cannot
                    // overtake the waiter. The callback must not reenter the cache.
                    beforeWaiting?()
                    #endif
                    condition.wait()
                case .completed(let result):
                    condition.unlock()
                    return try result.get()
                }
            }
        }
    }

    private let entries = Mutex<[Entry]>([])

    func interface(
        for key: RuntimeCallInterfaceKey,
        build: () throws -> Interface
    ) throws -> Interface {
        let preparation = entries.withLock { entries in
            if let entry = entries.last(where: { $0.key == key }) {
                return entry.preparation
            }
            #if DEBUG
            let preparation = Preparation(beforeWaiting: beforeWaitingForPreparation)
            #else
            let preparation = Preparation()
            #endif
            entries.append(Entry(key: key, preparation: preparation))
            return preparation
        }
        let result: Interface
        do {
            result = try preparation.result(build: build)
        } catch {
            let retired = entries.withLock { entries in
                var retired: [Entry] = []
                entries.removeAll { entry in
                    guard entry.preparation === preparation else { return false }
                    retired.append(entry)
                    return true
                }
                return retired
            }
            withExtendedLifetime(retired) {}
            throw error
        }
        let retired = entries.withLock { entries in
            // In-flight entries remain available to all callers. Only the
            // completed cache is bounded; active handles survive eviction.
            var completedCount = entries.filter { $0.preparation.isCompleted }.count
            var retired: [Entry] = []
            entries.removeAll { entry in
                guard completedCount > 64, entry.preparation.isCompleted else { return false }
                completedCount -= 1
                retired.append(entry)
                return true
            }
            return retired
        }
        // An interface can acquire callback stubs and image leases after its
        // preparation. Their disposal can reenter the loader or another lookup.
        withExtendedLifetime(retired) {}
        return result
    }
}
