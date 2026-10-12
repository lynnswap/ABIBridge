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
}
