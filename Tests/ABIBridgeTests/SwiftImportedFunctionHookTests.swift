#if os(macOS) && DEBUG
@testable import ABIBridge
import ABIBridgeCore
import Darwin
import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct SwiftImportedFunctionHookTests {

    @Test func noncopyableHookInputsReserveRecoveryOwnership() async throws {
        let fixture = try CompiledSwiftReplacementFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime
        let type = try await runtime.swiftType(named: fixture.module + ".HookTicket", in: fixture.providerScope)
        let consume = try await runtime.swiftFunction(named: fixture.module + ".consumeHookTicket(_:)",
            as: ((NativeSwiftConsuming<NativeSwiftValue>) -> Int64).self, genericArguments: [.type(type)], in: fixture.providerScope)
        let read = try await type.method(named: "read()", as: (() -> Int64).self, receiverABI: .int64)
        let caller = try await runtime.swiftFunction(named: fixture.callerModule + ".callConsumeTicket(_:)",
            as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let counts = try await runtime.swiftFunction(named: fixture.module + ".hookTicketCounts()",
            as: (() -> (Int64, Int64)).self, in: fixture.providerScope)
        let saved = SavedRuntimeHookValues()
        let failures = Mutex(0)
        let hook = try unsafe await consume.hookImportedCalls(in: fixture.callerScope, using: runtime,
            onFailure: { _ in failures.withLock { $0 += 1 } }) { call, incoming in
                saved.input = incoming.value
                #expect(try unsafe read.unsafeInvoke(on: incoming.value) == 42)
                #expect(throws: NativeSwiftValueError.valueInUse) {
                    try unsafe consume.unsafeInvoke(incoming)
                }
                #expect(!incoming.value.isConsumed)
                return try call.proceed(incoming) + 10
            }
        #expect(try unsafe caller.unsafeInvoke(42) == 52)
        #expect(saved.input!.isConsumed)
        #expect(try unsafe counts.unsafeInvoke() == (1, 1))
        hook.invalidate()
        let fallback = try unsafe await consume.hookImportedCalls(in: fixture.callerScope, using: runtime,
            onFailure: { _ in failures.withLock { $0 += 1 } }) { _, incoming in
                saved.input = incoming.value
                throw RuntimeHookBodyFailure()
            }
        defer { fallback.invalidate() }
        #expect(try unsafe caller.unsafeInvoke(43) == 43)
        #expect(saved.input!.isConsumed)
        #expect(try unsafe counts.unsafeInvoke() == (2, 2))
        #expect(failures.withLock { $0 } == 1)
        fallback.invalidate()
        let retained = try unsafe await consume.hookImportedCalls(in: fixture.callerScope, using: runtime,
            onFailure: { Issue.record($0) }) { call, incoming in
                saved.input = incoming.value
                saved.runtimeContinuation = call
                return 100
            }
        #expect(try unsafe caller.unsafeInvoke(44) == 100)
        #expect(!saved.input!.isConsumed)
        #expect(throws: NativeSwiftHookInvocationError.expiredInvocation) {
            try saved.runtimeContinuation!.proceed(NativeSwiftConsuming(saved.input!))
        }
        #expect(try unsafe consume.unsafeInvoke(NativeSwiftConsuming(saved.input!)) == 44)
        #expect(try unsafe counts.unsafeInvoke() == (3, 3))
        retained.invalidate()
    }

    @Test func noncopyableHookResultsSharePublicationAndRecoveryOwnership() async throws {
        let fixture = try CompiledSwiftReplacementFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime
        let type = try await runtime.swiftType(named: fixture.module + ".HookTicket", in: fixture.providerScope)
        let move = try await runtime.swiftFunction(named: fixture.module + ".moveHookTicket(_:)",
            as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self, genericArguments: [.type(type)], in: fixture.providerScope)
        let consume = try await runtime.swiftFunction(named: fixture.module + ".consumeHookTicket(_:)",
            as: ((NativeSwiftConsuming<NativeSwiftValue>) -> Int64).self, genericArguments: [.type(type)], in: fixture.providerScope)
        let caller = try await runtime.swiftFunction(named: fixture.callerModule + ".callMoveTicket(_:)",
            as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let counts = try await runtime.swiftFunction(named: fixture.module + ".hookTicketCounts()",
            as: (() -> (Int64, Int64)).self, in: fixture.providerScope)
        let saved = SavedRuntimeHookValues()
        let failures = Mutex(0)
        let hook = try unsafe await move.hookImportedCalls(in: fixture.callerScope, using: runtime,
            onFailure: { _ in failures.withLock { $0 += 1 } }) { call, incoming in
                saved.input = incoming.value
                let result = try call.proceed(incoming)
                saved.output = result
                #expect(incoming.value.isConsumed)
                #expect(throws: NativeSwiftValueError.valueInUse) {
                    try unsafe consume.unsafeInvoke(NativeSwiftConsuming(result))
                }
                return result
            }
        let outer = try unsafe await move.hookImportedCalls(in: fixture.callerScope, using: runtime,
            onFailure: { Issue.record($0) }) { call, incoming in
                let read = try incoming.value.withBorrowedValue { view in
                    #expect(!incoming.value.isConsumed)
                    return view.type.name
                }
                #expect(read == type.name)
                return try call.proceed(incoming)
            }
        #expect(try unsafe caller.unsafeInvoke(42) == 42)
        #expect(saved.input!.isConsumed && saved.output!.isConsumed)
        #expect(try unsafe counts.unsafeInvoke() == (1, 1))
        outer.invalidate()
        hook.invalidate()
        let fallback = try unsafe await move.hookImportedCalls(in: fixture.callerScope, using: runtime,
            onFailure: { _ in failures.withLock { $0 += 1 } }) { call, incoming in
                saved.output = try call.proceed(incoming)
                throw RuntimeHookBodyFailure()
            }
        defer { fallback.invalidate() }
        #expect(try unsafe caller.unsafeInvoke(43) == 43)
        #expect(saved.output!.isConsumed)
        #expect(try unsafe counts.unsafeInvoke() == (2, 2))
        #expect(failures.withLock { $0 } == 1)
    }

    @Test func virtualHooksTransferTheSameNoncopyableRuntimeOwner() async throws {
        let fixture = try CompiledSwiftReplacementFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime
        let valueType = try await runtime.swiftType(named: fixture.module + ".HookTicket", in: fixture.providerScope)
        let type = try await runtime.swiftType(named: fixture.module + ".HookTicketRenderer", in: fixture.providerScope)
        let move = try await type.method(named: "move(_:)",
            as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self, genericArguments: [.type(valueType)])
        let caller = try await runtime.swiftFunction(named: fixture.callerModule + ".callVirtualMoveTicket(_:)",
            as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let counts = try await runtime.swiftFunction(named: fixture.module + ".hookTicketCounts()",
            as: (() -> (Int64, Int64)).self, in: fixture.providerScope)
        let saved = SavedRuntimeHookValues()
        let hook = try unsafe await move.hookVirtualCalls(onFailure: { Issue.record($0) }) { call, value in
            _ = try call.receiver(as: AnyObject.self)
            saved.input = value.value
            let result = try call.proceed(value)
            saved.output = result
            return result
        }
        defer { hook.invalidate() }
        #expect(try unsafe caller.unsafeInvoke(42) == 42)
        #expect(saved.input!.isConsumed && saved.output!.isConsumed)
        #expect(try unsafe counts.unsafeInvoke() == (1, 1))
    }

    @MainActor @Test func asyncHooksComposeRuntimeOwnershipAcrossSuspension() async throws {
        let fixture = try CompiledSwiftReplacementFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime
        let type = try await runtime.swiftType(named: fixture.module + ".HookTicket", in: fixture.providerScope)
        let move = try await runtime.swiftFunction(named: fixture.module + ".moveAsyncHookTicket(_:)",
            as: (@concurrent (NativeSwiftConsuming<NativeSwiftValue>) async -> NativeSwiftValue).self,
            genericArguments: [.type(type)], in: fixture.providerScope)
        let caller = try await runtime.swiftFunction(named: fixture.callerModule + ".callAsyncMoveTicket(_:)",
            as: (@concurrent (Int64) async -> Int64).self, in: fixture.callerScope)
        let counts = try await runtime.swiftFunction(named: fixture.module + ".hookTicketCounts()",
            as: (() -> (Int64, Int64)).self, in: fixture.providerScope)
        let saved = SavedRuntimeHookValues()
        let failures = Mutex(0)
        let hook = try unsafe await move.hookImportedCalls(in: fixture.callerScope, using: runtime,
            onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value in
                saved.input = value.value
                await Task.yield()
                saved.output = try await call.proceed(value)
                #expect(value.value.isConsumed)
                await Task.yield()
                throw RuntimeHookBodyFailure()
            }
        defer { hook.invalidate() }
        #expect(try unsafe await caller.unsafeInvoke(42) == 42)
        #expect(saved.input!.isConsumed && saved.output!.isConsumed)
        #expect(try unsafe counts.unsafeInvoke() == (1, 1))
        #expect(failures.withLock { $0 } == 1)
    }

    @Test func untypedErrorsDoNotReserveNoncopyableRecoveryInputs() async throws {
        let fixture = try CompiledSwiftReplacementFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime
        let type = try await runtime.swiftType(named: fixture.module + ".HookTicket", in: fixture.providerScope)
        let target = try await runtime.swiftFunction(named: fixture.module + ".consumeAnyErrorHookTicket(_:)",
            as: ((NativeSwiftConsuming<NativeSwiftValue>) throws -> Int64).self,
            genericArguments: [.type(type)], in: fixture.providerScope)
        let consume = try await runtime.swiftFunction(named: fixture.module + ".consumeHookTicket(_:)",
            as: ((NativeSwiftConsuming<NativeSwiftValue>) -> Int64).self,
            genericArguments: [.type(type)], in: fixture.providerScope)
        let caller = try await runtime.swiftFunction(named: fixture.callerModule + ".callConsumeAnyErrorTicket(_:)",
            as: ((Int64) throws -> Int64).self, in: fixture.callerScope)
        let counts = try await runtime.swiftFunction(named: fixture.module + ".hookTicketCounts()",
            as: (() -> (Int64, Int64)).self, in: fixture.providerScope)
        let saved = SavedRuntimeHookValues()
        let hook = try unsafe await target.hookImportedCalls(in: fixture.callerScope, using: runtime,
            onFailure: { Issue.record($0) }) { _, incoming in
                saved.input = incoming.value
                #expect(try unsafe consume.unsafeInvoke(incoming) == 42)
                throw RuntimeHookBodyFailure()
            }
        defer { hook.invalidate() }
        do {
            _ = try unsafe caller.unsafeInvoke(42)
            Issue.record("Expected the native untyped error channel")
        } catch let error as NativeSwiftError {
            error.withUnderlyingError { #expect($0 is RuntimeHookBodyFailure) }
        }
        #expect(saved.input!.isConsumed)
        #expect(try unsafe counts.unsafeInvoke() == (1, 1))
    }

    @Test func consumingContinuationCopiesReleaseTheirOriginalStorage() async throws {
        let fixture = try CompiledSwiftReplacementFixture()
        defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".consumeHookObject(_:)",
            as: ((NativeSwiftConsuming<NSObject>) -> Int64).self, in: fixture.providerScope)
        let caller = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".callConsumeHookObject(_:)",
            as: ((NativeSwiftConsuming<NSObject>) -> Int64).self, in: fixture.callerScope)
        let hook = try unsafe await target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in try call.proceed(value) }
        defer { hook.invalidate() }
        weak var observed: NSObject?
        do {
            let object = NSObject()
            observed = object
            #expect(try unsafe caller.unsafeInvoke(NativeSwiftConsuming(object)) == 42)
        }
        #expect(observed == nil)
    }

    @Test func optionalPointerAdaptersUseTheSharedHookCodec() async throws {
        let fixture = try CompiledSwiftReplacementFixture()
        defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookOptionalPointer(Swift.UnsafeMutableRawPointer?) -> Swift.UnsafeMutableRawPointer?",
            as: ((OptionalHookPointer?) -> OptionalHookPointer?).self, in: fixture.providerScope)
        let caller = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".callOptionalHookPointer(_:)",
            as: ((UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?).self, in: fixture.callerScope)
        let hook = try unsafe await target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                if let value { #expect(value.marker == 42) }
                return try call.proceed(value)
            }
        defer { hook.invalidate() }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { pointer.deallocate() }
        #expect(try unsafe caller.unsafeInvoke(nil) == nil)
        #expect(try unsafe caller.unsafeInvoke(pointer) == pointer)
    }

    @Test func forwardingTransfersOwnershipToAChildHookThatKeepsTheValue() async throws {
        let fixture = try CompiledSwiftReplacementFixture()
        defer { fixture.cleanup() }
        let type = try await fixture.runtime.swiftType(named: fixture.module + ".HookTicket", in: fixture.providerScope)
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".consumeHookTicket(_:)",
            as: ((NativeSwiftConsuming<NativeSwiftValue>) -> Int64).self, genericArguments: [.type(type)], in: fixture.providerScope)
        let caller = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".callConsumeTicket(_:)",
            as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let saved = SavedRuntimeHookValues()
        let child = try unsafe await target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { _, value in saved.output = value.value; return 100 }
        defer { child.invalidate() }
        let parent = try unsafe await target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                saved.input = value.value
                return try call.proceed(value)
            }
        defer { parent.invalidate() }
        #expect(try unsafe caller.unsafeInvoke(42) == 100)
        #expect(saved.input!.isConsumed && !saved.output!.isConsumed)
        #expect(try unsafe target.unsafeInvoke(NativeSwiftConsuming(saved.output!)) == 42)
        #expect(saved.output!.isConsumed)
    }

    @Test func borrowedPointerAdaptersUseTheSharedHookCodec() async throws {
        let fixture = try CompiledSwiftReplacementFixture()
        defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookBorrowedPointer(Swift.UnsafeMutableRawPointer?) -> Swift.UnsafeMutableRawPointer?",
            as: ((NativeSwiftBorrowing<OptionalHookPointer?>) -> OptionalHookPointer?).self, in: fixture.providerScope)
        let caller = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".callBorrowedHookPointer(_:)",
            as: ((UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?).self, in: fixture.callerScope)
        let hook = try unsafe await target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                if let value = value.value { #expect(value.marker == 42) }
                return try call.proceed(value)
            }
        defer { hook.invalidate() }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { pointer.deallocate() }
        #expect(try unsafe caller.unsafeInvoke(nil) == nil)
        #expect(try unsafe caller.unsafeInvoke(pointer) == pointer)
    }

    @MainActor @Test func writebackFailurePreservesNoncopyableRecoveryResults() async throws {
        let fixture = try CompiledSwiftReplacementFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime
        let type = try await runtime.swiftType(named: fixture.module + ".HookTicket", in: fixture.providerScope)
        typealias Body = NativeSwiftClosure<() -> Int64>
        let target = try await runtime.swiftFunction(named: fixture.module + ".moveHookTicketWithBody(_:_:_:)",
            as: ((NativeSwiftConsuming<NativeSwiftValue>, NativeSwiftInout<Body>, Body) -> NativeSwiftValue).self,
            genericArguments: [.type(type)], in: fixture.providerScope)
        let caller = try await runtime.swiftFunction(named: fixture.callerModule + ".callMoveTicketWithBody(_:)",
            as: ((Int64) -> (Int64, Int64)).self, in: fixture.callerScope)
        let saved = SavedRuntimeHookValues()
        let failures = Mutex(0)
        let hook = try unsafe await target.hookImportedCalls(in: fixture.callerScope, using: runtime,
            onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value, body, borrowed in
                let result = try call.proceed(value, body, borrowed)
                saved.output = result
                body.value = borrowed
                return result
            }
        #expect(try unsafe caller.unsafeInvoke(42) == (42, 42))
        #expect(saved.output!.isConsumed && failures.withLock { $0 } == 1)
        hook.invalidate()
        let asyncTarget = try await runtime.swiftFunction(named: fixture.module + ".moveAsyncHookTicketWithBody(_:_:_:)",
            as: (@concurrent (NativeSwiftConsuming<NativeSwiftValue>, NativeSwiftInout<Body>, Body) async -> NativeSwiftValue).self,
            genericArguments: [.type(type)], in: fixture.providerScope)
        let asyncCaller = try await runtime.swiftFunction(named: fixture.callerModule + ".callAsyncMoveTicketWithBody(_:)",
            as: (@concurrent (Int64) async -> (Int64, Int64)).self, in: fixture.callerScope)
        let asyncHook = try unsafe await asyncTarget.hookImportedCalls(in: fixture.callerScope, using: runtime,
            onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value, body, borrowed in
                let result = try await call.proceed(value, body, borrowed)
                saved.output = result
                body.value = borrowed
                return result
            }
        defer { asyncHook.invalidate() }
        #expect(try unsafe await asyncCaller.unsafeInvoke(42) == (42, 42))
        #expect(saved.output!.isConsumed && failures.withLock { $0 } == 2)
        let counts = try await runtime.swiftFunction(named: fixture.module + ".hookTicketCounts()",
            as: (() -> (Int64, Int64)).self, in: fixture.providerScope)
        #expect(try unsafe counts.unsafeInvoke() == (2, 2))
    }

    @Test func runtimeValuesNestedClosuresAndInoutComposeThroughHooks() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) public func runtimeHookEcho<Value>(_ value: Value) -> Value { value }
        @inline(never) public func runtimeHookTuple(_ value: (Int64, () -> String)) -> (Int64, () -> String) { value }
        @inline(never) public func runtimeHookEdit(_ value: inout String, _ suffix: consuming String) { value += suffix }
        """, callerExtra: """
        @inline(never) public func runtimeHookInteger(_ value: Int64) -> Int64 { runtimeHookEcho(value) }
        @inline(never) public func runtimeHookNested(_ value: Int64, _ text: String) -> (Int64, String) {
            let result = runtimeHookTuple((value, { text }))
            return (result.0, result.1())
        }
        @inline(never) public func runtimeHookEdited(_ value: String) -> String {
            var output = value
            runtimeHookEdit(&output, " native")
            return output
        }
        """)
        defer { fixture.cleanup() }
        let echo = try await fixture.runtime.swiftFunction(named: fixture.module + ".runtimeHookEcho(_:)",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self,
            genericArguments: [.type(Int64.self)], in: fixture.providerScope)
        let integer = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".runtimeHookInteger(_:)",
            as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let saved = SavedRuntimeHookValues()
        let first = try unsafe await echo.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                #expect(try value.withCopy { $0 as? Int64 } == 41)
                saved.input = value
                let result = try call.proceed(value)
                saved.output = result
                return result
            }
        defer { first.invalidate() }
        #expect(try unsafe integer.unsafeInvoke(41) == 41)
        #expect(try saved.input?.take(as: Int64.self) == 41)
        #expect(saved.output?.isConsumed == true)
        first.invalidate()

        typealias Pair = (Int64, NativeSwiftClosure<() -> String>)
        let tuple = try await fixture.runtime.swiftFunction(named: fixture.module + ".runtimeHookTuple(_:)",
            as: ((Pair) -> Pair).self, in: fixture.providerScope)
        let nested = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".runtimeHookNested(_:_:)",
            as: ((Int64, String) -> (Int64, String)).self, in: fixture.callerScope)
        let second = try unsafe await tuple.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                saved.borrowedClosure = value.1
                saved.copiedClosure = try value.1.copy()
                let result = try call.proceed((value.0 + 1, value.1))
                return (result.0 + 1, result.1)
            }
        defer { second.invalidate() }
        let text = String(repeating: "runtime hook ", count: 50)
        let pair = try unsafe nested.unsafeInvoke(40, text)
        #expect(pair.0 == 42 && pair.1 == text)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) { try unsafe saved.borrowedClosure!.unsafeInvoke() }
        #expect(try unsafe saved.copiedClosure!.unsafeInvoke() == text)
        second.invalidate()

        let edit = try await fixture.runtime.swiftFunction(named: fixture.module + ".runtimeHookEdit(_:_:)",
            as: ((NativeSwiftInout<String>, NativeSwiftConsuming<String>) -> Void).self, in: fixture.providerScope)
        let edited = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".runtimeHookEdited(_:)",
            as: ((String) -> String).self, in: fixture.callerScope)
        let third = try unsafe await edit.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value, suffix in
                value.value += " before"
                try call.proceed(value, NativeSwiftConsuming(suffix.value + " replacement"))
                value.value += " after"
            }
        defer { third.invalidate() }
        #expect(try unsafe edited.unsafeInvoke(text) == text + " before native replacement after")
    }

    @Test func unmatchedPackBindingsPreserveStackArguments() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) public func hookStackPack<each Value>(_ values: repeat each Value,
            a: Int64, b: Int64, c: Int64, d: Int64, e: Int64, f: Int64, g: Int64, h: Int64) -> String {
            var result = ""
            for value in repeat each values { result += "\\(value)|" }
            return result + "sum=\\(a+b+c+d+e+f+g+h)"
        }
        """, callerExtra: """
        @inline(never) public func stackPackEmpty() -> String {
            hookStackPack(a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8)
        }
        @inline(never) public func stackPackOne() -> String {
            hookStackPack(Int64(41), a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8)
        }
        @inline(never) public func stackPackTen() -> String {
            hookStackPack(Int64(1), Int64(2), Int64(3), Int64(4), Int64(5), Int64(6), Int64(7), Int64(8), Int64(9), Int64(10),
                a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8)
        }
        """)
        defer { fixture.cleanup() }
        let short = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookStackPack(_:a:b:c:d:e:f:g:h:)",
            as: ((Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) -> String).self,
            genericArguments: [.pack([.type(Int64.self)])], in: fixture.providerScope)
        let long = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookStackPack(_:a:b:c:d:e:f:g:h:)",
            as: ((Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64,
                  Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) -> String).self,
            genericArguments: [.pack(Array(repeating: .type(Int64.self), count: 10))], in: fixture.providerScope)
        let empty = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".stackPackEmpty()",
            as: (() -> String).self, in: fixture.callerScope)
        let one = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".stackPackOne()",
            as: (() -> String).self, in: fixture.callerScope)
        let ten = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".stackPackTen()",
            as: (() -> String).self, in: fixture.callerScope)
        let expectedTen = "1|2|3|4|5|6|7|8|9|10|sum=36"
        #expect(try unsafe empty.unsafeInvoke() == "sum=36")
        #expect(try unsafe one.unsafeInvoke() == "41|sum=36")
        #expect(try unsafe ten.unsafeInvoke() == expectedTen)
        let first = try unsafe await short.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value, a, b, c, d, e, f, g, h in
                try call.proceed(value, a, b, c, d, e, f, g, h) + " short"
            }
        defer { first.invalidate() }
        #expect(try unsafe empty.unsafeInvoke() == "sum=36")
        #expect(try unsafe one.unsafeInvoke() == "41|sum=36 short")
        #expect(try unsafe ten.unsafeInvoke() == expectedTen)
        let second = try unsafe await long.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, a, b, c, d, e, f, g, h in
                try call.proceed(v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, a, b, c, d, e, f, g, h) + " long"
            }
        defer { second.invalidate() }
        first.invalidate()
        #expect(try unsafe empty.unsafeInvoke() == "sum=36")
        #expect(try unsafe one.unsafeInvoke() == "41|sum=36")
        #expect(try unsafe ten.unsafeInvoke() == expectedTen + " long")
        second.invalidate()
        #expect(try unsafe empty.unsafeInvoke() == "sum=36")
        #expect(try unsafe one.unsafeInvoke() == "41|sum=36")
        #expect(try unsafe ten.unsafeInvoke() == expectedTen)
    }

    @Test func tuplePackClassArgumentsUseTheirPhysicalNativePositions() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) public func hookPlainTuplePack<each Value>(_ values: (repeat each Value, object: NSObject)) -> NSObject {
            values.object
        }
        @inline(never) public func hookTuplePack<each Value, Object: AnyObject>(_ values: (repeat each Value, object: Object)) -> Object {
            values.object
        }
        """, callerExtra: """
        @inline(never) public func plainTuplePackObject(_ object: NSObject) -> NSObject {
            hookPlainTuplePack((Int64(4), "plain", object: object))
        }
        @inline(never) public func tuplePackObject(_ object: NSObject) -> NSObject {
            hookTuplePack((Int64(4), "bound", object: object))
        }
        @inline(never) public func tuplePackOther(_ object: NSObject) -> NSObject {
            hookTuplePack((true, object: object))
        }
        """)
        defer { fixture.cleanup() }
        typealias Values = (Int64, String, object: NSObject)
        let plain = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookPlainTuplePack(_:)",
            as: ((Values) -> NSObject).self,
            genericArguments: [.pack([.type(Int64.self), .type(String.self)])], in: fixture.providerScope)
        let bound = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookTuplePack(_:)",
            as: ((Values) -> NSObject).self,
            genericArguments: [.pack([.type(Int64.self), .type(String.self)]), .type(NSObject.self)], in: fixture.providerScope)
        let plainCaller = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".plainTuplePackObject(_:)",
            as: ((NSObject) -> NSObject).self, in: fixture.callerScope)
        let boundCaller = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".tuplePackObject(_:)",
            as: ((NSObject) -> NSObject).self, in: fixture.callerScope)
        let otherCaller = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".tuplePackOther(_:)",
            as: ((NSObject) -> NSObject).self, in: fixture.callerScope)
        let calls = Mutex(0)
        let first = try unsafe await plain.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                calls.withLock { $0 += 1 }
                return try call.proceed(value)
            }
        defer { first.invalidate() }
        let second = try unsafe await bound.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                calls.withLock { $0 += 1 }
                return try call.proceed((value.0 + 1, value.1, object: value.object))
            }
        defer { second.invalidate() }
        let object = NSObject()
        #expect(try unsafe plainCaller.unsafeInvoke(object) === object)
        #expect(try unsafe boundCaller.unsafeInvoke(object) === object)
        #expect(try unsafe otherCaller.unsafeInvoke(object) === object)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func returnedClosuresTransferOneOwnedContextThroughProceed() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) public func hookFactory(_ value: AnyObject) -> () -> AnyObject { { value } }
        """, callerExtra: """
        @inline(never) public func importedFactory(_ value: AnyObject) -> () -> AnyObject { hookFactory(value) }
        """)
        defer { fixture.cleanup() }
        typealias Closure = NativeSwiftClosure<() -> AnyObject>
        let factory = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookFactory(_:)",
            as: ((AnyObject) -> Closure).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedFactory(_:)",
            as: ((AnyObject) -> Closure).self, in: fixture.callerScope)
        let hook = try unsafe await factory.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                _ = try call.proceed(value)
                return try call.proceed(value)
            }
        defer { hook.invalidate() }
        weak var observed: NSObject?
        var saved: Closure?
        do {
            let object = NSObject()
            observed = object
            saved = try unsafe oracle.unsafeInvoke(object as AnyObject)
            #expect(try unsafe saved?.unsafeInvoke() === object)
        }
        hook.invalidate()
        #expect(observed != nil)
        saved = nil
        #expect(observed == nil)
    }

    @Test func genericHooksSelectBindingsBeforeReadingNativeValues() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        import Foundation
        @inline(never) public func hookEcho<Value>(_ value: Value) -> Value { value }
        @inline(never) public func hookPack<each Value>(_ values: repeat each Value) -> (repeat each Value) { (repeat each values) }
        @inline(never) public func hookTuple(_ value: (Int64, String)) -> (Int64, String) { value }
        @inline(never) public func hookNativeScalar(_ value: Int64) -> Int64 { value + 1 }
        @inline(never) public func hookGenericFactory<Value>(_ value: Value) -> () -> Value { { value } }
        """, callerExtra: """
        import Foundation
        @inline(never) public func echoInt(_ value: Int64) -> Int64 { hookEcho(value) }
        @inline(never) public func echoText(_ value: String) -> String { hookEcho(value) }
        @inline(never) public func echoArray(_ value: [String]) -> [String] { hookEcho(value) }
        @inline(never) public func forwardGeneric<Value>(_ value: Value) -> Value { hookEcho(value) }
        @inline(never) public func importedTuple(_ value: (Int64, String)) -> (Int64, String) { hookTuple(value) }
        @inline(never) public func importedNativeScalar(_ value: Int64) -> Int64 { hookNativeScalar(value) }
        @inline(never) public func echoObject(_ value: NSObject) -> NSObject { hookEcho(value) }
        @inline(never) public func genericFactoryInteger(_ value: Int64) -> Int64 { hookGenericFactory(value)() }
        @inline(never) public func genericFactoryString(_ value: String) -> String { hookGenericFactory(value)() }
        @inline(never) public func packPair(_ value: Int64, _ text: String) -> (Int64, String) { hookPack(value, text) }
        @inline(never) public func packSingle(_ value: Int64) -> Int64 { hookPack(value) }
        @inline(never) public func packTriple(_ text: String) -> (String, Int64, Double) { hookPack(text, Int64(7), 1.5) }
        """)
        defer { fixture.cleanup() }
        let integer = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookEcho(_:)",
            as: ((Int64) -> Int64).self, genericArguments: [.type(Int64.self)], in: fixture.providerScope)
        let text = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookEcho(_:)",
            as: ((String) -> String).self, genericArguments: [.type(String.self)], in: fixture.providerScope)
        let intOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".echoInt(_:)",
            as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let textOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".echoText(_:)",
            as: ((String) -> String).self, in: fixture.callerScope)
        let arrayOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".echoArray(_:)",
            as: (([String]) -> [String]).self, in: fixture.callerScope)
        #expect(try unsafe intOracle.unsafeInvoke(40) == 40)
        let failures = Mutex<[String]>([])
        let failure: @Sendable (any Error) -> Void = { error in failures.withLock { $0.append(String(describing: error)) } }
        let intHook = try unsafe await integer.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: failure) { call, value in try call.proceed(value + 1) + 10 }
        defer { intHook.invalidate() }
        let textHook = try unsafe await text.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: failure) { call, value in try call.proceed(value + " input") + " output" }
        defer { textHook.invalidate() }
        let input = String(repeating: "generic hook value ", count: 80)
        #expect(try unsafe intOracle.unsafeInvoke(40) == 51)
        #expect(try unsafe textOracle.unsafeInvoke(input) == input + " input output")
        #expect(try unsafe arrayOracle.unsafeInvoke([input, "unchanged"]) == [input, "unchanged"])
        intHook.invalidate()
        #expect(try unsafe intOracle.unsafeInvoke(40) == 40)
        #expect(try unsafe textOracle.unsafeInvoke(input) == input + " input output")
        textHook.invalidate()
        #expect(try unsafe textOracle.unsafeInvoke(input) == input)

        let object = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookEcho(_:)",
            as: ((NSObject) -> NSObject).self, genericArguments: [.type(NSObject.self)], in: fixture.providerScope)
        let objectOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".echoObject(_:)",
            as: ((NSObject) -> NSObject).self, in: fixture.callerScope)
        let received = Mutex(0)
        let objectHook = try unsafe await object.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: failure) { call, value in
                received.withLock { $0 += 1 }
                return try call.proceed(value)
            }
        defer { objectHook.invalidate() }
        let instance = NSObject()
        #expect(try unsafe objectOracle.unsafeInvoke(instance) === instance)
        #expect(received.withLock { $0 } == 1)
        objectHook.invalidate()

        let factory = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookGenericFactory(_:)",
            as: ((Int64) -> NativeSwiftClosure<() -> Int64>).self,
            genericArguments: [.type(Int64.self)], in: fixture.providerScope)
        let factoryOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".genericFactoryInteger(_:)",
            as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let factoryControl = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".genericFactoryString(_:)",
            as: ((String) -> String).self, in: fixture.callerScope)
        #expect(try unsafe factoryOracle.unsafeInvoke(40) == 40)
        let factoryHook = try unsafe await factory.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: failure) { call, value in
                _ = try call.proceed(value)
                return try call.proceed(value + 1)
            }
        defer { factoryHook.invalidate() }
        #expect(try unsafe factoryOracle.unsafeInvoke(40) == 41)
        #expect(try unsafe factoryControl.unsafeInvoke(input) == input)
        factoryHook.invalidate()

        let native = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookEcho(_:)",
            as: ((SwiftHookDistinctABIValue) -> SwiftHookDistinctABIValue).self,
            genericArguments: [.type(SwiftHookDistinctABIValue.self)], in: fixture.providerScope)
        let nativeOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".forwardGeneric(_:)",
            as: ((SwiftHookDistinctABIValue) -> SwiftHookDistinctABIValue).self,
            genericArguments: [.type(SwiftHookDistinctABIValue.self)], in: fixture.callerScope)
        let nativeHook = try unsafe await native.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: failure) { call, value in
                try call.proceed(.init(value.number + 1, value.text + " native"))
            }
        defer { nativeHook.invalidate() }
        let preserved = try unsafe nativeOracle.unsafeInvoke(.init(40, input))
        #expect(preserved.number == 41 && preserved.text == input + " native")
        nativeHook.invalidate()

        let tuple = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookTuple(_:)",
            as: (((Int64, String)) -> (Int64, String)).self, in: fixture.providerScope)
        let tupleOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedTuple(_:)",
            as: (((Int64, String)) -> (Int64, String)).self, in: fixture.callerScope)
        let tupleHook = try unsafe await tuple.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: failure) { call, value in try call.proceed((value.0 + 4, value.1 + " tuple")) }
        defer { tupleHook.invalidate() }
        let tupleResult = try unsafe tupleOracle.unsafeInvoke((Int64(40), input))
        #expect(tupleResult.0 == 44 && tupleResult.1 == input + " tuple")
        tupleHook.invalidate()

        let scalarAdapter = try await fixture.runtime.swiftFunction(
            named: fixture.module + ".hookNativeScalar(Swift.Int64) -> Swift.Int64",
            as: ((Int64) -> SwiftHookDistinctABIValue).self, in: fixture.providerScope)
        let scalarOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedNativeScalar(_:)",
            as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let scalarHook = try unsafe await scalarAdapter.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: failure) { call, value in
                let result = try call.proceed(value)
                return .init(result.number + 10, result.text)
            }
        defer { scalarHook.invalidate() }
        #expect(try unsafe scalarOracle.unsafeInvoke(40) == 51)
        scalarHook.invalidate()

        let pair = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookPack(_:)",
            as: ((Int64, String) -> (Int64, String)).self,
            genericArguments: [.pack([.type(Int64.self), .type(String.self)])], in: fixture.providerScope)
        let single = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookPack(_:)",
            as: ((Int64) -> Int64).self, genericArguments: [.pack([.type(Int64.self)])], in: fixture.providerScope)
        let pairOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".packPair(_:_:)",
            as: ((Int64, String) -> (Int64, String)).self, in: fixture.callerScope)
        let singleOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".packSingle(_:)",
            as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let tripleOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".packTriple(_:)",
            as: ((String) -> (String, Int64, Double)).self, in: fixture.callerScope)
        #expect(try unsafe singleOracle.unsafeInvoke(40) == 40)
        let pairHook = try unsafe await pair.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: failure) { call, number, text in try call.proceed(number + 2, text + " pair") }
        defer { pairHook.invalidate() }
        let singleHook = try unsafe await single.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: failure) { call, value in try call.proceed(value + 3) }
        defer { singleHook.invalidate() }
        let paired = try unsafe pairOracle.unsafeInvoke(40, input)
        #expect(paired.0 == 42 && paired.1 == input + " pair")
        #expect(try unsafe singleOracle.unsafeInvoke(40) == 43)
        let untouched = try unsafe tripleOracle.unsafeInvoke(input)
        #expect(untouched.0 == input && untouched.1 == 7 && untouched.2 == 1.5)
        pairHook.invalidate(); singleHook.invalidate()
        let restored = try unsafe pairOracle.unsafeInvoke(40, input)
        #expect(restored.0 == 40 && restored.1 == input)
        #expect(failures.withLock { $0.isEmpty })
    }

    @Test func throwingHooksUseNativeErrorsAndPreserveCompletedFailures() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        import Foundation
        @inline(never) public func throwsAny(_ value: Int64, _ calls: UnsafeMutablePointer<Int64>) throws -> Int64 {
            calls.pointee += 1
            if value < 0 { throw NSError(domain: "native", code: Int(value)) }
            return value + 1
        }
        @inline(never) public func throwsTyped(_ value: Int64, _ calls: UnsafeMutablePointer<Int64>) throws(NSError) -> Int64 {
            calls.pointee += 1
            if value < 0 { throw NSError(domain: "native", code: Int(value)) }
            return value + 1
        }
        """, callerExtra: """
        import Foundation
        @inline(never) public func importedThrowsAny(_ value: Int64, _ calls: UnsafeMutablePointer<Int64>) throws -> Int64 {
            try throwsAny(value, calls)
        }
        @inline(never) public func importedThrowsTyped(_ value: Int64, _ calls: UnsafeMutablePointer<Int64>) throws(NSError) -> Int64 {
            try throwsTyped(value, calls)
        }
        """)
        defer { fixture.cleanup() }
        let any = try await fixture.runtime.swiftFunction(named: fixture.module + ".throwsAny(_:_:)",
            as: ((Int64, UnsafeMutablePointer<Int64>) throws -> Int64).self, in: fixture.providerScope)
        let anyOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedThrowsAny(_:_:)",
            as: ((Int64, UnsafeMutablePointer<Int64>) throws -> Int64).self, in: fixture.callerScope)
        let typed = try await fixture.runtime.swiftFunction(named: fixture.module + ".throwsTyped(_:_:)",
            as: ((Int64, UnsafeMutablePointer<Int64>) throws(NSError) -> Int64).self, in: fixture.providerScope)
        let typedOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedThrowsTyped(_:_:)",
            as: ((Int64, UnsafeMutablePointer<Int64>) throws(NSError) -> Int64).self, in: fixture.callerScope)
        let calls = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        calls.initialize(to: 0)
        defer { calls.deinitialize(count: 1); calls.deallocate() }
        #expect(try unsafe anyOracle.unsafeInvoke(1, calls) == 2)
        #expect(try unsafe typedOracle.unsafeInvoke(1, calls) == 2)
        let failures = Mutex(0)
        let anyHook = try unsafe await any.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value, count in
                if value == 99 { throw SwiftHookTestFailure.afterProceed }
                let result = try call.proceed(value, count)
                if value == 98 { throw SwiftHookTestFailure.afterProceed }
                return result + 10
            }
        defer { anyHook.invalidate() }
        #expect(try unsafe anyOracle.unsafeInvoke(1, calls) == 12)
        func caught(_ body: () throws -> Int64) throws -> NativeSwiftError {
            do { _ = try body(); throw SwiftHookTestFailure.timeout }
            catch let error as NativeSwiftError { return error }
        }
        calls.pointee = 0
        let before = try caught { try unsafe anyOracle.unsafeInvoke(99, calls) }
        before.withUnderlyingError { #expect($0 is SwiftHookTestFailure) }
        #expect(calls.pointee == 0)
        let after = try caught { try unsafe anyOracle.unsafeInvoke(98, calls) }
        after.withUnderlyingError { #expect($0 is SwiftHookTestFailure) }
        #expect(calls.pointee == 1)
        let native = try caught { try unsafe anyOracle.unsafeInvoke(-7, calls) }
        native.withUnderlyingError { #expect(($0 as NSError).domain == "native" && ($0 as NSError).code == -7) }
        #expect(calls.pointee == 2 && failures.withLock { $0 } == 0)

        let typedHook = try unsafe await typed.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value, count in
                if value == 99 { throw NSError(domain: "hook", code: 99) }
                if value == 98 { throw SwiftHookTestFailure.afterProceed }
                do {
                    let result = try call.proceed(value, count)
                    if value == 97 { throw SwiftHookTestFailure.afterProceed }
                    return result + 10
                } catch {
                    if value == -8 { throw SwiftHookTestFailure.afterProceed }
                    throw error
                }
            }
        defer { typedHook.invalidate() }
        calls.pointee = 0
        let replacement = try caught { try unsafe typedOracle.unsafeInvoke(99, calls) }
        replacement.withUnderlyingError { #expect(($0 as NSError).domain == "hook") }
        #expect(calls.pointee == 0)
        #expect(try unsafe typedOracle.unsafeInvoke(98, calls) == 99)
        #expect(try unsafe typedOracle.unsafeInvoke(97, calls) == 98)
        let preserved = try caught { try unsafe typedOracle.unsafeInvoke(-8, calls) }
        preserved.withUnderlyingError { #expect(($0 as NSError).domain == "native" && ($0 as NSError).code == -8) }
        #expect(calls.pointee == 3 && failures.withLock { $0 } == 3)
        typedHook.invalidate()
        anyHook.invalidate()
        #expect(try unsafe typedOracle.unsafeInvoke(1, calls) == 2)
        let fallback = try caught { try unsafe anyOracle.unsafeInvoke(-9, calls) }
        fallback.withUnderlyingError { #expect(($0 as NSError).code == -9) }
    }

    @Test func opaqueResultsKeepTheirDeclaredReturnConvention() async throws {
        let fixture = try CompiledSwiftReplacementFixture()
        defer { fixture.cleanup() }
        let scalar = try await fixture.runtime.swiftFunction(named: fixture.module + ".opaqueScalar(Swift.Int64) -> some",
            as: ((Int64) -> Int64).self, declaredAs: "(Swift.Int64) -> some", in: fixture.providerScope)
        let scalarOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedOpaqueScalar(_:)",
            as: ((Int64) -> Int64).self, in: fixture.callerScope)
        #expect(try unsafe scalar.unsafeInvoke(41) == 42)
        let scalarHook = try await unsafe scalar.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in try call.proceed(value + 1) + 10 }
        defer { scalarHook.invalidate() }
        #expect(try unsafe scalarOracle.unsafeInvoke(40) == 52)
        scalarHook.invalidate()
        #expect(try unsafe scalarOracle.unsafeInvoke(40) == 41)

        let text = try await fixture.runtime.swiftFunction(named: fixture.module + ".opaqueText(Swift.String) -> some",
            as: ((String) -> String).self, declaredAs: "(Swift.String) -> some", in: fixture.providerScope)
        let textOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedOpaqueText(_:)",
            as: ((String) -> String).self, in: fixture.callerScope)
        let textHook = try await unsafe text.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                _ = try call.proceed(value + " discarded")
                return try call.proceed(value + " edited") + " returned"
            }
        defer { textHook.invalidate() }
        let input = String(repeating: "owned opaque value ", count: 100)
        for _ in 0..<10 {
            #expect(try unsafe textOracle.unsafeInvoke(input) == input + " edited original returned")
        }
        let failures = Mutex(0)
        let failing = try await unsafe text.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value in
                _ = try call.proceed(value + " outer")
                throw SwiftHookTestFailure.afterProceed
            }
        defer { failing.invalidate() }
        #expect(try unsafe textOracle.unsafeInvoke(input) == input + " outer edited original returned")
        #expect(failures.withLock { $0 } == 1)
        failing.invalidate()
        textHook.invalidate()
        #expect(try unsafe textOracle.unsafeInvoke(input) == input + " original")
    }

    @Test func chainsTypedArgumentsResultsAndIndependentInvalidation() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: (@Sendable (Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let failures = Mutex<[String]>([])
        let first = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in
                #expect(call.declaration.name.contains("scalar"))
                #expect(call.description.contains("scalar"))
                return try call.proceed(value + 1) + 10
            }
        defer { first.invalidate() }
        #expect(first.slots.count == 1 && first.slots[0].status == .active)
        #expect(try unsafe oracle.unsafeInvoke(40) == 52)
        let second = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in
                try call.proceed(value * 2) + 100
            }
        defer { second.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(40) == 192)
        first.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(40) == 181)
        second.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(40) == 41)
        #expect(first.slots[0].status == .invalidated && second.slots[0].status == .invalidated)
        #expect(failures.withLock { $0.isEmpty })
    }

    @Test func editsOwnedStringsAndPreservesLatestResultAfterFailure() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".text(_:)", as: ((String) -> String).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedText(_:)", as: ((String) -> String).self, in: fixture.callerScope)
        let failures = Mutex<[String]>([])
        let calls = Mutex(0)
        let hook = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in
                calls.withLock { $0 += 1 }
                _ = try call.proceed(value + " discarded")
                return try call.proceed(value + " edited") + " returned"
            }
        defer { hook.invalidate() }
        let input = String(repeating: "heap-backed", count: 100)
        for _ in 0..<20 {
            #expect(try unsafe oracle.unsafeInvoke(input) == "original:" + input + " edited returned")
        }
        let failing = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in
                _ = try call.proceed(value + " outer")
                throw SwiftHookTestFailure.afterProceed
            }
        #expect(try unsafe oracle.unsafeInvoke(input) == "original:" + input + " outer edited returned")
        failing.invalidate(); hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(input) == "original:" + input)
        #expect(failures.withLock { $0.count } == 1)
        #expect(calls.withLock { $0 } == 21)
    }

    @Test func editsTheIncomingObjectBeforeAndAfterProceeding() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        import Foundation
        @inline(never) public func objectLength(_ value: NSMutableString) -> Int64 { Int64(value.length) }
        """, callerExtra: """
        import Foundation
        @inline(never) public func importedObjectLength(_ value: NSMutableString) -> Int64 { objectLength(value) }
        """); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".objectLength(_:)", as: ((NSMutableString) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedObjectLength(_:)", as: ((NSMutableString) -> Int64).self, in: fixture.callerScope)
        let hook = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record("Unexpected hook error: \($0)") }) { call, value in
                value.append("!")
                let result = try call.proceed(value)
                value.append("?")
                return result + 100
            }
        defer { hook.invalidate() }
        let value = NSMutableString(string: "abc")
        #expect(try unsafe oracle.unsafeInvoke(value) == 104)
        #expect(value == "abc!?")
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(value) == 5)
    }

    @Test @MainActor func mainActorCallbacksBypassBackgroundEntry() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: (@Sendable (Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let state = SwiftHookMainActorState()
        let failures = Mutex<[String]>([])
        let hook = try await unsafe target.hookMainActorImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in
                state.calls += 1
                return try call.proceed(value + 1)
            }
        defer { hook.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(40) == 42)
        let background = try await Task.detached { try unsafe oracle.unsafeInvoke(40) }.value
        #expect(background == 41 && state.calls == 1)
        #expect(failures.withLock { $0 } == ["wrongThread"])
    }

    @Test func preservesIndirectResultsThroughTheCompiledCaller() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".payload(Swift.Int64) -> " + fixture.module + ".ReplacementPayload",
            as: ((Int64) -> SwiftABIFive).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedPayload(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let hook = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record("Unexpected hook error: \($0)") }) { call, value in
                var result = try call.proceed(value + 1)
                result.a += 100
                return result
            }
        defer { hook.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(40) == 315)
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(40) == 210)
    }

    @Test func handlesZeroArgumentsVoidAndStackArguments() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) public func zero() -> Int64 { 42 }
        @inline(never) public func touch(_ value: UnsafeMutablePointer<Int64>) { value.pointee += 10 }
        @inline(never) public func many(_ a: Int64, _ b: Int64, _ c: Int64, _ d: Int64, _ e: Int64, _ f: Int64, _ g: Int64, _ h: Int64, _ i: Int64, _ j: Int64, _ k: Int64, _ l: Int64) -> Int64 { a+b+c+d+e+f+g+h+i+j+k+l }
        """, callerExtra: """
        @inline(never) public func importedZero() -> Int64 { zero() }
        @inline(never) public func importedTouch(_ value: UnsafeMutablePointer<Int64>) { touch(value) }
        @inline(never) public func importedMany() -> Int64 { many(1,2,3,4,5,6,7,8,9,10,11,12) }
        """); defer { fixture.cleanup() }
        let zero = try await fixture.runtime.swiftFunction(named: fixture.module + ".zero()", as: (() -> Int64).self, in: fixture.providerScope)
        let zeroOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedZero()", as: (() -> Int64).self, in: fixture.callerScope)
        let zeroHook = try await unsafe zero.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call in
            try call.proceed() + 100
        }
        defer { zeroHook.invalidate() }
        #expect(try unsafe zeroOracle.unsafeInvoke() == 142)
        let touch = try await fixture.runtime.swiftFunction(named: fixture.module + ".touch(_:)", as: ((UnsafeMutablePointer<Int64>) -> Void).self, in: fixture.providerScope)
        let touchOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedTouch(_:)", as: ((UnsafeMutablePointer<Int64>) -> Void).self, in: fixture.callerScope)
        let touchHook = try await unsafe touch.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            value.pointee += 1
            try call.proceed(value)
            value.pointee += 2
        }
        defer { touchHook.invalidate() }
        var value: Int64 = 0
        try withUnsafeMutablePointer(to: &value) { try unsafe touchOracle.unsafeInvoke($0) }
        #expect(value == 13)
        let many = try await fixture.runtime.swiftFunction(named: fixture.module + ".many(_:_:_:_:_:_:_:_:_:_:_:_:)",
            as: ((Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) -> Int64).self, in: fixture.providerScope)
        let manyOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedMany()", as: (() -> Int64).self, in: fixture.callerScope)
        let manyHook = try await unsafe many.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, a,b,c,d,e,f,g,h,i,j,k,l in
            try call.proceed(a,b,c,d,e,f,g,h,i,j,k,l+100)
        }
        defer { manyHook.invalidate() }
        #expect(try unsafe manyOracle.unsafeInvoke() == 178)
    }

    @Test func preservesDisplacementAndSavedDispatcherLifetime() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let replacement = try await fixture.runtime.swiftFunction(named: fixture.module + ".replacementScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let hook = try await unsafe target.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            try call.proceed(value + 1)
        }
        let external = try await unsafe target.prepareImportedReplacement(with: replacement, in: fixture.callerScope)
        let saved = try #require(external.slots.first?.original)
        try unsafe external.install()
        #expect(hook.slots[0].status == .displaced)
        #expect(try unsafe oracle.unsafeInvoke(40) == 140)
        #expect(try unsafe saved.unsafeInvoke(40) == 42)
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(40) == 140)
        #expect(try unsafe saved.unsafeInvoke(40) == 41)
        try external.restore()
        #expect(try unsafe oracle.unsafeInvoke(40) == 41)
    }

    @Test func failedPublicationKeepsProtectionOnlyRecoveryReachable() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let selection = try ImportedFunctionSelection(resolver: SymbolResolver(), declaration: target.symbol.declaration,
            importer: fixture.callerScope, provider: nil, language: .swift)
        let signature = try SwiftHookCallbackSignature<Int64, Int64>().erased(consumingArguments: false, retaining: target)
        let handler = SwiftHookHandler(failure: { Issue.record("Unexpected: \($0)") }) { frame, values in
            try frame.use { try $0(values) }
        }
        let repaired = Mutex(false)
        let transport = SwiftReplacementTransport(exchange: { _, before, _ in
            var result = ABIPointerSlotResult()
            result.status = Int32(ABIPointerSlotRestoreFailed)
            result.observed = before
            result.restoreProtectionError = KERN_PROTECTION_FAILURE
            result.protectionBefore = VM_PROT_READ
            return result
        }, repair: { _, _, _, _, _, _ in
            var result = ABIPointerSlotResult()
            result.status = Int32(repaired.withLock { $0 } ? ABIPointerSlotComplete : ABIPointerSlotRestoreFailed)
            result.restoreProtectionError = repaired.withLock { $0 } ? 0 : KERN_PROTECTION_FAILURE
            return result
        })
        let registry = SwiftHookRegistry()
        do {
            _ = try await registry.register(selection: selection, signature: signature, handler: handler, transport: transport)
            Issue.record("Expected injected publication failure")
        } catch let error as NativeSwiftHookInstallationError {
            let slot = try #require(error.registration.slots.first)
            #expect(slot.mutation?.didWrite == false)
            #expect(slot.protectionRecovery?.status == Int32(ABIPointerSlotRestoreFailed))
            #expect(try unsafe oracle.unsafeInvoke(40) == 41)
            repaired.withLock { $0 = true }
            try await registry.recover(node: ObjectIdentifier(error.registration.node), records: error.registration.records)
            #expect(error.registration.slots[0].protectionRecovery?.status == Int32(ABIPointerSlotComplete))
        }
    }

    @Test func releasesCapturesAndRejectsEscapedContinuations() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let saved = SavedSwiftHookInvocation()
        let released = Mutex(false)
        var capture: SwiftHookCapture? = SwiftHookCapture { released.withLock { $0 = true } }
        let hook = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record("Unexpected hook error: \($0)") }) { [capture] call, value in
                withExtendedLifetime(capture) { saved.value = call }
                return try call.proceed(value)
            }
        capture = nil
        #expect(try unsafe oracle.unsafeInvoke(40) == 41)
        let escaped = try #require(saved.value)
        #expect(throws: NativeSwiftHookInvocationError.expiredInvocation) { try escaped.proceed(40) }
        #expect(!released.withLock { $0 })
        hook.invalidate()
        #expect(released.withLock { $0 })
        #expect(try unsafe oracle.unsafeInvoke(40) == 41)
    }

    @Test func concurrentCallsKeepTheirSnapshotsWhileInvalidationReleasesCaptures() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let released = Mutex(false)
        let failures = Mutex<[String]>([])
        var capture: SwiftHookCapture? = SwiftHookCapture { released.withLock { $0 = true } }
        let hook = try await unsafe target.hookImportedCalls(in: fixture.callerScope,
            onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { [capture] call, value in
            entered.signal()
            guard resume.wait(timeout: .now() + 10) == .success else { throw SwiftHookTestFailure.timeout }
            return try withExtendedLifetime(capture) { try call.proceed(value + 1) }
        }
        capture = nil
        // Both sides of this intentionally blocked native call must progress
        // independently of Swift's bounded cooperative executor on busy runners.
        let observation: (Int64, Bool, Bool) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let done = DispatchSemaphore(value: 0)
                let result = Mutex<Swift.Result<Int64, any Error>?>(nil)
                DispatchQueue.global(qos: .userInitiated).async {
                    let value = Swift.Result { try unsafe oracle.unsafeInvoke(40) }
                    result.withLock { $0 = value }
                    done.signal()
                }
                let didEnter = entered.wait(timeout: .now() + 10) == .success
                hook.invalidate()
                let retainedDuringCall = !released.withLock { $0 }
                resume.signal()
                let didFinish = done.wait(timeout: .now() + 10) == .success
                guard didEnter && didFinish else {
                    continuation.resume(throwing: SwiftHookTestFailure.timeout)
                    return
                }
                do {
                    let value = try result.withLock { try $0!.get() }
                    continuation.resume(returning: (value, retainedDuringCall, released.withLock { $0 }))
                } catch { continuation.resume(throwing: error) }
            }
        }
        #expect(observation.0 == 42 && observation.1 && observation.2)
        #expect(failures.withLock { $0.isEmpty })
        let next = try await unsafe target.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            try call.proceed(value + 1) + 1
        }
        defer { next.invalidate() }
        let sum = try await withThrowingTaskGroup(of: Int64.self) { group in
            for index in 0..<32 { group.addTask { try unsafe oracle.unsafeInvoke(Int64(index)) } }
            return try await group.reduce(Int64(0), +)
        }
        #expect(sum == 592)
    }

    @Test func reusingAnEntryRetainsAdditionalCodeOwnersIndependentlyOfCallbacks() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let first = try await unsafe target.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in try call.proceed(value) }
        var owner: SwiftHookCapture? = SwiftHookCapture {}
        weak var retainedOwner = owner
        let second = try await unsafe target.hookImportedCalls(in: fixture.callerScope, retaining: owner,
            onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in try call.proceed(value) }
        owner = nil
        first.invalidate(); second.invalidate()
        #expect(retainedOwner != nil)
    }
}

private struct SwiftHookDistinctABIValue: ABIBridgeValue {
    static var abiType: NativeType { .int64 }
    let number: Int64
    let text: String
    init(_ number: Int64, _ text: String) { self.number = number; self.text = text }
    init(nativeValue: NativeValue) throws {
        number = try unsafe nativeValue.read(as: Int64.self)
        text = "foreign conversion"
    }
    static func nativeValue(from value: Self) throws -> NativeValue { try .init(copying: value.number, as: .int64) }
}

private final class SavedRuntimeHookValues: @unchecked Sendable {
    var runtimeContinuation: NativeSwiftFunctionInvocation<(NativeSwiftConsuming<NativeSwiftValue>) -> Int64>?
    var input: NativeSwiftValue?
    var output: NativeSwiftValue?
    var borrowedClosure: NativeSwiftClosure<() -> String>?
    var copiedClosure: NativeSwiftClosure<() -> String>?
}

private enum SwiftHookTestFailure: Error { case afterProceed, timeout }

@MainActor private final class SwiftHookMainActorState { var calls = 0 }

// The fixture invokes synchronously; this box deliberately lets the test retain
// a non-Sendable continuation after that same call has completed.
private final class SavedSwiftHookInvocation: @unchecked Sendable {
    var value: NativeSwiftFunctionInvocation<(Int64) -> Int64>?
}

private final class SwiftHookCapture: Sendable {
    let release: @Sendable () -> Void
    init(_ release: @escaping @Sendable () -> Void) { self.release = release }
    deinit { release() }
}
private struct RuntimeHookBodyFailure: Error {}


private struct OptionalHookPointer: ABIBridgeValue {
    static let abiType = NativeType.pointer
    let native: NativeValue
    let marker: Int64
    init(nativeValue: NativeValue) { native = nativeValue; marker = 42 }
    static func nativeValue(from value: Self) -> NativeValue { value.native }
}

#endif
