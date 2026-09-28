import ABIBridge
import ManagedSwiftAdapters
import ManagedSwiftFixtures
import Testing

private func metadataPointer(_ type: Any.Type) -> UnsafeRawPointer {
    unsafeBitCast(type, to: UnsafeRawPointer.self)
}

private enum GenericCallFailure: Error { case status(Int32) }

private func genericStorage<Value: GenericMetric>(_ value: Value, runtime: ABIRuntime) async throws -> NativeValue {
    let initialize = try await runtime.cFunction(
        named: "ABIGenericRecordInitialize",
        as: ((UnsafeRawPointer?, UnsafeRawPointer, UnsafeMutableRawPointer) -> Int32).self
    )
    let destroy = try await runtime.cFunction(
        named: "ABIGenericRecordDestroy",
        as: ((UnsafeRawPointer?, UnsafeMutableRawPointer) -> Int32).self
    )
    let layout = try NativeType.opaque(named: String(reflecting: GenericRecord<Value>.self),
                                      size: MemoryLayout<GenericRecord<Value>>.stride,
                                      alignment: MemoryLayout<GenericRecord<Value>>.alignment)
    let argument = metadataPointer(Value.self)
    // The compiler-provided concrete metatype owns sizing; the retained handles
    // own adapter images through the last value destruction.
    return try NativeValue(type: layout, retaining: (initialize, destroy), destroy: { address in
        do { #expect(try unsafe destroy.unsafeInvoke(argument, address) == 0) }
        catch { Issue.record(error) }
    }) { output in
        try withUnsafePointer(to: value) { input in
            let status = try unsafe initialize.unsafeInvoke(argument, UnsafeRawPointer(input), output.baseAddress!)
            guard status == 0 else { throw GenericCallFailure.status(status) }
        }
    }
}

struct SwiftGenericMetadataTests {
    @Test func metatypeSubstitutionsProduceCanonicalSpecializations() async throws {
        let resolve = try await ABIRuntime.shared.cFunction(
            named: "ABIGenericRecordMetadata",
            as: ((UnsafeRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>) -> Int32).self
        )
        for (argument, expected): (Any.Type, Any.Type) in [
            (ManagedRecord.self, GenericRecord<ManagedRecord>.self),
            (ResilientRecord.self, GenericRecord<ResilientRecord>.self),
            (ConditionalMetric<ManagedRecord>.self, GenericRecord<ConditionalMetric<ManagedRecord>>.self)
        ] {
            for _ in 0..<100 {
                var result: UnsafeRawPointer?
                let status = try withUnsafeMutablePointer(to: &result) {
                    try unsafe resolve.unsafeInvoke(metadataPointer(argument), $0)
                }
                #expect(status == 0)
                #expect(result == metadataPointer(expected))
            }
        }
        #expect(metadataPointer(GenericRecord<ManagedRecord>.self) != metadataPointer(GenericRecord<ResilientRecord>.self))
    }

    @Test func missingMetadataAndUnsatisfiedConstraintsLeaveOutputUntouched() async throws {
        let resolve = try await ABIRuntime.shared.cFunction(
            named: "ABIGenericRecordMetadata",
            as: ((UnsafeRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>) -> Int32).self
        )
        for (argument, expected): (UnsafeRawPointer?, Int32) in [
            (nil, 1), (metadataPointer(String.self), 2),
            (metadataPointer(ConditionalMetric<String>.self), 2)
        ] {
            var result: UnsafeRawPointer? = metadataPointer(Int.self)
            let status = try withUnsafeMutablePointer(to: &result) { try unsafe resolve.unsafeInvoke(argument, $0) }
            #expect(status == expected)
            #expect(result == metadataPointer(Int.self))
        }
    }

    @Test func constrainedGenericCallsPreserveManagedAndResilientValues() async throws {
        let runtime = ABIRuntime()
        let measure = try await runtime.cFunction(
            named: "ABIGenericRecordMeasure",
            as: ((UnsafeRawPointer?, UnsafeRawPointer, UnsafeMutablePointer<Int64>) -> Int32).self
        )
        func check<Value: GenericMetric>(_ value: Value) async throws {
            let storage = try await genericStorage(value, runtime: runtime)
            var actual: Int64 = -1
            let status = try unsafe storage.withUnsafeBytes { input in
                try withUnsafeMutablePointer(to: &actual) {
                    try unsafe measure.unsafeInvoke(metadataPointer(Value.self), input.baseAddress!, $0)
                }
            }
            #expect(status == 0)
            #expect(actual == measureGenericRecord(makeGenericRecord(value)))
            let copy = unsafe storage.withUnsafeBytes { $0.baseAddress!.load(as: GenericRecord<Value>.self) }
            #expect(copy.value.metric == value.metric)
        }
        let token = LifetimeToken()
        try await check(ManagedRecord(token: token, number: 42))
        try await check(ResilientRecord(token: token, number: 43))
        try await check(ConditionalMetric(ManagedRecord(token: token, number: 44)))
    }

    @Test func genericResultOutlivesArgumentsAndLookupRuntime() async throws {
        var stored: NativeValue?
        weak var observed: LifetimeToken?
        var destroyed = 0
        do {
            let runtime = ABIRuntime()
            let token = LifetimeToken { destroyed += 1 }
            observed = token
            stored = try await genericStorage(ResilientRecord(token: token, number: 42), runtime: runtime)
            await runtime.removeCachedResults()
        }
        withExtendedLifetime(stored) {
            #expect(observed != nil)
            #expect(destroyed == 0)
        }
        let actual = unsafe stored!.withUnsafeBytes {
            $0.baseAddress!.load(as: GenericRecord<ResilientRecord>.self).value.number
        }
        #expect(actual == 42)
        stored = nil
        #expect(observed == nil)
        #expect(destroyed == 1)
    }

    @Test func rejectedGenericCallDoesNotInitializeResult() async throws {
        let initialize = try await ABIRuntime.shared.cFunction(
            named: "ABIGenericRecordInitialize",
            as: ((UnsafeRawPointer?, UnsafeRawPointer, UnsafeMutableRawPointer) -> Int32).self
        )
        var input: Int64 = 42, output: Int64 = 99
        let status = try withUnsafePointer(to: &input) { input in
            try withUnsafeMutablePointer(to: &output) { output in
                try unsafe initialize.unsafeInvoke(metadataPointer(Int64.self), UnsafeRawPointer(input),
                                                    UnsafeMutableRawPointer(output))
            }
        }
        #expect(status == 2)
        #expect(output == 99)
    }
}
