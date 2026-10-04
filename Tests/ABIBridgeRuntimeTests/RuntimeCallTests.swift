import ABIBridgeCore
import ABIBridgeRuntime
import Darwin
import ManagedSwiftFixtures
import Synchronization
import Testing

@c(ABIBridgeRuntimeTestAnchor)
func runtimeTestAnchor() {}

@inline(never) public func runtimeMany(
    _ a: Int64,
    _ b: Int64,
    _ c: Int64,
    _ d: Int64,
    _ e: Int64,
    _ f: Int64,
    _ g: Int64,
    _ h: Int64,
    _ i: Int64,
    _ j: Int64,
    _ k: Double,
    _ l: Double,
    _ m: Double,
    _ n: Double,
    _ o: Double,
    _ p: Double,
    _ q: Double,
    _ r: Double,
    _ s: Double,
    _ t: Double
) -> Double {
    Double(a + b + c + d + e + f + g + h + i + j) + k + l + m + n + o + p + q + r + s + t
}

@inline(never) public func runtimeThrow(_ value: Int64) throws(ScalarFailure) -> Int64 {
    if value == 0 { throw ScalarFailure(0) }
    return value + 1
}

@inline(never) public func runtimeTuple(_ value: (Int64, String)) -> (Int64, String) {
    (value.0 + 1, value.1 + " result")
}

public class RuntimeDispatchBase {
    @inline(never) public func value(_ input: Int64) -> Int64 { input + 1 }
}
public class RuntimeDispatchChild: RuntimeDispatchBase {
    @inline(never) public override func value(_ input: Int64) -> Int64 { input + 2 }
}

// Test inputs own ordinary Swift values. The call under test receives only
// their storage, and output storage is moved exactly once after completion.
private final class CallStorage: @unchecked Sendable {
    let address: UnsafeMutableRawPointer
    private let destroy: () -> Void
    init<Value>(_ value: Value) {
        address = .allocate(
            byteCount: max(1, MemoryLayout<Value>.size),
            alignment: MemoryLayout<Value>.alignment
        )
        address.initializeMemory(as: Value.self, repeating: value, count: 1)
        let pointer = address.assumingMemoryBound(to: Value.self)
        destroy = { pointer.deinitialize(count: 1) }
    }
    init<Result>(result: Result.Type) {
        address = .allocate(
            byteCount: max(1, MemoryLayout<Result>.size),
            alignment: MemoryLayout<Result>.alignment
        )
        destroy = {}
    }
    func take<Value>(_ type: Value.Type) -> Value {
        address.assumingMemoryBound(to: Value.self).move()
    }
    deinit { destroy(); address.deallocate() }
}

enum CallSymbols {
    static let resolver = RuntimeSymbolResolver()
    static func resolve(_ name: String, kind: RuntimeSymbolKind = .function) throws -> RuntimeSymbol
    {
        let anchor: @convention(c) () -> Void = runtimeTestAnchor
        let image = try #require(
            try runtimeImplementationImage(
                containing: unsafeBitCast(anchor, to: UnsafeRawPointer.self)
            )
        )
        return try resolver.resolve(
            .init(name: name, language: .swift, kind: kind),
            in: image,
            loading: .loadedOnly
        )
    }
}

private func invoke<Result>(
    _ symbol: RuntimeSymbol,
    interface: RuntimeSwiftCallInterface,
    arguments: [CallStorage],
    result: Result.Type,
    context: UnsafeRawPointer? = nil
) throws -> Result {
    let output = CallStorage(result: result)
    let pointers = arguments.map { Optional($0.address) }
    var failure: OpaquePointer?
    let succeeded = unsafe symbol.withUnsafeAddress { address in
        pointers.withUnsafeBufferPointer {
            ABIUnsafeInvokeSwiftCallInterface(
                interface.handle,
                ABIUnsafeFunctionAtAddress(address),
                output.address,
                $0.baseAddress,
                context,
                &failure
            )
        }
    }
    guard succeeded else { throw consumeRuntimeCallFailure(failure) }
    return withExtendedLifetime((interface, arguments)) { output.take(result) }
}

struct RuntimeCallTests {
    @Test func variadicCInterfaceUsesThePlatformAnonymousArgumentConvention() throws {
        let pointer = try RuntimeValueType(scalar: ABIValuePointer)
        let count = try RuntimeValueType(scalar: ABIValueUInt64)
        let integer = try RuntimeValueType(scalar: ABIValueInt32)
        let floating = try RuntimeValueType(scalar: ABIValueDouble)
        let interface = try RuntimeCCallInterface(
            result: integer,
            parameters: [pointer, count, pointer, integer, floating],
            fixedParameterCount: 3
        )
        let symbol = try CallSymbols.resolver.resolve(.init(name: "snprintf", language: .c))
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
        defer { buffer.deallocate() }
        try "%d %.1f".withCString { format in
            let arguments = [
                CallStorage(buffer), CallStorage(UInt64(64)), CallStorage(format),
                CallStorage(Int32(7)), CallStorage(Double(2.5)),
            ]
            var result: Int32 = 0, failure: OpaquePointer?
            let success = unsafe symbol.withUnsafeAddress { address in
                arguments.map { Optional($0.address) }.withUnsafeBufferPointer {
                    ABIUnsafeInvokeCCallInterface(
                        interface.handle,
                        ABIUnsafeFunctionAtAddress(address),
                        &result,
                        $0.baseAddress,
                        &failure
                    )
                }
            }
            guard success else { throw consumeRuntimeCallFailure(failure) }
            withExtendedLifetime(arguments) {
                #expect(result == 5 && String(cString: buffer) == "7 2.5")
            }
        }
    }

    @Test func integerAndFloatingRegistersSpillToTheStack() throws {
        let integer = try RuntimeValueType(scalar: ABIValueInt64)
        let floating = try RuntimeValueType(scalar: ABIValueDouble)
        let names =
            Array(repeating: "Swift.Int64", count: 10) + Array(repeating: "Swift.Double", count: 10)
        let symbol = try CallSymbols.resolve(
            "ABIBridgeRuntimeTests.runtimeMany(" + names.joined(separator: ", ")
                + ") -> Swift.Double"
        )
        let interface = try RuntimeSwiftCallInterface(
            result: floating,
            parameters: Array(repeating: integer, count: 10) + Array(repeating: floating, count: 10)
        )
        let values =
            (1...10).map { CallStorage(Int64($0)) } + (1...10).map { CallStorage(Double($0) / 2) }
        let actual = try invoke(
            symbol,
            interface: interface,
            arguments: values,
            result: Double.self
        )
        #expect(
            actual
                == runtimeMany(
                    1,
                    2,
                    3,
                    4,
                    5,
                    6,
                    7,
                    8,
                    9,
                    10,
                    0.5,
                    1,
                    1.5,
                    2,
                    2.5,
                    3,
                    3.5,
                    4,
                    4.5,
                    5
                )
        )
    }

    @Test func tupleLoweringReturnsAnOwnedManagedValue() throws {
        typealias Value = (Int64, String)
        let word = try RuntimeValueType(scalar: ABIValueInt64)
        let string = try RuntimeValueType(fields: [word, word])
        let tuple = try #require(RuntimeTupleMetadata(Value.self)).layout(
            for: Value.self,
            fields: [word, string]
        )
        let interface = try RuntimeSwiftCallInterface(result: tuple, parameters: [tuple])
        let symbol = try CallSymbols.resolve(
            "ABIBridgeRuntimeTests.runtimeTuple((Swift.Int64, Swift.String)) -> (Swift.Int64, Swift.String)"
        )
        let input: Value = (41, String(repeating: "managed ", count: 20))
        let result = try invoke(
            symbol,
            interface: interface,
            arguments: [CallStorage(input)],
            result: Value.self
        )
        let expected = runtimeTuple(input)
        #expect(result.0 == expected.0 && result.1 == expected.1)
    }

    @Test func resilientValuesUseIndirectStorageAndKeepOwnership() throws {
        let token = LifetimeToken()
        let input = ResilientRecord(token: token, number: 41)
        let layout = try RuntimeValueType(
            indirectSwiftSize: MemoryLayout<ResilientRecord>.size,
            alignment: MemoryLayout<ResilientRecord>.alignment
        )
        let interface = try RuntimeSwiftCallInterface(result: layout, parameters: [layout])
        let symbol = try CallSymbols.resolve(
            "ManagedSwiftFixtures.transformResilient(ManagedSwiftFixtures.ResilientRecord) -> ManagedSwiftFixtures.ResilientRecord"
        )
        let result = try invoke(
            symbol,
            interface: interface,
            arguments: [CallStorage(input)],
            result: ResilientRecord.self
        )
        let expected = transformResilient(input)
        #expect(result.token === expected.token && result.number == expected.number)
    }

    @Test func zeroTypedErrorDoesNotSelectTheSuccessStorage() throws {
        let word = try RuntimeValueType(scalar: ABIValueInt64)
        let interface = try RuntimeSwiftCallInterface(
            result: word,
            parameters: [word],
            errorPlan: .init(type: word, isTyped: true)
        )
        let symbol = try CallSymbols.resolve(
            "ABIBridgeRuntimeTests.runtimeThrow(Swift.Int64) throws(ManagedSwiftFixtures.ScalarFailure) -> Swift.Int64"
        )
        for value: Int64 in [0, 41] {
            let input = CallStorage(value), result = CallStorage(result: Int64.self),
                error = CallStorage(result: ScalarFailure.self)
            var failure: OpaquePointer?, didThrow = false
            let success = unsafe symbol.withUnsafeAddress { address in
                [Optional(input.address)].withUnsafeBufferPointer {
                    ABIUnsafeInvokeSwiftThrowingCallInterface(
                        interface.handle,
                        ABIUnsafeFunctionAtAddress(address),
                        result.address,
                        $0.baseAddress,
                        nil,
                        error.address,
                        &didThrow,
                        &failure
                    )
                }
            }
            guard success else { throw consumeRuntimeCallFailure(failure) }
            if didThrow {
                #expect(value == 0 && error.take(ScalarFailure.self).code == 0)
            } else {
                #expect(value == 41 && result.take(Int64.self) == 42)
            }
            withExtendedLifetime(input) {}
        }
    }

    @Test func asyncSuspensionKeepsTheCallerTaskAndResultStorage() async throws {
        let declaration =
            "ManagedSwiftFixtures.asyncMany("
            + (Array(repeating: "Swift.Int64", count: 10)
            + Array(repeating: "Swift.Double", count: 10)).joined(separator: ", ")
            + ") async -> Swift.Double"
        let descriptor = try CallSymbols.resolve(
            "async function pointer to " + declaration,
            kind: .data
        )
        let entry = try RuntimeSwiftAsyncEntry(
            descriptor: UnsafeRawPointer(bitPattern: UInt(descriptor.address))!
        )
        let integer = try RuntimeValueType(scalar: ABIValueInt64),
            floating = try RuntimeValueType(scalar: ABIValueDouble)
        let interface = try RuntimeSwiftAsyncCallInterface(
            result: floating,
            parameters: Array(repeating: integer, count: 10)
                + Array(repeating: floating, count: 10),
            errorPlan: nil,
            inheritsCallerIsolation: false
        )
        let values =
            (1...10).map { CallStorage(Int64($0)) } + (1...10).map { CallStorage(Double($0) / 2) }
        let output = CallStorage(result: Double.self)
        var failure: OpaquePointer?
        let invocation = values.map { Optional($0.address) }.withUnsafeBufferPointer {
            ABICreateSwiftAsyncInvocation(
                interface.handle,
                entry.function,
                entry.contextSize,
                output.address,
                $0.baseAddress,
                nil,
                nil,
                &failure
            )
        }
        guard let invocation else { throw consumeRuntimeCallFailure(failure) }
        defer {
            withExtendedLifetime((descriptor, entry, interface, values, output)) {
                ABIReleaseSwiftAsyncInvocation(invocation)
            }
        }
        await invokeSwiftAsync(invocation)
        #expect(!ABISwiftAsyncInvocationDidThrow(invocation))
        #expect(output.take(Double.self) == 577.5)
    }

    @Test func virtualDispatchFindsTheInheritedSlotAndCurrentImplementation() throws {
        let object = RuntimeDispatchChild()
        let declaration = RuntimeDeclaration(
            name: "ABIBridgeRuntimeTests.RuntimeDispatchBase.value(Swift.Int64) -> Swift.Int64",
            language: .swift
        )
        let dispatch = try RuntimeClassDispatch(
            metadata: RuntimeDispatchChild.self,
            declaration: declaration,
            resolver: CallSymbols.resolver
        )
        let storage = UnsafeRawPointer(bitPattern: dispatch.address)!
        let implementation = try #require(
            try RuntimeImplementation(
                bits: storage.load(as: UInt.self),
                storage: storage,
                authentication: dispatch.authentication,
                retaining: nil
            )
        )
        let word = try RuntimeValueType(scalar: ABIValueInt64)
        let interface = try RuntimeSwiftCallInterface(result: word, parameters: [word])
        var input: Int64 = 40, output: Int64 = 0, failure: OpaquePointer?
        let success = withUnsafeMutablePointer(to: &input) { argument in
            [Optional(UnsafeMutableRawPointer(argument))].withUnsafeBufferPointer {
                ABIUnsafeInvokeSwiftCallInterface(
                    interface.handle,
                    implementation.function,
                    &output,
                    $0.baseAddress,
                    Unmanaged.passUnretained(object).toOpaque(),
                    &failure
                )
            }
        }
        guard success else { throw consumeRuntimeCallFailure(failure) }
        #expect(output == object.value(40))
    }
}
