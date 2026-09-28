import ABIBridge
import ManagedSwiftAdapters
import ManagedSwiftFixtures
import Testing

private func closureStorage<Value>(_ value: Value) throws -> NativeValue {
    NativeValue(
        type: try .opaque(named: String(reflecting: Value.self),
                          size: MemoryLayout<Value>.stride, alignment: MemoryLayout<Value>.alignment),
        destroy: { $0.assumingMemoryBound(to: Value.self).deinitialize(count: 1) }
    ) { bytes in
        bytes.baseAddress!.initializeMemory(as: Value.self, repeating: value, count: 1)
    }
}

struct SwiftClosureABITests {
    @Test func noncapturingAndCapturingInputsUseCompilerReabstraction() async throws {
        let apply = try await ABIRuntime.shared.cFunction(
            named: "ABIIntegerClosureApply", as: ((UnsafeRawPointer, Int64) -> Int64).self
        )
        let bias: Int64 = 7
        let callbacks: [IntegerClosure] = [{ -$0 }, { $0 + bias }]
        for callback in callbacks {
            let input = try closureStorage(callback)
            let actual = try unsafe input.withUnsafeBytes { try unsafe apply.unsafeInvoke($0.baseAddress!, 35) }
            #expect(actual == applyIntegerClosure(callback, 35))
            #expect(actual == concreteThroughGeneric(callback, 35))
        }
    }

    @Test func nativeCalleeRetainsEscapingCaptureAfterInputRelease() async throws {
        let runtime = ABIRuntime.shared
        let retain = try await runtime.cFunction(
            named: "ABIIntegerClosureRetain", as: ((UnsafeRawPointer) -> UnsafeMutableRawPointer).self
        )
        let call = try await runtime.cFunction(
            named: "ABIIntegerClosureCallRetained", as: ((UnsafeRawPointer, Int64) -> Int64).self
        )
        var owner: NativeValue?
        weak var observed: LifetimeToken?
        var destroys = 0
        do {
            let token = LifetimeToken { destroys += 1 }
            observed = token
            let callback: IntegerClosure = { value in withExtendedLifetime(token) { value + 7 } }
            let input = try closureStorage(callback)
            let pointer = try unsafe input.withUnsafeBytes { try unsafe retain.unsafeInvoke($0.baseAddress!) }
            owner = unsafe NativeValue(
                adopting: pointer, as: try .opaque(named: "StoredIntegerClosure"),
                retaining: retain, release: integerClosureRelease
            )
        }
        withExtendedLifetime(owner) {
            #expect(observed != nil)
            #expect(destroys == 0)
        }
        let actual = try unsafe owner!.withUnsafeBytes { try unsafe call.unsafeInvoke($0.baseAddress!, 35) }
        #expect(actual == 42)
        owner = nil
        #expect(observed == nil)
        #expect(destroys == 1)
    }

    @Test func returnedClosureOutlivesCallAndResultStorage() async throws {
        let make = try await ABIRuntime.shared.cFunction(
            named: "ABIIntegerClosureReturn",
            as: ((UnsafeRawPointer, Int64, UnsafeMutableRawPointer) -> Void).self
        )
        var callback: IntegerClosure?
        weak var observed: LifetimeToken?
        var destroys = 0
        do {
            let token = LifetimeToken { destroys += 1 }
            observed = token
            let output = try withExtendedLifetime(token) {
                try NativeValue(
                    type: .opaque(named: "IntegerClosure",
                                  size: MemoryLayout<IntegerClosure>.stride,
                                  alignment: MemoryLayout<IntegerClosure>.alignment),
                    retaining: make,
                    destroy: { $0.assumingMemoryBound(to: IntegerClosure.self).deinitialize(count: 1) }
                ) { bytes in
                    try unsafe make.unsafeInvoke(Unmanaged.passUnretained(token).toOpaque(), 7, bytes.baseAddress!)
                }
            }
            callback = unsafe output.withUnsafeBytes { $0.baseAddress!.load(as: IntegerClosure.self) }
        }
        withExtendedLifetime(callback) {
            #expect(observed != nil)
            #expect(destroys == 0)
        }
        #expect(callback!(35) == 42)
        callback = nil
        #expect(observed == nil)
        #expect(destroys == 1)
    }

    @Test func sendableCallbackKeepsItsConcreteValueContract() async throws {
        let apply = try await ABIRuntime.shared.cFunction(
            named: "ABISendableIntegerClosureApply", as: ((UnsafeRawPointer, Int64) -> Int64).self
        )
        let bias: Int64 = 7
        let callback: SendableIntegerClosure = { $0 + bias }
        let input = try closureStorage(callback)
        let actual = try unsafe input.withUnsafeBytes { try unsafe apply.unsafeInvoke($0.baseAddress!, 35) }
        #expect(actual == applySendableIntegerClosure(callback, 35))
    }

    @MainActor @Test func isolatedCallbackRunsUnderTheCallersExplicitActorContract() async throws {
        let apply = try await ABIRuntime.shared.cFunction(
            named: "ABIIsolatedIntegerClosureApply", as: ((UnsafeRawPointer, Int64) -> Int64).self
        )
        var calls = 0
        let callback: IsolatedIntegerClosure = { value in calls += 1; return value + 7 }
        let input = try closureStorage(callback)
        let actual = try unsafe input.withUnsafeBytes { try unsafe apply.unsafeInvoke($0.baseAddress!, 35) }
        #expect(actual == 42)
        #expect(calls == 1)
    }
}
