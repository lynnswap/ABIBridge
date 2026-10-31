import ABIBridgeCore
import ABIBridgeCore.Backend
import ABIBridgeRuntime
import ManagedSwiftAdapters
import Synchronization
import Testing

@inline(never) public func runtimeCallbackOriginal(_ value: Int64) -> Int64 { value + 1 }

public protocol RuntimeCallbackDelegate: AnyObject {
    func receive(_ value: Int64)
}

public protocol RuntimeCallbackValueDelegate {
    func receive(_ value: Int64)
}

public protocol RuntimeCallbackPropertyDelegate: AnyObject {
    var value: Int64 { get }
}

public protocol RuntimeRegisteredDelegate: AnyObject {
    func receive(_ value: Int64)
}

public final class RuntimeCallbackDelegateFixture: RuntimeCallbackDelegate,
    RuntimeCallbackValueDelegate, RuntimeCallbackPropertyDelegate, RuntimeRegisteredDelegate
{
    public var value: Int64 { 0 }
    public func receive(_ value: Int64) {}
}

private final class CallbackValue {
    let value: Int64
    var invocationCount = 0
    init(_ value: Int64) { self.value = value }
}

private final class ClosureContext {
    let entry: RuntimeSwiftClosureCallbackOwner
    let bias: Int64
    init(entry: RuntimeSwiftClosureCallbackOwner, bias: Int64) {
        self.entry = entry; self.bias = bias
    }
}

struct RuntimeCallbackTests {
    @Test func protocolDescriptorsRejectUnsupportedRequirementShapes() throws {
        let symbol = try CallSymbols.resolve(
            "protocol descriptor for ABIBridgeRuntimeTests.RuntimeCallbackDelegate",
            kind: .data
        )
        let descriptor = try RuntimeSwiftProtocolDescriptor(
            symbol: symbol,
            resolver: CallSymbols.resolver
        )
        #expect(descriptor.requirements.count == 1)
        #expect(descriptor.requirements.first?.slot == 1)
        #expect(descriptor.requirements.first?.name.contains("receive") == true)

        for name in ["RuntimeCallbackValueDelegate", "RuntimeCallbackPropertyDelegate"] {
            let symbol = try CallSymbols.resolve(
                "protocol descriptor for ABIBridgeRuntimeTests." + name,
                kind: .data
            )
            do {
                _ = try RuntimeSwiftProtocolDescriptor(
                    symbol: symbol,
                    resolver: CallSymbols.resolver
                )
                Issue.record("An unsupported protocol shape was accepted: \(name)")
            } catch RuntimeResolutionError.unsupportedDeclaration {
            }
        }
    }

    @Test func incompleteProtocolConformanceFailsBeforeRegistration() throws {
        let symbol = try CallSymbols.resolve(
            "protocol descriptor for ABIBridgeRuntimeTests.RuntimeCallbackDelegate",
            kind: .data
        )
        let descriptor = try RuntimeSwiftProtocolDescriptor.cached(
            symbol: symbol,
            resolver: CallSymbols.resolver
        )
        let type = try RuntimeSwiftProtocolClass.prepare(descriptor: descriptor)
        #expect(throws: RuntimeResolutionError.self) {
            try type.register(interfaces: [], retaining: [])
        }
        let metadata = unsafeBitCast(type.metadata, to: UnsafeRawPointer.self)
        #expect(unsafe symbol.withUnsafeAddress { ABISwiftConformance(metadata, $0) } == nil)
    }

    @Test func protocolWitnessPreparationRequiresVoidAndAcceptsNativeErrors() throws {
        let word = try RuntimeValueType(scalar: ABIValueInt64)
        let invalid = try RuntimeSwiftCallInterface(result: word, parameters: [word])
        let valid = try RuntimeSwiftCallInterface(
            result: RuntimeValueType(scalar: ABIValueVoid),
            parameters: [word]
        )
        var failure: OpaquePointer?
        let rejected = ABICreateSwiftProtocolWitnessCallback(
            invalid.handle,
            0,
            &failure
        )
        #expect(rejected == nil)
        let error = try #require(failure)
        #expect(ABIResolutionFailureGetCode(error) == ABIFailureUnsupportedDeclaration)
        ABIReleaseResolutionFailure(error)
        guard
            let callback = ABICreateSwiftProtocolWitnessCallback(
                valid.handle,
                0,
                &failure
            )
        else {
            throw consumeRuntimeCallFailure(failure)
        }
        ABIReleaseSwiftClosureCallback(callback)

        let throwing = try RuntimeSwiftCallInterface(
            result: RuntimeValueType(scalar: ABIValueVoid),
            parameters: [word],
            errorPlan: RuntimeErrorConvention(
                type: RuntimeValueType(scalar: ABIValuePointer),
                isTyped: false
            )
        )
        let throwingCallback = try #require(
            ABICreateSwiftProtocolWitnessCallback(
                throwing.handle,
                0,
                &failure
            )
        )
        ABIReleaseSwiftClosureCallback(throwingCallback)
    }

    @Test func runtimeRegistrationReusesPhysicalABIWithoutRetainingInstanceCaptures() throws {
        let symbol = try CallSymbols.resolve(
            "protocol descriptor for ABIBridgeRuntimeTests.RuntimeRegisteredDelegate",
            kind: .data
        )
        let descriptor = try RuntimeSwiftProtocolDescriptor.cached(
            symbol: symbol,
            resolver: CallSymbols.resolver
        )
        let type = try RuntimeSwiftProtocolClass.prepare(descriptor: descriptor)
        #expect(try RuntimeSwiftProtocolClass.prepare(descriptor: descriptor) === type)
        let word = try RuntimeValueType(scalar: ABIValueInt64)
        let interface = try RuntimeSwiftCallInterface(
            result: RuntimeValueType(scalar: ABIValueVoid),
            parameters: [word]
        )
        let registered = try type.register(interfaces: [interface], retaining: [symbol.image])
        let sameABI = try RuntimeSwiftCallInterface(
            result: RuntimeValueType(scalar: ABIValueVoid),
            parameters: [RuntimeValueType(scalar: ABIValueInt64)]
        )
        #expect(try type.register(interfaces: [sameABI], retaining: []) === registered)
        let differentABI = try RuntimeSwiftCallInterface(
            result: RuntimeValueType(scalar: ABIValueVoid),
            parameters: [word, word]
        )
        #expect(throws: RuntimeResolutionError.self) {
            try type.register(interfaces: [differentABI], retaining: [])
        }
        weak var observed: CallbackValue?
        do {
            let owner = CallbackValue(42)
            observed = owner
            let context = Unmanaged.passRetained(owner)
            var failure: OpaquePointer?
            guard
                let object = ABICreateSwiftProtocolInstance(
                    registered.handle,
                    context.toOpaque(),
                    { context, slot, arguments, _, _ in
                        let owner = Unmanaged<CallbackValue>.fromOpaque(context!)
                            .takeUnretainedValue()
                        #expect(slot == 0)
                        #expect(arguments![0]!.load(as: Int64.self) == owner.value)
                        owner.invocationCount += 1
                        return false
                    },
                    { Unmanaged<CallbackValue>.fromOpaque($0!).release() },
                    &failure
                )
            else {
                context.release()
                throw consumeRuntimeCallFailure(failure)
            }
            let retained = Unmanaged<AnyObject>.fromOpaque(object).takeRetainedValue()
            let delegate = try #require(retained as? any RuntimeRegisteredDelegate)
            delegate.receive(42)
            #expect(owner.invocationCount == 1)
        }
        #expect(observed == nil)
    }

    @Test func precompiledPagesExpandAndUnpublishedEntriesCanBeReused() throws {
        let symbol = try CallSymbols.resolve(
            "ABIBridgeRuntimeTests.runtimeCallbackOriginal(Swift.Int64) -> Swift.Int64"
        )
        let word = try RuntimeValueType(scalar: ABIValueInt64)
        let interface = try RuntimeSwiftCallInterface(result: word, parameters: [word])
        let implementation = try unsafe symbol.withUnsafeAddress {
            try RuntimeImplementation(function: ABIUnsafeFunctionAtAddress($0)!, retaining: nil)
        }
        var functions = ABISwiftCallbackFunctions()
        functions.invoke = { context, call in
            var value = Unmanaged<CallbackValue>.fromOpaque(context!).takeUnretainedValue().value
            var failure: OpaquePointer?
            let success = ABISwiftIncomingSetResult(
                call,
                &value,
                MemoryLayout<Int64>.size,
                &failure
            )
            #expect(success)
            if let failure { ABIReleaseResolutionFailure(failure) }
        }
        functions.releaseContext = { context in
            Unmanaged<CallbackValue>.fromOpaque(context!).release()
        }
        for _ in 0..<2 {
            var callbacks: [OpaquePointer] = []
            defer { for callback in callbacks { ABIReleaseSwiftCallback(callback) } }
            // One precompiled entry page has 512 slots. Cross that boundary,
            // then repeat after release to exercise reuse as well as expansion.
            for index in 0..<520 {
                let context = Unmanaged.passRetained(CallbackValue(Int64(index)))
                var failure: OpaquePointer?
                guard
                    let callback = ABICreateSwiftCallback(
                        interface.handle,
                        implementation.function,
                        functions,
                        context.toOpaque(),
                        nil,
                        nil,
                        &failure
                    )
                else {
                    context.release()
                    throw consumeRuntimeCallFailure(failure)
                }
                callbacks.append(callback)
            }
            for (index, callback) in callbacks.enumerated() {
                var input: Int64 = 40, result: Int64 = 0, failure: OpaquePointer?
                let success = withUnsafeMutablePointer(to: &input) { pointer in
                    [Optional(UnsafeMutableRawPointer(pointer))].withUnsafeBufferPointer {
                        ABIUnsafeInvokeSwiftCallInterface(
                            interface.handle,
                            ABISwiftCallbackFunction(callback),
                            &result,
                            $0.baseAddress,
                            nil,
                            &failure
                        )
                    }
                }
                guard success else { throw consumeRuntimeCallFailure(failure) }
                #expect(result == Int64(index))
            }
            withExtendedLifetime(implementation) {}
        }
    }

    @Test func nativeClosureRetainsItsEntryAfterCacheEviction() throws {
        weak var observed: ClosureContext?
        let callback: UnsafeMutableRawPointer
        do {
            // UnsafeRawPointer.load(as: IntegerClosure.self) in the compiler
            // fixture loads a stored function value with indirect arguments
            // and result, then reabstracts it to the concrete call convention.
            let word = try RuntimeValueType(
                indirectSwiftSize: MemoryLayout<Int64>.size,
                alignment: MemoryLayout<Int64>.alignment
            )
            let interface = try RuntimeSwiftCallInterface.cached(result: word, parameters: [word])
            var functions = ABISwiftThrowingClosureCallbackFunctions()
            functions.usesNativeContext = true
            functions.invoke = { context, arguments, result, _ in
                let box = Unmanaged<ClosureContext>.fromOpaque(context!).takeUnretainedValue()
                let input = arguments![0]!.load(as: Int64.self)
                result!.storeBytes(of: input + box.bias, as: Int64.self)
                return false
            }
            let entry = try interface.closureEntry(functions: functions)
            #expect(try interface.closureEntry(functions: functions) === entry)
            let box = ClosureContext(entry: entry, bias: 2)
            observed = box
            let discriminator = swiftClosureDiscriminator(
                parameters: ["-indirect"],
                result: "-indirect"
            )
            #expect(discriminator == 55683)
            var value = ABISwiftClosureValue(
                function: ABISignSwiftClosureFunction(entry.function, discriminator),
                context: Unmanaged.passUnretained(box).toOpaque()
            )
            callback = withUnsafePointer(to: &value) { integerClosureRetain(UnsafeRawPointer($0)) }
        }
        for size in 1...80 {
            _ = try RuntimeSwiftCallInterface.cached(
                result: RuntimeValueType(indirectSwiftSize: size, alignment: 1),
                parameters: []
            )
        }
        let actual = integerClosureCallRetained(callback, 40)
        #expect(actual == 42)
        #expect(observed != nil)
        integerClosureRelease(callback)
        #expect(observed == nil)
    }
}
