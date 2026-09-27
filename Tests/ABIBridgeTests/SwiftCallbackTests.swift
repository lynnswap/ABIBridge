#if DEBUG && os(macOS)
@testable import ABIBridge
import ABIBridgeCore
import Foundation
import Synchronization
import Testing

private final class SwiftCallbackTestBox {
    let body: (OpaquePointer) throws -> Void
    let destroyResult: ((UnsafeMutableRawPointer) -> Void)?
    let errors = Mutex<[String]>([])
    init(destroyResult: ((UnsafeMutableRawPointer) -> Void)? = nil, body: @escaping (OpaquePointer) throws -> Void) {
        self.destroyResult = destroyResult; self.body = body
    }
}

private func makeSwiftTestCallback(_ interface: SwiftCallInterface, original: SwiftImplementation,
    box: SwiftCallbackTestBox) throws -> OpaquePointer {
    var functions = ABISwiftCallbackFunctions()
    functions.invoke = { context, call in
        let box = Unmanaged<SwiftCallbackTestBox>.fromOpaque(context!).takeUnretainedValue()
        do { try box.body(call!) } catch { box.errors.withLock { $0.append(String(describing: error)) } }
    }
    functions.releaseContext = { context in Unmanaged<SwiftCallbackTestBox>.fromOpaque(context!).release() }
    functions.destroyResult = { context, result in
        Unmanaged<SwiftCallbackTestBox>.fromOpaque(context!).takeUnretainedValue().destroyResult?(result!)
    }
    let owner = Unmanaged.passRetained(original), context = Unmanaged.passRetained(box)
    var error: OpaquePointer?
    guard let callback = ABICreateSwiftCallback(interface.handle, original.function, functions, context.toOpaque(),
        owner.toOpaque(), { context in Unmanaged<SwiftImplementation>.fromOpaque(context!).release() }, &error) else {
        owner.release(); context.release()
        throw consumeNativeCallFailure(error)
    }
    return callback
}

private func withSwiftVirtualCallback(_ fixture: CompiledSwiftReplacementFixture, method: String,
    result: CValueType, arguments: [CValueType], box: SwiftCallbackTestBox,
    expectedErrors: Int = 0, body: (OpaquePointer) throws -> Void) async throws {
    let type = try await fixture.runtime.swiftType(named: fixture.module + ".ReplacementRenderer", in: fixture.providerScope)
    let declaration = NativeDeclaration(name: type.name + "." + method, language: .swift)
    let entry = try await SwiftClassDispatch(metadata: type.metadata, declaration: declaration, resolver: type.resolver)
    let slot = try #require(UnsafeMutableRawPointer(bitPattern: entry.address))
    let before = slot.load(as: UInt.self)
    let original = try #require(try SwiftImplementation(bits: before, storage: slot, authentication: entry.authentication, retaining: nil))
    let interface = try SwiftCallInterface(result: result, parameters: arguments)
    let callback = try makeSwiftTestCallback(interface, original: original, box: box)
    var canRelease = true
    defer { if canRelease { ABIReleaseSwiftCallback(callback) } }
    var after: UInt = 0
    try #require(ABIEncodePointerSlotFunction(ABISwiftCallbackFunction(callback), slot, entry.authentication.keyCode,
        entry.authentication.discriminator, entry.authentication.addressDiversity, &after))
    let installed = ABICompareExchangePointerSlot(slot, before, after)
    defer {
        if installed.didWrite {
            let restored = ABICompareExchangePointerSlot(slot, after, before)
            if restored.status != ABIPointerSlotComplete { canRelease = false; ABIClearSwiftCallback(callback) }
            #expect(restored.status == ABIPointerSlotComplete)
        }
    }
    try #require(installed.status == ABIPointerSlotComplete && installed.didWrite)
    try body(callback)
    #expect(box.errors.withLock { $0.count } == expectedErrors)
}

private func callbackArgument<T>(_ call: OpaquePointer, _ index: Int, as: T.Type) throws -> T {
    let storage = NativeValueStorage(size: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
    var error: OpaquePointer?
    guard ABISwiftIncomingReadArgument(call, index, storage.address, MemoryLayout<T>.size, &error) else {
        throw consumeNativeCallFailure(error)
    }
    return storage.address.load(as: T.self)
}
private func callbackResult<T>(_ call: OpaquePointer, as: T.Type) throws -> T {
    let storage = NativeValueStorage(size: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
    var error: OpaquePointer?
    guard ABISwiftIncomingCopyResult(call, storage.address, MemoryLayout<T>.size, &error) else {
        throw consumeNativeCallFailure(error)
    }
    return storage.address.load(as: T.self)
}
private func assignCallbackResult<T>(_ call: OpaquePointer, _ value: T) throws {
    let storage = NativeValueStorage(size: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
    storage.initialize(value)
    var error: OpaquePointer?
    guard ABISwiftIncomingSetResult(call, storage.address, MemoryLayout<T>.size, &error) else {
        throw consumeNativeCallFailure(error)
    }
    storage.relinquishValue()
}
private func proceedCallback<T>(_ call: OpaquePointer, _ argument: T) throws {
    let storage = NativeValueStorage(size: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
    storage.initialize(argument)
    let arguments: [UnsafeMutableRawPointer?] = [storage.address]
    var error: OpaquePointer?
    guard arguments.withUnsafeBufferPointer({ ABISwiftIncomingProceed(call, $0.baseAddress, $0.count,
        ABISwiftIncomingContext(call), &error) }) else { throw consumeNativeCallFailure(error) }
}

private final class SwiftCallbackCallHandles: @unchecked Sendable {
    let callback: OpaquePointer
    let interface: SwiftCallInterface
    init(_ callback: OpaquePointer, _ interface: SwiftCallInterface) { self.callback = callback; self.interface = interface }
}

private func invokeTestCallback(_ handles: SwiftCallbackCallHandles, _ input: Int64) throws -> Int64 {
    var input = input, result: Int64 = 0
    var error: OpaquePointer?
    let ok = withUnsafeMutablePointer(to: &input) { pointer in
        let arguments: [UnsafeMutableRawPointer?] = [UnsafeMutableRawPointer(pointer)]
        return arguments.withUnsafeBufferPointer {
            ABIUnsafeInvokeSwiftCallInterface(handles.interface.handle, ABISwiftCallbackFunction(handles.callback), &result,
                $0.baseAddress, nil, &error)
        }
    }
    guard ok else { throw consumeNativeCallFailure(error) }
    return result
}

private func callbackScalarOriginal(_ fixture: CompiledSwiftReplacementFixture) async throws -> SwiftImplementation {
    let symbol = try await fixture.symbol("scalar(Swift.Int64) -> Swift.Int64")
    return try unsafe symbol.withUnsafeAddress { pointer in
        try #require(try SwiftImplementation(bits: UInt(bitPattern: pointer), storage: pointer, authentication: .unsigned, retaining: nil))
    }
}

private enum CallbackTestError: Error { case afterOriginal }
private struct CallbackTestPayload { var a, b, c, d, e: Int64 }

@Suite(.serialized)
struct SwiftCallbackTests {
    @Test func compiledCallerReceivesEditedArgumentsAndResultsAndCanInvalidate() async throws {
        let fixture = try CompiledSwiftReplacementFixture(writable: false); defer { fixture.cleanup() }
        let name = fixture.module + ".ReplacementRenderer"
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeRenderer() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        let object = try unsafe make.unsafeInvoke()
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".classScalar(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self, in: fixture.callerScope)
        let integer = try CValueType(scalar: ABIValueInt64)
        let box = SwiftCallbackTestBox { call in
            #expect(ABISwiftIncomingArgumentCount(call) == 1)
            let receiver = Unmanaged<AnyObject>.fromOpaque(ABISwiftIncomingContext(call)!).takeUnretainedValue()
            #expect(ObjectIdentifier(receiver) == ObjectIdentifier(object))
            let value = try callbackArgument(call, 0, as: Int64.self)
            try proceedCallback(call, value + 1)
            let original = try callbackResult(call, as: Int64.self)
            try assignCallbackResult(call, original + 10)
        }
        try await withSwiftVirtualCallback(fixture, method: "scalar(Swift.Int64) -> Swift.Int64", result: integer, arguments: [integer], box: box) { (callback: OpaquePointer) throws -> Void in
            #expect(try unsafe oracle.unsafeInvoke(object, 40) == 53)
            ABIClearSwiftCallback(callback)
            #expect(try unsafe oracle.unsafeInvoke(object, 40) == 42)
        }
        #expect(try unsafe oracle.unsafeInvoke(object, 40) == 42)
    }

    @Test func ownedStringResultsAreCopiedDestroyedAndTransferred() async throws {
        let fixture = try CompiledSwiftReplacementFixture(writable: false); defer { fixture.cleanup() }
        let name = fixture.module + ".ReplacementRenderer"
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeRenderer() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        let object = try unsafe make.unsafeInvoke()
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".classText(\(name), Swift.String) -> Swift.String",
            as: ((AnyObject, String) -> String).self, in: fixture.callerScope)
        let string = try SwiftValueCodec<String>().type
        let destructions = Mutex(0)
        let box = SwiftCallbackTestBox(destroyResult: { pointer in
            pointer.assumingMemoryBound(to: String.self).deinitialize(count: 1)
            destructions.withLock { $0 += 1 }
        }) { call in
            let value = try callbackArgument(call, 0, as: String.self)
            try proceedCallback(call, value + "-first")
            try proceedCallback(call, value + "-second")
            let original = try callbackResult(call, as: String.self)
            try assignCallbackResult(call, "discarded:" + original)
            try assignCallbackResult(call, "callback:" + original)
        }
        let input = String(repeating: "owned argument", count: 100)
        try await withSwiftVirtualCallback(fixture, method: "text(Swift.String) -> Swift.String", result: string, arguments: [string], box: box) { (_: OpaquePointer) throws -> Void in
            for _ in 0..<20 {
                #expect(try unsafe oracle.unsafeInvoke(object, input) == "callback:method:" + input + "-second")
            }
        }
        #expect(destructions.withLock { $0 } == 60)
        #expect(try unsafe oracle.unsafeInvoke(object, input) == "method:" + input)
    }

    @Test func failureAfterProceedUsesTheLatestCompletedResult() async throws {
        let fixture = try CompiledSwiftReplacementFixture(writable: false); defer { fixture.cleanup() }
        let name = fixture.module + ".ReplacementRenderer"
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeRenderer() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        let object = try unsafe make.unsafeInvoke()
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".classScalar(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self, in: fixture.callerScope)
        let integer = try CValueType(scalar: ABIValueInt64)
        let box = SwiftCallbackTestBox { call in
            let value = try callbackArgument(call, 0, as: Int64.self)
            try proceedCallback(call, value + 20)
            throw CallbackTestError.afterOriginal
        }
        try await withSwiftVirtualCallback(fixture, method: "scalar(Swift.Int64) -> Swift.Int64", result: integer, arguments: [integer], box: box, expectedErrors: 1) { (_: OpaquePointer) throws -> Void in
            #expect(try unsafe oracle.unsafeInvoke(object, 40) == 62)
        }
    }
    @Test func compilerAllocatedIndirectResultStorageReceivesTheCallbackValue() async throws {
        let fixture = try CompiledSwiftReplacementFixture(writable: false); defer { fixture.cleanup() }
        let name = fixture.module + ".ReplacementRenderer"
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeRenderer() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        let object = try unsafe make.unsafeInvoke()
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".classPayload(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self, in: fixture.callerScope)
        let integer = try CValueType(scalar: ABIValueInt64)
        let payload = try CValueType(fields: Array(repeating: integer, count: 5))
        let box = SwiftCallbackTestBox { call in
            let value = try callbackArgument(call, 0, as: Int64.self)
            try proceedCallback(call, value + 1)
            var result = try callbackResult(call, as: CallbackTestPayload.self)
            result.a += 1000
            try assignCallbackResult(call, result)
        }
        try await withSwiftVirtualCallback(fixture, method: "payload(Swift.Int64) -> " + fixture.module + ".ReplacementPayload",
            result: payload, arguments: [integer], box: box) { (_: OpaquePointer) throws -> Void in
            #expect(try unsafe oracle.unsafeInvoke(object, 40) == 1225)
        }
    }

    @Test func invalidationReleasesCapturesAfterConcurrentEntryFinishes() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let original = try await callbackScalarOriginal(fixture)
        let integer = try CValueType(scalar: ABIValueInt64)
        let interface = try SwiftCallInterface(result: integer, parameters: [integer])
        @Sendable func exercise() throws {
            let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let outcome = Mutex<(Int64?, String?)>((nil, nil))
            weak var weakBox: SwiftCallbackTestBox?
            func create() throws -> OpaquePointer {
                let box = SwiftCallbackTestBox { call in
                    entered.signal()
                    guard resume.wait(timeout: .now() + 10) == .success else { throw CallbackTestError.afterOriginal }
                    try proceedCallback(call, Int64(50))
                    let result = try callbackResult(call, as: Int64.self)
                    try assignCallbackResult(call, result + 10)
                }
                weakBox = box
                return try makeSwiftTestCallback(interface, original: original, box: box)
            }
            let callback = try create()
            let handles = SwiftCallbackCallHandles(callback, interface)
            var finished = false
            defer {
                resume.signal()
                if !finished { finished = done.wait(timeout: .now() + 10) == .success }
                if finished { ABIReleaseSwiftCallback(callback) }
                else { ABIClearSwiftCallback(callback); Issue.record("Callback still entered; retained code to preserve its lifetime.") }
            }
            DispatchQueue.global().async {
                do { let value = try invokeTestCallback(handles, 40); outcome.withLock { $0 = (value, nil) } }
                catch { outcome.withLock { $0 = (nil, String(describing: error)) } }
                done.signal()
            }
            try #require(entered.wait(timeout: .now() + 10) == .success)
            ABIClearSwiftCallback(callback)
            #expect(weakBox != nil)
            // A new entry bypasses the blocked, already-entered handler.
            #expect(try invokeTestCallback(handles, 40) == 41)
            resume.signal()
            finished = done.wait(timeout: .now() + 10) == .success
            try #require(finished)
            #expect(outcome.withLock { $0.0 } == 61)
            #expect(outcome.withLock { $0.1 } == nil)
            #expect(weakBox == nil)
            #expect(try invokeTestCallback(handles, 40) == 41)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                do { try exercise(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    @Test func precompiledPagesExpandAndUnpublishedEntriesCanBeReused() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let original = try await callbackScalarOriginal(fixture)
        let integer = try CValueType(scalar: ABIValueInt64)
        let interface = try SwiftCallInterface(result: integer, parameters: [integer])
        for _ in 0..<2 {
            var callbacks: [OpaquePointer] = []
            defer { for callback in callbacks { ABIReleaseSwiftCallback(callback) } }
            for index in 0..<520 {
                let box = SwiftCallbackTestBox { call in try assignCallbackResult(call, Int64(index)) }
                callbacks.append(try makeSwiftTestCallback(interface, original: original, box: box))
            }
            for (index, callback) in callbacks.enumerated() {
                #expect(try invokeTestCallback(SwiftCallbackCallHandles(callback, interface), 40) == Int64(index))
            }
        }
    }

}
#endif
