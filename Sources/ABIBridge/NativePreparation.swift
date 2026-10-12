import Dispatch

enum NativePreparation {
    // Lookup can wait for native loader locks or another running index scan.
    // Keep that blocking work independent of Swift's cooperative executor.
    private static let workers = DispatchQueue(
        label: "ABIBridge.preparation",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            workers.async { continuation.resume(returning: operation()) }
        }
    }

    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let result: Result<Value, any Error> = await run { Result(catching: operation) }
        return try result.get()
    }
}
