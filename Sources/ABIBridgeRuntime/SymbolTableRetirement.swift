import Dispatch
import Synchronization

/// Tables that retirement frees explicitly, so the last reference to their
/// container can be dropped on any thread.
protocol RetiredSymbolTables: AnyObject, Sendable {
    func freeTables()
}

/// Frees the symbol tables of ended lookup batches on a worker.
///
/// Any thread can end a batch, including the main thread, and freeing an
/// image's tables can take as long as building them. Tables wait here only
/// until the worker frees them. Building tables while more than `limit` is
/// pending frees that backlog on the building thread, so a delayed worker
/// does not keep retired tables alive alongside their replacements.
/// Weights approximate the stored entries; they do not bound resident memory.
package final class SymbolTableRetirement: Sendable {
    private struct Retired: Sendable {
        let tables: any RetiredSymbolTables
        let weight: Int
    }
    private struct State: Sendable {
        var pending: [Retired] = []
        var isScheduled = false
    }
    private let state = Mutex(State())
    // Includes tables that a thread has taken but not yet released.
    private let pendingWeight = Atomic(0)
    private let limit: Int
    private let queue = DispatchQueue(label: "ABIBridge.SymbolTableRetirement", qos: .utility)
    #if DEBUG
    private let releasing: (@Sendable () -> Void)?
    private let retired: (@Sendable () -> Void)?
    #endif

    package init(limit: Int) {
        self.limit = limit
        #if DEBUG
        releasing = nil
        retired = nil
        #endif
    }

    #if DEBUG
    /// - Parameters:
    ///   - releasing: Called on the worker before it frees tables.
    ///   - retired: Called on the retiring thread after it schedules the worker.
    package init(
        limit: Int,
        beforeReleasing releasing: (@Sendable () -> Void)? = nil,
        afterRetiring retired: (@Sendable () -> Void)? = nil
    ) {
        self.limit = limit
        self.releasing = releasing
        self.retired = retired
    }

    package var pendingTableWeight: Int { pendingWeight.load(ordering: .relaxed) }

    /// Waits until the worker has freed the tables retired so far.
    package func waitForWorker() { queue.sync {} }
    #endif

    func retire(_ tables: some RetiredSymbolTables, weight: Int) {
        pendingWeight.add(weight, ordering: .relaxed)
        let schedules = state.withLock { state in
            state.pending.append(Retired(tables: tables, weight: weight))
            defer { state.isScheduled = true }
            return !state.isScheduled
        }
        if schedules { queue.async { self.releaseScheduled() } }
        #if DEBUG
        retired?()
        #endif
    }

    /// Frees the pending tables on the caller's thread when they exceed the
    /// limit. Called after a table build has grown its tables.
    func relieve() {
        guard pendingWeight.load(ordering: .relaxed) > limit else { return }
        release(state.withLock { state in
            defer { state.pending.removeAll() }
            return state.pending
        })
    }

    private func releaseScheduled() {
        #if DEBUG
        releasing?()
        #endif
        while true {
            let retired = state.withLock { state in
                defer { state.pending.removeAll() }
                if state.pending.isEmpty { state.isScheduled = false }
                return state.pending
            }
            guard !retired.isEmpty else { return }
            release(retired)
        }
    }

    private func release(_ retired: [Retired]) {
        for entry in retired { entry.tables.freeTables() }
        pendingWeight.subtract(retired.reduce(0) { $0 + $1.weight }, ordering: .relaxed)
    }
}
