import ABIBridgeCore
import ABIBridgeRuntime
import ManagedSwiftAdapters
import Synchronization
import Testing

@inline(never) public func runtimeCallbackOriginal(_ value: Int64) -> Int64 { value + 1 }

private final class CallbackValue {
    let value: Int64
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
