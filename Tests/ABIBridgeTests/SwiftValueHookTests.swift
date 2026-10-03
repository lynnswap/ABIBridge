#if os(macOS) && DEBUG
@testable import ABIBridge
import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct SwiftValueHookTests {
    @Test func indirectReceiversAndResultsPreserveTheirSeparateStorage() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        public struct WideValue {
            public var a,b,c,d,e: Int64
            public init(_ seed: Int64) { a=seed; b=seed+1; c=seed+2; d=seed+3; e=seed+4 }
            @inline(never) public func sum(_ delta: Int64) -> Int64 { a+b+c+d+e+delta }
            @inline(never) public consuming func consume(_ delta: Int64) -> Int64 { a+b+c+d+e+delta }
            @inline(never) public func payload(_ delta: Int64) -> ReplacementPayload { ReplacementPayload(a+delta) }
        }
        """, callerExtra: """
        @inline(never) public func wideSum(_ seed: Int64, _ delta: Int64) -> Int64 { WideValue(seed).sum(delta) }
        @inline(never) public func wideConsume(_ seed: Int64, _ delta: Int64) -> Int64 { WideValue(seed).consume(delta) }
        @inline(never) public func widePayload(_ seed: Int64, _ delta: Int64) -> Int64 { WideValue(seed).payload(delta).checksum }
        """); defer { fixture.cleanup() }
        let type = try await fixture.runtime.swiftType(named: fixture.module + ".WideValue", as: SwiftABIFive.self, in: fixture.providerScope)
        for (member, caller, consuming) in [("sum", "wideSum", false), ("consume", "wideConsume", true)] {
            let method = try await type.method(named: member + "(_:)", as: ((Int64) -> Int64).self, consuming: consuming)
            let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + "." + caller + "(_:_:)", as: ((Int64, Int64) -> Int64).self, in: fixture.callerScope)
            let hook = try await unsafe method.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
                let receiver = try call.receiver(as: SwiftABIFive.self)
                #expect(receiver.a == 40 && receiver.e == 44)
                _ = try call.proceed(value + 1)
                return try call.proceed(value + 2) + 100
            }
            #expect(try unsafe oracle.unsafeInvoke(40, 2) == 314)
            hook.invalidate()
            #expect(try unsafe oracle.unsafeInvoke(40, 2) == 212)
        }
        let method = try await type.method(named: "payload(Swift.Int64) -> " + fixture.module + ".ReplacementPayload", as: ((Int64) -> SwiftABIFive).self)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".widePayload(_:_:)", as: ((Int64, Int64) -> Int64).self, in: fixture.callerScope)
        let hook = try await unsafe method.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            var result = try call.proceed(value + 1)
            result.a += 100
            return result
        }
        defer { hook.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(40, 2) == 325)
    }

    @Test func registerPassedSelfIsSeparateFromExplicitArguments() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let type = try await fixture.runtime.swiftType(named: fixture.module + ".ReplacementValue", as: Int64.self, in: fixture.providerScope)
        let method = try await type.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedValueMethod(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let hook = try await unsafe method.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            #expect(try call.receiver(as: Int64.self) == 40)
            let result = try call.proceed(value + 1)
            #expect(try call.receiver(as: Int64.self) == 40)
            return result + 100
        }
        defer { hook.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(2) == 143)
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(2) == 42)
    }

    @Test func trailingSelfSurvivesStackArgumentsAndExpiredViews() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        extension ReplacementValue {
            @inline(never) public func stack(_ a: Int64, _ b: Int64, _ c: Int64, _ d: Int64, _ e: Int64, _ f: Int64, _ g: Int64, _ h: Int64, _ i: Int64, _ j: Int64, _ k: Int64, _ l: Int64) -> Int64 { seed+a+b+c+d+e+f+g+h+i+j+k+l }
        }
        """, callerExtra: """
        @inline(never) public func stackedValue() -> Int64 { ReplacementValue(40).stack(1,2,3,4,5,6,7,8,9,10,11,12) }
        """); defer { fixture.cleanup() }
        let type = try await fixture.runtime.swiftType(named: fixture.module + ".ReplacementValue", as: Int64.self, in: fixture.providerScope)
        let method = try await type.method(named: "stack(_:_:_:_:_:_:_:_:_:_:_:_:)",
            as: ((Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) -> Int64).self)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".stackedValue()", as: (() -> Int64).self, in: fixture.callerScope)
        let hook = try await unsafe method.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call,a,b,c,d,e,f,g,h,i,j,k,l in
            #expect(try call.receiver(as: Int64.self) == 40)
            return try call.proceed(a+1,b,c,d,e,f,g,h,i,j,k,l+100)
        }
        defer { hook.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke() == 219)
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke() == 118)

        let scalar = try await type.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
        let scalarCaller = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedValueMethod(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let saved = SavedValueInvocation()
        let captured = try await unsafe scalar.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            saved.value = call
            return try call.proceed(value)
        }
        defer { captured.invalidate() }
        #expect(try unsafe scalarCaller.unsafeInvoke(2) == 42)
        let expired = try #require(saved.value)
        #expect(throws: NativeSwiftHookInvocationError.expiredInvocation) { try expired.receiver(as: Int64.self) }
    }

    @Test func mutatingSelfUsesTheCallersAddressAndPreservesEffectsOnFailure() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        public struct CounterValue {
            public var count: Int64
            public init(_ count: Int64) { self.count = count }
            @inline(never) public mutating func increment(_ delta: Int64) -> Int64 { count += delta; return count }
        }
        """, callerExtra: """
        @inline(never) public func incrementValue(_ seed: Int64, _ delta: Int64) -> Int64 {
            var value = CounterValue(seed)
            let result = value.increment(delta)
            return value.count * 1000 + result
        }
        """); defer { fixture.cleanup() }
        let type = try await fixture.runtime.swiftType(named: fixture.module + ".CounterValue", as: Int64.self, in: fixture.providerScope)
        let method = try await type.method(named: "increment(_:)", as: ((Int64) -> Int64).self, mutating: true)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".incrementValue(_:_:)", as: ((Int64, Int64) -> Int64).self, in: fixture.callerScope)
        let failures = Mutex<[String]>([])
        let hook = try await unsafe method.hookImportedCalls(in: fixture.callerScope, onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, delta in
            let before = try call.receiver(as: Int64.self)
            let result = try call.proceed(delta + 1)
            #expect(try call.receiver(as: Int64.self) == before + delta + 1)
            if delta == 3 { throw SwiftValueHookFailure.afterProceed }
            return result + 100
        }
        defer { hook.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(40, 2) == 43143)
        #expect(try unsafe oracle.unsafeInvoke(40, 3) == 44044)
        #expect(failures.withLock { $0 } == ["afterProceed"])
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(40, 2) == 42042)
    }

    @Test func consumingManagedValueSelfIsCopiedForEachContinuation() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        public struct TextValue {
            public var text: String
            public init(_ text: String) { self.text = text }
            @inline(never) public consuming func consume() -> String { "value:" + text }
        }
        """, callerExtra: """
        @inline(never) public func consumeTextValue(_ text: String) -> String { TextValue(text).consume() }
        """); defer { fixture.cleanup() }
        // A one-field String wrapper has String's established native storage and
        // ownership. This does not synthesize a general nontrivial struct adapter.
        let type = try await fixture.runtime.swiftType(named: fixture.module + ".TextValue", as: String.self, in: fixture.providerScope)
        let method = try await type.method(named: "consume()", as: (() -> String).self, consuming: true)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".consumeTextValue(_:)", as: ((String) -> String).self, in: fixture.callerScope)
        let hook = try await unsafe method.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call in
            let value = try call.receiver(as: String.self)
            if value == "skip" { return "skipped" }
            _ = try call.proceed()
            let result = try call.proceed()
            #expect(try call.receiver(as: String.self) == value)
            return result + " edited"
        }
        defer { hook.invalidate() }
        let text = String(repeating: "owned receiver", count: 100)
        for _ in 0..<20 { #expect(try unsafe oracle.unsafeInvoke(text) == "value:" + text + " edited") }
        #expect(try unsafe oracle.unsafeInvoke("skip") == "skipped")
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(text) == "value:" + text)
    }

    @Test func mutatingStringSnapshotsObserveNativeWriteback() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        public struct MutableTextValue {
            public var text: String
            public init(_ text: String) { self.text = text }
            @inline(never) public mutating func append(_ suffix: String) -> String { text += suffix; return text }
        }
        """, callerExtra: """
        @inline(never) public func appendTextValue(_ input: String, _ suffix: String) -> String {
            var value = MutableTextValue(input)
            let result = value.append(suffix)
            return result + "|" + value.text
        }
        """); defer { fixture.cleanup() }
        let type = try await fixture.runtime.swiftType(named: fixture.module + ".MutableTextValue", as: String.self, in: fixture.providerScope)
        let method = try await type.method(named: "append(_:)", as: ((String) -> String).self, mutating: true)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".appendTextValue(_:_:)", as: ((String, String) -> String).self, in: fixture.callerScope)
        let hook = try await unsafe method.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, suffix in
            let before = try call.receiver(as: String.self)
            let result = try call.proceed(suffix + " edited")
            #expect(try call.receiver(as: String.self) == before + suffix + " edited")
            return result + " returned"
        }
        defer { hook.invalidate() }
        let input = String(repeating: "mutable receiver", count: 100)
        for _ in 0..<20 {
            #expect(try unsafe oracle.unsafeInvoke(input, " suffix") == input + " suffix edited returned|" + input + " suffix edited")
        }
    }

    @Test func consumingReferenceFieldReleasesUnusedIncomingOwnership() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        public final class ValueToken { public init() {} }
        public struct ReferenceValue {
            public let token: ValueToken
            public init(_ token: ValueToken) { self.token = token }
            @inline(never) public consuming func consume(_ value: Int64) -> Int64 { withExtendedLifetime(token) {}; return value+1 }
        }
        @inline(never) public func makeValueToken() -> ValueToken { ValueToken() }
        """, callerExtra: """
        @inline(never) public func consumeReferenceValue(_ token: ValueToken, _ value: Int64) -> Int64 { ReferenceValue(token).consume(value) }
        """); defer { fixture.cleanup() }
        let name = fixture.module + ".ValueToken"
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeValueToken() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        var object: AnyObject? = try unsafe make.unsafeInvoke()
        weak var observed = object
        let identity = ObjectIdentifier(object!)
        let type = try await fixture.runtime.swiftType(named: fixture.module + ".ReferenceValue", as: AnyObject.self, in: fixture.providerScope)
        let method = try await type.method(named: "consume(_:)", as: ((Int64) -> Int64).self, consuming: true)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".consumeReferenceValue(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self, in: fixture.callerScope)
        let hook = try await unsafe method.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            #expect(ObjectIdentifier(try call.receiver(as: AnyObject.self)) == identity)
            if value == 0 { return 1000 }
            _ = try call.proceed(value + 1)
            return try call.proceed(value + 2)
        }
        defer { hook.invalidate() }
        for _ in 0..<20 {
            #expect(try unsafe oracle.unsafeInvoke(object!, 0) == 1000)
            #expect(try unsafe oracle.unsafeInvoke(object!, 40) == 43)
        }
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(object!, 40) == 41)
        object = nil
        #expect(observed == nil)
    }

    @Test func nonmutatingSetterConsumesOnlyItsExplicitArgument() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        public final class ValueBox { public var text: String = "initial"; public init() {} }
        public struct BoxValue {
            public let box: ValueBox
            public init(_ box: ValueBox) { self.box = box }
            public var text: String {
                get { box.text }
                nonmutating set { box.text = newValue }
            }
        }
        @inline(never) public func makeValueBox() -> ValueBox { ValueBox() }
        """, callerExtra: """
        @inline(never) public func setBoxValue(_ box: ValueBox, _ text: String) -> String {
            let value = BoxValue(box); value.text = text; return value.text
        }
        """); defer { fixture.cleanup() }
        let name = fixture.module + ".ValueBox"
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeValueBox() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        var object: AnyObject? = try unsafe make.unsafeInvoke()
        weak var observed = object
        let type = try await fixture.runtime.swiftType(named: fixture.module + ".BoxValue", as: AnyObject.self, in: fixture.providerScope)
        let setter = try await type.setter(named: "text", as: String.self, mutating: false)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".setBoxValue(\(name), Swift.String) -> Swift.String",
            as: ((AnyObject, String) -> String).self, in: fixture.callerScope)
        let hook = try await unsafe setter.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            _ = try call.receiver(as: AnyObject.self)
            try call.proceed(value + " edited")
        }
        defer { hook.invalidate() }
        let text = String(repeating: "owned setter", count: 100)
        for _ in 0..<20 { #expect(try unsafe oracle.unsafeInvoke(object!, text) == text + " edited") }
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(object!, text) == text)
        object = nil
        #expect(observed == nil)
    }
}
private enum SwiftValueHookFailure: Error { case afterProceed }
private final class SavedValueInvocation: @unchecked Sendable {
    var value: NativeSwiftMethodInvocation<(Int64) -> Int64>?
}
#endif
