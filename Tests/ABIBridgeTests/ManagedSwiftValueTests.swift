import ABIBridge
import ManagedSwiftAdapters
import ManagedSwiftFixtures
import Testing

private enum ManagedConversionError: Error { case rejected }

private func storageType<Value>(for type: Value.Type) throws -> NativeType {
    try .opaque(
        named: String(reflecting: type),
        size: MemoryLayout<Value>.stride,
        alignment: MemoryLayout<Value>.alignment
    )
}

private func copiedStorage<Value>(_ value: Value) throws -> NativeValue {
    NativeValue(
        type: try storageType(for: Value.self),
        destroy: { destroyValue(Value.self, at: $0) }
    ) { bytes in
        withUnsafePointer(to: value) { copyValue(Value.self, from: $0, to: bytes.baseAddress!) }
    }
}

private func readStorage<Value>(_ storage: NativeValue, as type: Value.Type) -> Value {
    unsafe storage.withUnsafeBytes { $0.baseAddress!.load(as: type) }
}

private func transformedStorage<Value>(
    _ value: Value,
    named name: String
) async throws -> NativeValue {
    let function = try ABIRuntime.shared.resolveCFunctionAndWait(
        named: name,
        as: ((UnsafeRawPointer, UnsafeMutableRawPointer) -> Void).self
    )
    let input = try copiedStorage(value)
    return try NativeValue(
        type: storageType(for: Value.self),
        retaining: function,
        destroy: { destroyValue(Value.self, at: $0) }
    ) { output in
        try unsafe input.withUnsafeBytes { input in
            try unsafe function.unsafeInvoke(input.baseAddress!, output.baseAddress!)
        }
    }
}

private struct ManagedArgument: ABIBridgeValue {
    static let abiType = NativeType.pointer
    let value: ManagedRecord

    init(_ value: ManagedRecord) { self.value = value }
    init(nativeValue: NativeValue) throws { throw ManagedConversionError.rejected }
    static func nativeValue(from value: Self) throws -> NativeValue {
        .reference(to: try copiedStorage(value.value))
    }
}

private struct RejectingPointer: ABIBridgeValue {
    static let abiType = NativeType.pointer
    init() {}
    init(nativeValue: NativeValue) throws { throw ManagedConversionError.rejected }
    static func nativeValue(from value: Self) throws -> NativeValue {
        throw ManagedConversionError.rejected
    }
}

private struct RejectedOwnedResult: ABIBridgeValue {
    static let abiType = NativeType.pointer

    init(nativeValue: NativeValue) throws {
        let pointer = try unsafe nativeValue.read(as: UnsafeMutableRawPointer.self)
        let adopted = unsafe NativeValue(
            adopting: pointer,
            as: try .opaque(named: "ResilientRecord"),
            retaining: nativeValue,
            release: resilientRecordDestroy
        )
        try withExtendedLifetime(adopted) { throw ManagedConversionError.rejected }
    }

    static func nativeValue(from value: Self) throws -> NativeValue {
        throw ManagedConversionError.rejected
    }
}

struct ManagedSwiftValueTests {
    @Test func importedManagedValuePreservesReferenceOwnership() async throws {
        weak var weakToken: LifetimeToken?
        var destroyed = 0
        var result: NativeValue?
        do {
            let token = LifetimeToken { destroyed += 1 }
            weakToken = token
            let input = ManagedRecord(token: token, number: 41)
            result = try await transformedStorage(input, named: "ABIManagedRecordTransform")
            let actual = readStorage(result!, as: ManagedRecord.self)
            #expect(actual.number == transformManaged(input).number)
            #expect(actual.token === token)
        }
        withExtendedLifetime(result) {
            #expect(weakToken != nil)
            #expect(destroyed == 0)
        }
        result = nil
        #expect(weakToken == nil)
        #expect(destroyed == 1)
    }

    @Test func optionalValuePreservesSomeAndNone() async throws {
        for value: Int64? in [nil, 0, 41] {
            let result = try await transformedStorage(value, named: "ABIOptionalValueTransform")
            #expect(readStorage(result, as: Int64?.self) == transformOptional(value))
        }
    }

    @Test func importedResilientValueUsesCompilerLowering() async throws {
        weak var weakToken: LifetimeToken?
        var result: NativeValue?
        do {
            let token = LifetimeToken()
            weakToken = token
            let input = ResilientRecord(token: token, number: 41)
            result = try await transformedStorage(input, named: "ABIResilientRecordTransform")
            let actual = readStorage(result!, as: ResilientRecord.self)
            #expect(actual.number == transformResilient(input).number)
            #expect(actual.token === token)
        }
        withExtendedLifetime(result) { #expect(weakToken != nil) }
        result = nil
        #expect(weakToken == nil)
    }

    @Test func genericCopyMoveAndDestructionBalanceReferences() throws {
        weak var weakToken: LifetimeToken?
        var destroyed = 0
        var result: NativeValue?
        do {
            let token = LifetimeToken { destroyed += 1 }
            weakToken = token
            let original = try copiedStorage(ResilientRecord(token: token, number: 7))
            let type = try storageType(for: ResilientRecord.self)
            let temporary = UnsafeMutableRawPointer.allocate(
                byteCount: max(type.size, 1),
                alignment: type.alignment
            )
            unsafe original.withUnsafeBytes {
                copyValue(ResilientRecord.self, from: $0.baseAddress!, to: temporary)
            }
            result = NativeValue(
                type: type,
                destroy: { destroyValue(ResilientRecord.self, at: $0) }
            ) { output in
                moveValue(ResilientRecord.self, from: temporary, to: output.baseAddress!)
            }
            // moveValue left temporary uninitialized; only its allocation remains.
            temporary.deallocate()
            #expect(readStorage(result!, as: ResilientRecord.self).number == 7)
        }
        withExtendedLifetime(result) {
            #expect(weakToken != nil)
            #expect(destroyed == 0)
        }
        result = nil
        #expect(weakToken == nil)
        #expect(destroyed == 1)
    }

    @Test func failedArgumentConversionCleansUpWithoutDestroyingOutput() async throws {
        let function = try ABIRuntime.shared.resolveCFunctionAndWait(
            named: "ABIManagedRecordTransform",
            as: ((ManagedArgument, RejectingPointer) -> Void).self
        )
        var destroys = 0
        weak var weakToken: LifetimeToken?
        do {
            let token = LifetimeToken()
            weakToken = token
            let input = ManagedArgument(ManagedRecord(token: token, number: 41))
            let type = try storageType(for: ManagedRecord.self)
            #expect(throws: ManagedConversionError.self) {
                _ = try NativeValue(type: type, destroy: { _ in destroys += 1 }) { _ in
                    try unsafe function.unsafeInvoke(input, RejectingPointer())
                }
            }
        }
        #expect(destroys == 0)
        #expect(weakToken == nil)
    }

    @Test func runtimeOnlyHandlesRetainCopiedResources() async throws {
        let runtime = ABIRuntime()
        let create = try runtime.resolveCFunctionAndWait(
            named: "ABIResilientRecordCreate",
            as: ((Int64, UnsafeMutablePointer<Int32>) -> UnsafeMutableRawPointer).self
        )
        let copy = try runtime.resolveCFunctionAndWait(
            named: "ABIResilientRecordCopy",
            as: ((UnsafeRawPointer) -> UnsafeMutableRawPointer).self
        )
        let number = try runtime.resolveCFunctionAndWait(
            named: "ABIResilientRecordNumber",
            as: ((UnsafeRawPointer) -> Int64).self
        )
        let destructor = try runtime.resolveAndWait(
            .init(name: "ABIResilientRecordDestroy", language: .c)
        )
        typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void
        let destroy = unsafe destructor.withUnsafeAddress { unsafeBitCast($0, to: Destroy.self) }
        let opaque = try NativeType.opaque(named: "ResilientRecord")
        func adopt(_ pointer: UnsafeMutableRawPointer) -> NativeValue {
            unsafe NativeValue(
                adopting: pointer,
                as: opaque,
                retaining: destructor,
                release: { destroy($0) }
            )
        }
        let destroyed = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        destroyed.initialize(to: 0)
        defer { destroyed.deinitialize(count: 1); destroyed.deallocate() }
        var original: NativeValue? = adopt(try unsafe create.unsafeInvoke(41, destroyed))
        var duplicate: NativeValue? = try unsafe original!.withUnsafeBytes { bytes in
            adopt(try unsafe copy.unsafeInvoke(bytes.baseAddress!))
        }
        original = nil
        #expect(destroyed.pointee == 0)
        let actual = try unsafe duplicate!.withUnsafeBytes {
            try unsafe number.unsafeInvoke($0.baseAddress!)
        }
        #expect(actual == 41)
        duplicate = nil
        #expect(destroyed.pointee == 1)
    }

    @Test func failedResultConversionDestroysTransferredValue() async throws {
        let create = try ABIRuntime.shared.resolveCFunctionAndWait(
            named: "ABIResilientRecordCreate",
            as: ((Int64, UnsafeMutablePointer<Int32>) -> RejectedOwnedResult).self
        )
        var destroyed: Int32 = 0
        withUnsafeMutablePointer(to: &destroyed) { counter in
            #expect(throws: ManagedConversionError.self) {
                try unsafe create.unsafeInvoke(41, counter)
            }
        }
        #expect(destroyed == 1)
    }

    /// ManagedRecord is frozen in this library-evolution module, so it passes
    /// directly; ResilientRecord is resilient and passes indirectly.
    @Test func declarationTypesInferTheirConventions() async throws {
        let managed = try ABIRuntime.shared.resolveAndWait(
            .function(
                "ManagedSwiftFixtures.transformManaged(_:)",
                as: ((ManagedRecord) -> ManagedRecord).self
            )
        )
        let resilient = try ABIRuntime.shared.resolveAndWait(
            .function(
                "ManagedSwiftFixtures.transformResilient(_:)",
                as: ((ResilientRecord) -> ResilientRecord).self
            )
        )
        weak var weakToken: LifetimeToken?
        var destroyed = 0
        do {
            let token = LifetimeToken { destroyed += 1 }
            weakToken = token
            let record = try unsafe managed.unsafeInvoke(ManagedRecord(token: token, number: 41))
            #expect(record.number == 42)
            #expect(record.token === token)
            let wrapped = try unsafe resilient.unsafeInvoke(
                ResilientRecord(token: token, number: 7)
            )
            #expect(wrapped.number == 8)
            #expect(wrapped.token === token)
        }
        #expect(weakToken == nil)
        #expect(destroyed == 1)
    }

    /// WideLabel's convention is undecided, but its five-register frozen
    /// lowering passes by address at whole positions either way, including
    /// for host values of the declaration's own type.
    @Test func undecidedHostValuesPassByAddressAtWholePositions() async throws {
        let runtime = ABIRuntime.shared
        let describe = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.describeWideLabel(_:)",
                as: ((WideLabel) -> String).self
            )
        )
        #expect(try unsafe describe.unsafeInvoke(WideLabel(name: "host", a: 4)) == "host:4,5,6")
        let make = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.makeWideLabel(_:)",
                as: ((String) -> WideLabel).self
            )
        )
        let made = try unsafe make.unsafeInvoke("made")
        #expect(made.name == "made" && made.a == 1 && made.c == 3)
        let apply = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.applyWideLabel(_:_:)",
                as: ((NativeSwiftClosure<(WideLabel) -> WideLabel>, WideLabel) -> String).self
            )
        )
        let callback = try NativeSwiftClosure { (value: WideLabel) in
            WideLabel(name: value.name + "!", a: value.c)
        }
        #expect(try unsafe apply.unsafeInvoke(callback, WideLabel(name: "cb", a: 1)) == "cb!:3,4,5")
        // A tuple parameter's elements are whole parameters.
        let pair = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.describeWideLabelPair(_:)",
                as: (((WideLabel, Int64)) -> String).self
            )
        )
        #expect(try unsafe pair.unsafeInvoke((WideLabel(name: "pair", a: 1), 7)) == "pair:1,2,3#7")
        // A tuple result's elements are nested, where the conventions differ.
        await #expect {
            _ = try await runtime.resolve(
                .function(
                    "ManagedSwiftFixtures.makeWideLabelPair(_:)",
                    as: ((String) -> (WideLabel, Int64)).self
                )
            )
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains("its field `name: Swift.String` explains")
        }
    }
}
