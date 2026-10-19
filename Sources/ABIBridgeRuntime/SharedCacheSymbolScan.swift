import Foundation

// A scan owns captured sources before it becomes visible to another lookup.
// Its body only reads those sources; loader discovery never runs behind this wait.
package final class SharedCacheSymbolScan: @unchecked Sendable {
    private let condition = NSCondition()
    private let query: SymbolQuery
    private let includingSwiftFallback: Bool
    private let relatedQueries: [SymbolQuery]
    private enum State {
        case pending(SharedCacheSymbols.CapturedSymbols)
        case running
        case completed(SharedCacheSymbols.Extraction)
    }
    private var state: State
    #if DEBUG
    private var waitingCallers = 0
    package var waitingCallerCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return waitingCallers
    }
    #endif

    package init(
        sources: SharedCacheSymbols.CapturedSymbols,
        query: SymbolQuery,
        includingSwiftFallback: Bool,
        relatedQueries: [SymbolQuery] = []
    ) {
        state = .pending(sources)
        self.query = query
        self.includingSwiftFallback = includingSwiftFallback
        self.relatedQueries = relatedQueries
    }

    package func result() -> SharedCacheSymbols.Extraction {
        condition.lock()
        while true {
            switch state {
            case .pending(let sources):
                state = .running
                condition.unlock()
                let result = sources.extract(
                    matching: query,
                    includingSwiftFallback: includingSwiftFallback,
                    relatedQueries: relatedQueries
                )
                condition.lock()
                state = .completed(result)
                condition.broadcast()
                condition.unlock()
                return result
            case .running:
                #if DEBUG
                waitingCallers += 1
                #endif
                condition.wait()
                #if DEBUG
                waitingCallers -= 1
                #endif
                continue
            case .completed(let result):
                condition.unlock()
                return result
            }
        }
    }
}
