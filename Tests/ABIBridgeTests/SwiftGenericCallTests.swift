import ABIBridge
import Foundation
import ManagedSwiftFixtures
import Synchronization
import Testing

extension GenericElementStorage: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        if Values.Element.self == Int64.self { return .int64 }
        if Values.Element.self == [String].self { return .pointer }
        return try! .opaque(named: "GenericElementStorage")
    }
}

private struct GenericConstraintValue: GenericNotAnyObject, ABIBridgeSwiftValue, Equatable {
    let text: String
    static var swiftABIType: NativeType { try! .opaque(named: "GenericConstraintValue") }
}

private enum GenericConversionFailure: Error { case rejected }
private struct RejectGenericArgument: ABIBridgeValue {
    static var abiType: NativeType { .int64 }
    init() {}
    init(nativeValue: NativeValue) throws { throw GenericConversionFailure.rejected }
    static func nativeValue(from value: Self) throws -> NativeValue { throw GenericConversionFailure.rejected }
}

private struct GenericPointerWrapper: ABIBridgeValue, Equatable {
    let pointer: UnsafeRawPointer
    let marker: Int64
    static var abiType: NativeType { .pointer }
    init(pointer: UnsafeRawPointer, marker: Int64) { self.pointer = pointer; self.marker = marker }
    init(nativeValue: NativeValue) throws { throw GenericConversionFailure.rejected }
    static func nativeValue(from value: Self) throws -> NativeValue { throw GenericConversionFailure.rejected }
}

private final class GenericCapture: Sendable {
    let state: GenericCaptureState
    init(_ state: GenericCaptureState) { self.state = state }
    deinit { state.deaths.withLock { $0 += 1 } }
    func value() -> String { state.calls.withLock { $0 += 1 }; return String(repeating: "capture", count: 100) }
}
private final class GenericCaptureState: Sendable {
    let calls = Mutex(0)
    let deaths = Mutex(0)
}

@Suite(.serialized)
struct SwiftGenericCallTests {
    @Test func labelOnlyFreeFunctionsBindTheirNativeDeclarations() async throws {
        let runtime = ABIRuntime()
        let name = "ManagedSwiftFixtures.labelLookupGeneric(_:)"
        let scalar = try await runtime.swiftFunction(named: name, as: ((Int64) -> Int64).self,
            genericArguments: [.type(Int64.self)])
        let array = try await runtime.swiftFunction(named: name, as: (([Int64]) -> Int64).self,
            genericArguments: [.type(Int64.self)])
        #expect(try unsafe scalar.unsafeInvoke(42) == labelLookupGeneric(Int64(42)))
        #expect(try unsafe array.unsafeInvoke([35, 7]) == labelLookupGeneric([Int64(35), 7]))
        let retainedImage = try await runtime.swiftFunction(named: name, as: (([Int64]) -> Int64).self,
            genericArguments: [.type(Int64.self)], in: array.symbol.image)
        #expect(try unsafe retainedImage.unsafeInvoke([35, 7]) == labelLookupGeneric([Int64(35), 7]))

        typealias Callback = NativeSwiftClosure<(Int64) -> Int64>
        typealias Caller = NativeSwiftClosure<(Callback, Int64) -> Int64>
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeConcreteNestedCaller()",
            as: (() -> Caller).self)
        let apply = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.callNestedRuntimeCaller(_:_:)",
            as: ((Caller, Int64) -> Int64).self, genericArguments: [.type(Int64.self)])
        #expect(try unsafe apply.unsafeInvoke(make.unsafeInvoke(), 42)
            == callNestedRuntimeCaller(makeConcreteNestedCaller(), Int64(42)))
    }

    @Test func labelOnlyValueABIsUseTheProviderTypes() async throws {
        let runtime = ABIRuntime()
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.RuntimeFixedPair")
        let abi = try NativeType.structure(named: type.name, fields: [.int64, .int64])
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeRuntimeFixedPair(_:_:)",
            as: ((Int64, Int64) -> NativeSwiftValue).self, valueABIs: [type: abi])
        let retainedImage = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeRuntimeFixedPair(_:_:)",
            as: ((Int64, Int64) -> NativeSwiftValue).self, valueABIs: [type: abi], in: type.image)
        for value in [try unsafe make.unsafeInvoke(35, 7), try unsafe retainedImage.unsafeInvoke(35, 7)] {
            #expect(try value.take(as: RuntimeFixedPair.self).sum() == makeRuntimeFixedPair(35, 7).sum())
        }
    }

    @Test func labelBindingPreservesAmbiguityAndCompleteSignatureSelection() async throws {
        let runtime = ABIRuntime()
        let name = "ManagedSwiftFixtures.ambiguousLookupGeneric(_:)"
        for clearCache in [false, true] {
            if clearCache { await runtime.removeCachedResults() }
            do {
                _ = try await runtime.swiftFunction(named: name, as: ((Int64) -> Int64).self,
                    genericArguments: [.type(Int64.self)])
                Issue.record("Two applicable generic declarations must remain ambiguous")
            } catch let ABIResolutionError.ambiguousDeclaration(_, candidates) { #expect(candidates.count == 2) }
        }
        for constraint in ["Equatable", "CustomStringConvertible"] {
            let selected = try await runtime.swiftFunction(
                named: "ManagedSwiftFixtures.ambiguousLookupGeneric<A where A: Swift." + constraint + ">(A) -> Swift.Int64",
                as: ((Int64) -> Int64).self, genericArguments: [.type(Int64.self)])
            let expected = constraint == "Equatable" ? referenceEquatableLookup(Int64(42)) : referenceDescriptionLookup(Int64(42))
            #expect(try unsafe selected.unsafeInvoke(42) == expected)
        }
    }

    @MainActor @Test func packsReabstractClosuresAndCleanUpAfterLaterFailures() async throws {
        typealias TextBody = NativeSwiftClosure<() -> String>
        typealias NumberBody = NativeSwiftClosure<() -> Int64>
        let runtime = ABIRuntime()
        let invoke = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.closurePackGeneric<each A>(repeat () -> A) -> (repeat A)",
            as: ((TextBody, NumberBody) -> (String, Int64)).self,
            genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
        let failEncoding = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.closurePackThenArgumentGeneric<each A>(_: repeat () -> A, after: Swift.Int64) -> (repeat A)",
            as: ((TextBody, NumberBody, RejectGenericArgument) -> (String, Int64)).self,
            genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
        let wrapperIdentity = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.packGeneric<each A>(repeat A) -> (repeat A)",
            as: ((TextBody) -> TextBody).self, genericArguments: [.pack([.type(TextBody.self)])])
        let state = GenericCaptureState()
        do {
            let capture = GenericCapture(state)
            let first = try TextBody { capture.value() }
            let second = try NumberBody { _ = capture; return 42 }
            let result = try unsafe invoke.unsafeInvoke(first, second)
            #expect(result == (String(repeating: "capture", count: 100), 42))
            let unchanged = try unsafe wrapperIdentity.unsafeInvoke(first)
            #expect(try unsafe unchanged.unsafeInvoke() == String(repeating: "capture", count: 100))
            do {
                _ = try unsafe failEncoding.unsafeInvoke(first, second, RejectGenericArgument())
                Issue.record("Expected encoding to fail after preparing the pack closures")
            } catch GenericConversionFailure.rejected {}
            #expect(try unsafe first.unsafeInvoke() == String(repeating: "capture", count: 100))
            #expect(state.deaths.withLock { $0 } == 0)
        }
        #expect(state.deaths.withLock { $0 } == 1)
        let empty = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.closurePackGeneric<each A>(repeat () -> A) -> (repeat A)",
            as: (() -> Void).self, genericArguments: [.pack([])])
        try unsafe empty.unsafeInvoke()
    }

    @MainActor @Test func ownedPackClosuresKeepIndependentNativeCaptures() async throws {
        typealias Owner = GenericClosurePackOwner<String, Int64>
        let runtime = ABIRuntime()
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericClosurePackOwner",
            genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
        let initialize = try await type.initializer(
            named: "init(_:)",
            as: ((NativeSwiftConsuming<NativeSwiftClosure<() -> String>>, NativeSwiftClosure<() -> Int64>) -> Owner).self)
        let call = try await type.method(named: "call()", as: (() -> (String, Int64)).self)
        let apply = try await type.method(named: "apply(_:)",
            as: ((NativeSwiftBorrowing<NativeSwiftClosure<() -> String>>, NativeSwiftClosure<() -> Int64>) -> (String, Int64)).self)
        let state = GenericCaptureState()
        var owner: Owner?
        do {
            let capture = GenericCapture(state)
            let first = try NativeSwiftClosure<() -> String> { capture.value() }
            let second = try NativeSwiftClosure<() -> Int64> { _ = capture; return 42 }
            owner = try unsafe initialize.unsafeInvoke(.init(first), second)
        }
        #expect(state.deaths.withLock { $0 } == 0)
        let result = try unsafe call.unsafeInvoke(on: owner!)
        #expect(result == (String(repeating: "capture", count: 100), 42))
        let applied = try unsafe apply.unsafeInvoke(on: owner!, .init(NativeSwiftClosure<() -> String> { "arguments" }),
            NativeSwiftClosure<() -> Int64> { 43 })
        #expect(applied == ("arguments", 43))
        owner = nil
        #expect(state.deaths.withLock { $0 } == 1)
    }

    @MainActor @Test func packClosuresPreserveAsyncAndTypedErrorConventions() async throws {
        let runtime = ABIRuntime()
        typealias AsyncText = NativeSwiftClosure<() async -> String>
        typealias AsyncNumber = NativeSwiftClosure<() async -> Int64>
        let asyncCall = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.asyncClosurePackGeneric<each A>(repeat nonisolated(nonsending) () async -> A) async -> (repeat A)",
            as: ((AsyncText, AsyncNumber) async -> (String, Int64)).self,
            genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
        let text: @Sendable () async -> String = { await Task.yield(); return "async pack" }
        let number: @Sendable () async -> Int64 = { await Task.yield(); return 42 }
        let result = try unsafe await asyncCall.unsafeInvoke(AsyncText(text), AsyncNumber(number))
        #expect(result == ("async pack", 42))
        typealias ObjectBody = NativeSwiftClosure<() throws(GenericGetterFailure) -> GenericCapture>
        typealias FailingBody = NativeSwiftClosure<() throws(GenericGetterFailure) -> Int64>
        let throwingCall = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.throwingClosurePackGeneric<A, B where A: Swift.Error>(repeat () throws(A) -> B) throws(A) -> (repeat B)",
            as: ((ObjectBody, FailingBody) throws(GenericGetterFailure) -> (GenericCapture, Int64)).self,
            genericArguments: [.type(GenericGetterFailure.self), .pack([.type(GenericCapture.self), .type(Int64.self)])])
        let state = GenericCaptureState()
        do {
            let capture = GenericCapture(state)
            let first = try ObjectBody { capture }
            let second = try FailingBody { () throws(GenericGetterFailure) in throw GenericGetterFailure(43) }
            do {
                _ = try unsafe throwingCall.unsafeInvoke(first, second)
                Issue.record("Expected the second pack closure's native error")
            } catch let error as NativeSwiftError {
                #expect(error.withUnderlyingError { ($0 as? GenericGetterFailure)?.code == 43 })
            }
        }
        #expect(state.deaths.withLock { $0 } == 1)
    }

    @Test func protocolNameSuffixDoesNotChangeGenericValueConvention() async throws {
        let method = try await ABIRuntime().swiftFunction(
            named: "ManagedSwiftFixtures.similarlyNamedConstraintGeneric<A where A: ManagedSwiftFixtures.GenericNotAnyObject>(A) -> A",
            as: ((GenericConstraintValue) -> GenericConstraintValue).self,
            genericArguments: [.type(GenericConstraintValue.self)])
        let value = GenericConstraintValue(text: String(repeating: "indirect", count: 100))
        #expect(try unsafe method.unsafeInvoke(value) == similarlyNamedConstraintGeneric(value))
    }

    @MainActor @Test func ownershipWrappersPreserveGenericClosureEncoding() async throws {
        let runtime = ABIRuntime()
        let borrowed = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftBorrowing<NativeSwiftClosure<() -> String>>) -> String).self,
            genericArguments: [.type(String.self)])
        let consumed = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.consumeClosureGeneric<A, B where B: Swift.Error>(__owned () -> A, B, Swift.Bool) throws(B) -> A",
            as: ((NativeSwiftConsuming<NativeSwiftClosure<() -> String>>, GenericConversionFailure, Bool) throws(GenericConversionFailure) -> String).self,
            genericArguments: [.type(String.self), .type(GenericConversionFailure.self)])
        let encodingFailure = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.consumeClosureThenArgumentGeneric<A>(__owned () -> A, Swift.Int64) -> A",
            as: ((NativeSwiftConsuming<NativeSwiftClosure<() -> String>>, RejectGenericArgument) -> String).self,
            genericArguments: [.type(String.self)])
        let state = GenericCaptureState()
        do {
            let capture = GenericCapture(state)
            let body = try NativeSwiftClosure<() -> String> { capture.value() }
            #expect(try unsafe borrowed.unsafeInvoke(.init(body)) == String(repeating: "capture", count: 100))
            #expect(try unsafe consumed.unsafeInvoke(.init(body), .rejected, false) == String(repeating: "capture", count: 100))
            do {
                _ = try unsafe consumed.unsafeInvoke(.init(body), .rejected, true)
                Issue.record("Expected the consuming generic callback's native error")
            } catch let error as NativeSwiftError {
                #expect(error.withUnderlyingError { $0 is GenericConversionFailure })
            }
            do {
                _ = try unsafe encodingFailure.unsafeInvoke(.init(body), RejectGenericArgument())
                Issue.record("Expected argument encoding to fail before native invocation")
            } catch GenericConversionFailure.rejected {}
            #expect(try unsafe body.unsafeInvoke() == String(repeating: "capture", count: 100))
            #expect(state.calls.withLock { $0 } == 3)
            #expect(state.deaths.withLock { $0 } == 0)
        }
        #expect(state.deaths.withLock { $0 } == 1)
        typealias AsyncBody = NativeSwiftClosure<() async throws(GenericGetterFailure) -> Int64>
        let asynchronous = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedGenericErrorCallback<A where A: Swift.Error>(nonisolated(nonsending) () async throws(A) -> Swift.Int64) async throws(A) -> Swift.Int64",
            as: ((NativeSwiftBorrowing<AsyncBody>) async throws(GenericGetterFailure) -> Int64).self,
            genericArguments: [.type(GenericGetterFailure.self)])
        for shouldThrow in [false, true] {
            let operation: @Sendable () async throws(GenericGetterFailure) -> Int64 = { () async throws(GenericGetterFailure) in
                await Task.yield()
                if shouldThrow { throw GenericGetterFailure(42) }
                return 42
            }
            let body = try AsyncBody(operation)
            do {
                #expect(try unsafe await asynchronous.unsafeInvoke(.init(body)) == 42)
                #expect(!shouldThrow)
            } catch let error as NativeSwiftError {
                #expect(shouldThrow && error.withUnderlyingError { $0 is GenericGetterFailure })
            }
        }
    }

    @Test func inoutClosuresDistinguishNativeGenericStorageFromConvertedFunctions() async throws {
        typealias Closure = NativeSwiftClosure<() -> String>
        let runtime = ABIRuntime()
        do {
            _ = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.replaceClosureGeneric<A>(inout () -> A, A) -> ()",
                as: ((NativeSwiftInout<Closure>, String) -> Void).self, genericArguments: [.type(String.self)])
            Issue.record("An inout function cannot expose the converted wrapper's storage as a native closure pair")
        } catch ABIResolutionError.unsupportedDeclaration {}
        let replace = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.mutateGeneric<A, B where B: Swift.Error>(inout A, __owned A, B, Swift.Bool) throws(B) -> ()",
            as: ((NativeSwiftInout<Closure>, NativeSwiftConsuming<Closure>, GenericGetterFailure, Bool) throws(GenericGetterFailure) -> Void).self,
            genericArguments: [.type(Closure.self), .type(GenericGetterFailure.self)])
        let value = NativeSwiftInout(try Closure { "original" })
        try unsafe replace.unsafeInvoke(value, .init(Closure { "updated" }), GenericGetterFailure(1), false)
        #expect(try unsafe value.value.unsafeInvoke() == "updated")
    }

    @Test func genericClosureInitializersAndSettersTransferIndependentCaptures() async throws {
        let type = try await ABIRuntime().swiftType(named: "ManagedSwiftFixtures.GenericClosureOwner",
            genericArguments: [.type(String.self)])
        let initialize = try await type.initializer(named: "init(_:)",
            as: ((NativeSwiftClosure<() -> String>) -> GenericClosureOwner<String>).self)
        let set = try await type.setter(named: "body", as: NativeSwiftClosure<() -> String>.self)
        let explicitlyOwnedSet = try await type.setter(named: "body", as: NativeSwiftConsuming<NativeSwiftClosure<() -> String>>.self)
        let first = GenericCaptureState(), second = GenericCaptureState(), third = GenericCaptureState()
        var object: GenericClosureOwner<String>?
        do {
            let capture = GenericCapture(first)
            object = try unsafe initialize.unsafeInvoke(NativeSwiftClosure<() -> String> { capture.value() })
        }
        #expect(first.deaths.withLock { $0 } == 0)
        #expect(object!.run() == String(repeating: "capture", count: 100))
        do {
            let capture = GenericCapture(second)
            try unsafe set.unsafeInvoke(on: object!, NativeSwiftClosure<() -> String> { capture.value() })
        }
        #expect(first.deaths.withLock { $0 } == 1)
        #expect(second.deaths.withLock { $0 } == 0)
        #expect(object!.run() == String(repeating: "capture", count: 100))
        do {
            let capture = GenericCapture(third)
            try unsafe explicitlyOwnedSet.unsafeInvoke(on: object!, .init(NativeSwiftClosure<() -> String> { capture.value() }))
        }
        #expect(second.deaths.withLock { $0 } == 1)
        #expect(third.deaths.withLock { $0 } == 0)
        #expect(object!.run() == String(repeating: "capture", count: 100))
        object = nil
        #expect(third.deaths.withLock { $0 } == 1)
    }

    @MainActor @Test func classResultsUseTheExistingAnyObjectRepresentation() async throws {
        let runtime = ABIRuntime()
        let object = NSObject()
        let echo = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
            as: ((NSObject) -> AnyObject).self, genericArguments: [.type(NSObject.self)])
        #expect(try unsafe echo.unsafeInvoke(object) === object)
        let optional = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.optionalGeneric<A>(A?) -> A?",
            as: ((NSObject?) -> AnyObject?).self, genericArguments: [.type(NSObject.self)])
        #expect(try unsafe optional.unsafeInvoke(object) === object)
        #expect(try unsafe optional.unsafeInvoke(nil) == nil)
    }

    @MainActor @Test func existentialAndProtocolMetatypesRoundTripWithGenericValues() async throws {
        let function = try await ABIRuntime().swiftFunction(
            named: "ManagedSwiftFixtures.existentialMetatypesGeneric<A>(Swift.CustomStringConvertible.Type, Swift.CustomStringConvertible.Protocol, A) -> (Swift.CustomStringConvertible.Type, Swift.CustomStringConvertible.Protocol, A)",
            as: ((any CustomStringConvertible.Type, (any CustomStringConvertible).Type, String)
                -> (any CustomStringConvertible.Type, (any CustomStringConvertible).Type, String)).self,
            genericArguments: [.type(String.self)])
        let result = try unsafe function.unsafeInvoke(Int64.self, (any CustomStringConvertible).self, "metadata")
        #expect(ObjectIdentifier(result.0) == ObjectIdentifier(Int64.self))
        #expect(result.1 == (any CustomStringConvertible).self)
        #expect(result.2 == "metadata")
    }

    @MainActor @Test func neverBoundErrorsPreserveTheFormalThrowingConvention() async throws {
        let runtime = ABIRuntime()
        let function = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.genericErrorType<A where A: Swift.Error>(A.Type) throws(A) -> Swift.Int64",
            as: ((Never.Type) -> Int64).self, genericArguments: [.type(Never.self)])
        #expect(try unsafe function.unsafeInvoke(Never.self) == 42)
        let asynchronous = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedGenericErrorType<A where A: Swift.Error>(A.Type) async throws(A) -> Swift.Int64",
            as: ((Never.Type) async -> Int64).self, genericArguments: [.type(Never.self)])
        #expect(try unsafe await asynchronous.unsafeInvoke(Never.self) == 44)
        let callback = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.genericErrorCallback<A where A: Swift.Error>(() throws(A) -> Swift.Int64) throws(A) -> Swift.Int64",
            as: ((NativeSwiftClosure<() -> Int64>) -> Int64).self, genericArguments: [.type(Never.self)])
        #expect(try unsafe callback.unsafeInvoke(NativeSwiftClosure<() -> Int64> { 46 }) == 46)
        let asyncCallback = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedGenericErrorCallback<A where A: Swift.Error>(nonisolated(nonsending) () async throws(A) -> Swift.Int64) async throws(A) -> Swift.Int64",
            as: ((NativeSwiftClosure<() async -> Int64>) async -> Int64).self, genericArguments: [.type(Never.self)])
        let asyncBody = try NativeSwiftClosure<() async -> Int64> { await Task.yield(); return 47 }
        #expect(try unsafe await asyncCallback.unsafeInvoke(asyncBody) == 47)
        let make = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.genericErrorClosure<A where A: Swift.Error>(A?) -> (Swift.Bool) throws(A) -> Swift.Int64",
            as: ((Never?) -> NativeSwiftClosure<(Bool) -> Int64>).self, genericArguments: [.type(Never.self)])
        let closure = try unsafe make.unsafeInvoke(nil)
        #expect(try unsafe closure.unsafeInvoke(true) == 43)
        let makeAsync = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedGenericErrorClosure<A where A: Swift.Error>(A?) -> nonisolated(nonsending) @Sendable (Swift.Bool) async throws(A) -> Swift.Int64",
            as: ((Never?) -> NativeSwiftClosure<@Sendable (Bool) async -> Int64>).self, genericArguments: [.type(Never.self)])
        let asyncClosure = try unsafe makeAsync.unsafeInvoke(nil)
        #expect(try unsafe await asyncClosure.unsafeInvoke(true) == 45)
    }

    @MainActor @Test func existentialBoundErrorsUseTypedGenericOutputs() async throws {
        let runtime = ABIRuntime()
        let error: any Error = GenericConversionFailure.rejected
        let function = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.genericErrorType<A where A: Swift.Error>(A.Type) throws(A) -> Swift.Int64",
            as: (((any Error).Type) throws -> Int64).self, genericArguments: [.type((any Error).self)])
        #expect(try unsafe function.unsafeInvoke((any Error).self) == 42)
        let failure = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.genericFailure<A, B where B: Swift.Error>(A, B, Swift.Bool) throws(B) -> A",
            as: ((Int64, any Error, Bool) throws -> Int64).self,
            genericArguments: [.type(Int64.self), .type((any Error).self)])
        #expect(try unsafe failure.unsafeInvoke(41, error, false) == 41)
        do {
            _ = try unsafe failure.unsafeInvoke(41, error, true)
            Issue.record("Expected the generic error.")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? GenericConversionFailure) == .rejected })
        }
        let asyncFailure = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedGenericFailure<A, B where B: Swift.Error>(A, B, Swift.Bool) async throws(B) -> A",
            as: ((Int64, any Error, Bool) async throws -> Int64).self,
            genericArguments: [.type(Int64.self), .type((any Error).self)])
        #expect(try unsafe await asyncFailure.unsafeInvoke(42, error, false) == 42)
        do {
            _ = try unsafe await asyncFailure.unsafeInvoke(42, error, true)
            Issue.record("Expected the generic async error.")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? GenericConversionFailure) == .rejected })
        }
        let callback = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.genericErrorCallback<A where A: Swift.Error>(() throws(A) -> Swift.Int64) throws(A) -> Swift.Int64",
            as: ((NativeSwiftClosure<() throws -> Int64>) throws -> Int64).self,
            genericArguments: [.type((any Error).self)])
        for shouldThrow in [false, true] {
            let body = try NativeSwiftClosure<() throws -> Int64> { if shouldThrow { throw error }; return 46 }
            do {
                #expect(try unsafe callback.unsafeInvoke(body) == 46)
                #expect(!shouldThrow)
            } catch let error as NativeSwiftError {
                #expect(shouldThrow)
                #expect(error.withUnderlyingError { ($0 as? GenericConversionFailure) == .rejected })
            }
        }
        let asyncCallback = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedGenericErrorCallback<A where A: Swift.Error>(nonisolated(nonsending) () async throws(A) -> Swift.Int64) async throws(A) -> Swift.Int64",
            as: ((NativeSwiftClosure<() async throws -> Int64>) async throws -> Int64).self,
            genericArguments: [.type((any Error).self)])
        for shouldThrow in [false, true] {
            let operation: @Sendable () async throws -> Int64 = {
                await Task.yield()
                if shouldThrow { throw error }
                return 47
            }
            let body = try NativeSwiftClosure<() async throws -> Int64>(operation)
            do {
                #expect(try unsafe await asyncCallback.unsafeInvoke(body) == 47)
                #expect(!shouldThrow)
            } catch let error as NativeSwiftError {
                #expect(shouldThrow)
                #expect(error.withUnderlyingError { ($0 as? GenericConversionFailure) == .rejected })
            }
        }
        let make = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.genericErrorClosure<A where A: Swift.Error>(A?) -> (Swift.Bool) throws(A) -> Swift.Int64",
            as: (((any Error)?) -> NativeSwiftClosure<(Bool) throws -> Int64>).self,
            genericArguments: [.type((any Error).self)])
        let closure = try unsafe make.unsafeInvoke(error)
        #expect(try unsafe closure.unsafeInvoke(false) == 43)
        do {
            _ = try unsafe closure.unsafeInvoke(true)
            Issue.record("Expected the returned closure's error.")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? GenericConversionFailure) == .rejected })
        }
        let makeAsync = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedGenericErrorClosure<A where A: Swift.Error>(A?) -> nonisolated(nonsending) @Sendable (Swift.Bool) async throws(A) -> Swift.Int64",
            as: (((any Error)?) -> NativeSwiftClosure<@Sendable (Bool) async throws -> Int64>).self,
            genericArguments: [.type((any Error).self)])
        let asyncClosure = try unsafe makeAsync.unsafeInvoke(error)
        #expect(try unsafe await asyncClosure.unsafeInvoke(false) == 45)
        do {
            _ = try unsafe await asyncClosure.unsafeInvoke(true)
            Issue.record("Expected the returned async closure's error.")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? GenericConversionFailure) == .rejected })
        }
    }
    @Test func associatedElementStorageUsesItsFormalWitness() async throws {
        let runtime = ABIRuntime()
        let array = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.arrayElementGeneric<A>(ManagedSwiftFixtures.GenericElementStorage<[A]>) -> ManagedSwiftFixtures.GenericElementStorage<[A]>",
            as: ((GenericElementStorage<[Int64]>) -> GenericElementStorage<[Int64]>).self,
            genericArguments: [.type(Int64.self)])
        #expect(try unsafe array.unsafeInvoke(.init(42)).element == 42)
        let slice = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.sliceElementGeneric<A>(ManagedSwiftFixtures.GenericElementStorage<Swift.ArraySlice<A>>) -> ManagedSwiftFixtures.GenericElementStorage<Swift.ArraySlice<A>>",
            as: ((GenericElementStorage<ArraySlice<String>>) -> GenericElementStorage<ArraySlice<String>>).self,
            genericArguments: [.type(String.self)])
        let text = String(repeating: "associated", count: 100)
        #expect(try unsafe slice.unsafeInvoke(.init(text)).element == text)
        let nested = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.nestedElementGeneric<A>(ManagedSwiftFixtures.GenericElementStorage<[[A]]>) -> ManagedSwiftFixtures.GenericElementStorage<[[A]]>",
            as: ((GenericElementStorage<[[String]]>) -> GenericElementStorage<[[String]]>).self,
            genericArguments: [.type(String.self)])
        #expect(try unsafe nested.unsafeInvoke(.init([text, "value"])).element == [text, "value"])
        let fixed = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.fixedElementGeneric<A>(ManagedSwiftFixtures.GenericElementStorage<ManagedSwiftFixtures.GenericFixedCollection<A>>) -> ManagedSwiftFixtures.GenericElementStorage<ManagedSwiftFixtures.GenericFixedCollection<A>>",
            as: ((GenericElementStorage<GenericFixedCollection<String>>) -> GenericElementStorage<GenericFixedCollection<String>>).self,
            genericArguments: [.type(String.self)])
        #expect(try unsafe fixed.unsafeInvoke(.init(42)).element == 43)
        let constrained = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.constrainedElementGeneric<A where A: Swift.Collection, A.Element == Swift.Int64>(ManagedSwiftFixtures.GenericElementStorage<A>) -> ManagedSwiftFixtures.GenericElementStorage<A>",
            as: ((GenericElementStorage<[Int64]>) -> GenericElementStorage<[Int64]>).self,
            genericArguments: [.type([Int64].self)])
        #expect(try unsafe constrained.unsafeInvoke(.init(42)).element == 44)
    }
    @Test func genericConsumedCopiesReleaseOnSuccessErrorAndEncodingFailure() async throws {
        let runtime = ABIRuntime()
        let consume = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.consumeGenericFailure<A, B where B: Swift.Error>(__owned A, B, Swift.Bool) throws(B) -> ()",
            as: ((NativeSwiftConsuming<GenericCapture>, ScalarFailure, Bool) throws(ScalarFailure) -> Void).self,
            genericArguments: [.type(GenericCapture.self), .type(ScalarFailure.self)])
        let conversion = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.consumeThenArgumentGeneric<A>(__owned A, Swift.Int64) -> ()",
            as: ((NativeSwiftConsuming<GenericCapture>, RejectGenericArgument) -> Void).self,
            genericArguments: [.type(GenericCapture.self)])
        let state = GenericCaptureState()
        for fail in [false, true] {
            weak var observed: GenericCapture?
            do {
                let value = GenericCapture(state)
                observed = value
                do {
                    try unsafe consume.unsafeInvoke(.init(value), ScalarFailure(42), fail)
                    #expect(!fail)
                } catch let error as NativeSwiftError {
                    error.withUnderlyingError { #expect(fail && ($0 as? ScalarFailure)?.code == 42) }
                }
                #expect(observed === value)
            }
            #expect(observed == nil)
        }
        weak var observed: GenericCapture?
        do {
            let value = GenericCapture(state)
            observed = value
            #expect(throws: GenericConversionFailure.rejected) {
                try unsafe conversion.unsafeInvoke(.init(value), RejectGenericArgument())
            }
            #expect(observed === value)
        }
        #expect(observed == nil && state.deaths.withLock { $0 } == 3)
    }

    @Test func genericOwnershipPreservesRawStorageAndWritebackOnErrors() async throws {
        let runtime = ABIRuntime()
        let borrowed = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.borrowingGeneric<A>(A) -> A",
            as: ((NativeSwiftBorrowing<String>) -> String).self, genericArguments: [.type(String.self)])
        let owned = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.consumingGeneric<A>(__owned A) -> A",
            as: ((NativeSwiftConsuming<String>) -> String).self, genericArguments: [.type(String.self)])
        let text = String(repeating: "ownership", count: 100)
        #expect(try unsafe borrowed.unsafeInvoke(.init(text)) == text)
        #expect(try unsafe owned.unsafeInvoke(.init(text)) == text)
        let mutate = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.mutateGeneric<A, B where B: Swift.Error>(inout A, __owned A, B, Swift.Bool) throws(B) -> ()",
            as: ((NativeSwiftInout<GenericPointerWrapper>, NativeSwiftConsuming<GenericPointerWrapper>, ScalarFailure, Bool) throws(ScalarFailure) -> Void).self,
            genericArguments: [.type(GenericPointerWrapper.self), .type(ScalarFailure.self)])
        let pointer = UnsafeRawPointer(bitPattern: 0x1234)!
        let value = NativeSwiftInout(GenericPointerWrapper(pointer: pointer, marker: 1))
        for fail in [false, true] {
            let marker: Int64 = fail ? 3 : 2
            do {
                try unsafe mutate.unsafeInvoke(value, .init(.init(pointer: pointer, marker: marker)), ScalarFailure(42), fail)
                #expect(!fail)
            } catch let error as NativeSwiftError {
                error.withUnderlyingError { #expect(fail && ($0 as? ScalarFailure)?.code == 42) }
            }
            #expect(value.value.pointer == pointer && value.value.marker == marker)
        }
        let suspended = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedMutateGeneric<A, B where B: Swift.Error>(inout A, __owned A, B, Swift.Bool) async throws(B) -> ()",
            as: ((NativeSwiftInout<String>, NativeSwiftConsuming<String>, ScalarFailure, Bool) async throws(ScalarFailure) -> Void).self,
            genericArguments: [.type(String.self), .type(ScalarFailure.self)])
        let buffer = NativeSwiftInout("before")
        do {
            try unsafe await suspended.unsafeInvoke(buffer, .init(text), ScalarFailure(43), true)
            Issue.record("Expected the native typed error")
        } catch let error as NativeSwiftError {
            error.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 43) }
        }
        #expect(buffer.value == text)
        await #expect(throws: ABIResolutionError.self) {
            try await runtime.swiftFunction(named: "ManagedSwiftFixtures.consumingGeneric<A>(__owned A) -> A",
                as: ((NativeSwiftBorrowing<String>) -> String).self, genericArguments: [.type(String.self)])
        }
    }

    @Test func nominalPackSourcesMatchCompilerMetadataFulfillments() async throws {
        let runtime = ABIRuntime()
        let arguments: [NativeSwiftGenericArgument] = [.pack([.type(Int64.self), .type(String.self)])]
        let object = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.packClassSourceGeneric<each A where A: Swift.Equatable>(ManagedSwiftFixtures.GenericSourcePack<Pack{repeat A}>, repeat A) -> Swift.Int64",
            as: ((GenericSourcePack<Int64, String>, Int64, String) -> Int64).self, genericArguments: arguments)
        #expect(try unsafe object.unsafeInvoke(GenericSourcePack<Int64, String>(), Int64(1), "two") == 2)
        let metatype = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.packMetatypeSourceGeneric<each A where A: Swift.Equatable>(ManagedSwiftFixtures.GenericSourcePack<Pack{repeat A}>.Type, repeat A) -> Swift.Int64",
            as: ((GenericSourcePack<Int64, String>.Type, Int64, String) -> Int64).self, genericArguments: arguments)
        #expect(try unsafe metatype.unsafeInvoke(GenericSourcePack<Int64, String>.self, Int64(1), "two") == 2)
        let value = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.packValueMetatypeGeneric<each A where A: Swift.Equatable>(ManagedSwiftFixtures.GenericTypePack<Pack{repeat A}>.Type, repeat A) -> Swift.Int64",
            as: ((GenericTypePack<Int64, String>.Type, Int64, String) -> Int64).self, genericArguments: arguments)
        #expect(try unsafe value.unsafeInvoke(GenericTypePack<Int64, String>.self, Int64(1), "two") == 2)
        let prefixed = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.prefixedPackSourceGeneric<each A where A: Swift.Equatable>(ManagedSwiftFixtures.GenericSourcePack<Pack{Swift.Int64, repeat A}>, repeat A) -> Swift.Int64",
            as: ((GenericSourcePack<Int64, Int64, String>, Int64, String) -> Int64).self, genericArguments: arguments)
        #expect(try unsafe prefixed.unsafeInvoke(GenericSourcePack<Int64, Int64, String>(), Int64(1), "two") == 2)
        let arrays = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.arrayPackSourceGeneric<each A where A: Swift.Equatable>(ManagedSwiftFixtures.GenericSourcePack<Pack{repeat [A]}>, repeat A) -> Swift.Int64",
            as: ((GenericSourcePack<[Int64], [String]>, Int64, String) -> Int64).self, genericArguments: arguments)
        #expect(try unsafe arrays.unsafeInvoke(GenericSourcePack<[Int64], [String]>(), Int64(1), "two") == 2)
    }

    @Test func metatypesPreserveFormalAndConcreteCallingConventions() async throws {
        let runtime = ABIRuntime()
        let nominal = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.valueMetatypeGeneric<A>(ManagedSwiftFixtures.GenericMetatypeValue<A>.Type, Swift.Int64) -> (ManagedSwiftFixtures.GenericMetatypeValue<A>.Type, Swift.Int64)",
            as: ((GenericMetatypeValue<String>.Type, Int64) -> (GenericMetatypeValue<String>.Type, Int64)).self,
            genericArguments: [.type(String.self)])
        let result = try unsafe nominal.unsafeInvoke(GenericMetatypeValue<String>.self, Int64(40))
        #expect(result.0 == GenericMetatypeValue<String>.self && result.1 == 41)
        let archetype = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.archetypeMetatypeGeneric<A>(A.Type, Swift.Int64) -> (A.Type, Swift.Int64)",
            as: ((Int64.Type, Int64) -> (Int64.Type, Int64)).self, genericArguments: [.type(Int64.self)])
        let genericResult = try unsafe archetype.unsafeInvoke(Int64.self, Int64(40))
        #expect(genericResult.0 == Int64.self && genericResult.1 == 42)
        let concrete = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.concreteMetatype((Swift.Int64.Type, Swift.Int64)) -> (Swift.Int64.Type, Swift.Int64)",
            as: (((Int64.Type, Int64)) -> (Int64.Type, Int64)).self)
        let concreteResult = try unsafe concrete.unsafeInvoke((Int64.self, Int64(40)))
        #expect(concreteResult.0 == Int64.self && concreteResult.1 == 43)
        let optional = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.optionalMetatype(Swift.Int64.Type?) -> Swift.Int64.Type?",
            as: ((Int64.Type?) -> Int64.Type?).self)
        #expect(try unsafe optional.unsafeInvoke(Int64.self) == nil)
        #expect(try unsafe optional.unsafeInvoke(nil) == Int64.self)
        let tuple = try NativeSwiftClosure<((Int64.Type, Int64)) -> (Int64.Type, Int64)> { pair in
            #expect(pair.0 == Int64.self)
            return (pair.0, pair.1 + 4)
        }
        let tupleResult = try unsafe tuple.unsafeInvoke((Int64.self, Int64(40)))
        #expect(tupleResult.0 == Int64.self && tupleResult.1 == 44)
        let existential = try NativeSwiftClosure<(any CustomStringConvertible.Type) -> any CustomStringConvertible.Type> { $0 }
        #expect(try unsafe existential.unsafeInvoke(String.self) == String.self)
    }

    @Test func optionalMetatypesPreserveTagsAcrossTupleAndGenericResults() async throws {
        let runtime = ABIRuntime()
        let optional = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.optionalMetatypeGeneric<A>(A.Type?) -> A.Type?",
            as: ((Int64.Type?) -> Int64.Type?).self, genericArguments: [.type(Int64.self)])
        #expect(try unsafe optional.unsafeInvoke(Int64.self) == Int64.self)
        #expect(try unsafe optional.unsafeInvoke(nil) == nil)
        let tuple = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.optionalNominalMetatypeGeneric<A>(ManagedSwiftFixtures.GenericMetatypeValue<A>.Type?, A) -> (ManagedSwiftFixtures.GenericMetatypeValue<A>.Type?, Swift.Int8, A, Swift.Int8)",
            as: ((GenericMetatypeValue<String>.Type?, String) -> (GenericMetatypeValue<String>.Type?, Int8, String, Int8)).self,
            genericArguments: [.type(String.self)])
        let text = String(repeating: "optional", count: 100)
        for input: GenericMetatypeValue<String>.Type? in [nil, GenericMetatypeValue<String>.self] {
            let result = try unsafe tuple.unsafeInvoke(input, text)
            #expect(result.0 == (input == nil ? GenericMetatypeValue<String>.self : nil))
            #expect(result.1 == 13 && result.2 == text && result.3 == 14)
        }
        let indirect = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.metatypeAndValueGeneric<A>(A) -> (Swift.Int64.Type, A)",
            as: ((String) -> (Int64.Type, String)).self, genericArguments: [.type(String.self)])
        let result = try unsafe indirect.unsafeInvoke(text)
        #expect(result.0 == Int64.self && result.1 == text)
        let closure = try NativeSwiftClosure<(Int64.Type?) -> Int64.Type?> { $0 == nil ? Int64.self : nil }
        #expect(try unsafe closure.unsafeInvoke(nil) == Int64.self)
        #expect(try unsafe closure.unsafeInvoke(Int64.self) == nil)
        let tupleClosure = try NativeSwiftClosure<((Int64.Type?, Int8)) -> (Int64.Type?, Int8)> { ($0.0 == nil ? Int64.self : nil, $0.1 + 1) }
        let closureResult = try unsafe tupleClosure.unsafeInvoke((nil, Int8(40)))
        #expect(closureResult.0 == Int64.self && closureResult.1 == 41)
    }

    @Test func metatypeCallbacksReabstractBothDirectionsAndAsyncResults() async throws {
        let runtime = ABIRuntime()
        let closure = try NativeSwiftClosure<(Int64.Type) -> Int64.Type> { type in
            #expect(type == Int64.self)
            return type
        }
        let callback = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.callbackMetatypeGeneric<A>(A.Type, (A.Type) -> A.Type) -> A.Type",
            as: ((Int64.Type, NativeSwiftClosure<(Int64.Type) -> Int64.Type>) -> Int64.Type).self,
            genericArguments: [.type(Int64.self)])
        #expect(try unsafe callback.unsafeInvoke(Int64.self, closure) == Int64.self)
        let factory = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeMetatypeClosureGeneric<A>() -> (A.Type) -> A.Type",
            as: (() -> NativeSwiftClosure<(Int64.Type) -> Int64.Type>).self, genericArguments: [.type(Int64.self)])
        #expect(try unsafe factory.unsafeInvoke().unsafeInvoke(Int64.self) == Int64.self)
        let erasedResult = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> Int64.Type>) -> Int64.Type).self, genericArguments: [.type(Int64.Type.self)])
        #expect(try unsafe erasedResult.unsafeInvoke(NativeSwiftClosure<() -> Int64.Type> { Int64.self }) == Int64.self)
        let asyncBody: @Sendable (Int64.Type) async -> Int64.Type = { type in
            await Task.yield()
            #expect(type == Int64.self)
            return type
        }
        let asyncClosure = try NativeSwiftClosure<(Int64.Type) async -> Int64.Type>(asyncBody)
        let asyncCallback = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.callbackAsyncMetatypeGeneric<A>(A.Type, nonisolated(nonsending) (A.Type) async -> A.Type) async -> A.Type",
            as: ((Int64.Type, NativeSwiftClosure<(Int64.Type) async -> Int64.Type>) async -> Int64.Type).self,
            genericArguments: [.type(Int64.self)])
        #expect(try unsafe await asyncCallback.unsafeInvoke(Int64.self, asyncClosure) == Int64.self)
        let asyncFactory = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeAsyncMetatypeClosureGeneric<A>() -> nonisolated(nonsending) @Sendable (A.Type) async -> A.Type",
            as: (() -> NativeSwiftClosure<nonisolated(nonsending) @Sendable (Int64.Type) async -> Int64.Type>).self,
            genericArguments: [.type(Int64.self)])
        #expect(try unsafe await asyncFactory.unsafeInvoke().unsafeInvoke(Int64.self) == Int64.self)
    }

    @Test func explicitClassAndMetatypeArgumentsFulfillGenericRequirements() async throws {
        let runtime = ABIRuntime()
        let box = GenericSourceBox(GenericSourceValue(41))
        let mixed = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.classSourceGeneric<A, B where A: ManagedSwiftFixtures.GenericSourceChild>(ManagedSwiftFixtures.GenericSourceBox<A>, B) -> (Swift.Int64, B)",
            as: ((GenericSourceBox<GenericSourceValue>, String) -> (Int64, String)).self,
            genericArguments: [.type(GenericSourceValue.self), .type(String.self)])
        let text = String(repeating: "fulfilled", count: 100)
        let result = try unsafe mixed.unsafeInvoke(box, text)
        #expect(result.0 == 41 && result.1 == text)
        let tuple = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.tupleSourceGeneric<A where A: ManagedSwiftFixtures.GenericSourceChild>((ManagedSwiftFixtures.GenericSourceBox<A>, Swift.Int64)) -> Swift.Int64",
            as: (((GenericSourceBox<GenericSourceValue>, Int64)) -> Int64).self,
            genericArguments: [.type(GenericSourceValue.self)])
        #expect(try unsafe tuple.unsafeInvoke((box, Int64(9))) == 50)
        let metatype = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.metatypeSourceGeneric<A where A: ManagedSwiftFixtures.GenericSourceChild>(ManagedSwiftFixtures.GenericSourceBox<A>.Type) -> Swift.Int64",
            as: ((GenericSourceBox<GenericSourceValue>.Type) -> Int64).self,
            genericArguments: [.type(GenericSourceValue.self)])
        #expect(try unsafe metatype.unsafeInvoke(GenericSourceBox<GenericSourceValue>.self) == 72)
        let nested = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.nestedSourceGeneric<A>(ManagedSwiftFixtures.GenericSourceNested<[A]>) -> A",
            as: ((GenericSourceNested<[String]>) -> String).self, genericArguments: [.type(String.self)])
        #expect(try unsafe nested.unsafeInvoke(GenericSourceNested([text])) == text)
        let superclass = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.superclassSourceGeneric<A, B where A: ManagedSwiftFixtures.GenericSourceChild, B: ManagedSwiftFixtures.GenericSourceBox<A>>(B) -> Swift.Int64",
            as: ((GenericSourceLeaf) -> Int64).self,
            genericArguments: [.type(GenericSourceValue.self), .type(GenericSourceLeaf.self)])
        #expect(try unsafe superclass.unsafeInvoke(GenericSourceLeaf(GenericSourceValue(73))) == 73)
    }

    @Test func associatedClassObjectiveCAndSuperclassConstraintsUseClassConventions() async throws {
        let runtime = ABIRuntime()
        let associated = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.associatedObjectGeneric<A where A: ManagedSwiftFixtures.GenericObjectContainer>(A.Type, A.Item) -> A.Item",
            as: ((GenericObjectCarrier.Type, NSObject) -> NSObject).self,
            genericArguments: [.type(GenericObjectCarrier.self)])
        let object = NSObject()
        #expect(try unsafe associated.unsafeInvoke(GenericObjectCarrier.self, object) === object)
        let value = GenericObjCValue()
        for name in ["objcConstraintGeneric<A where A: ManagedSwiftFixtures.GenericObjCConstraint>",
                     "superclassConstraintGeneric<A where A: ManagedSwiftFixtures.GenericObjCValue>"] {
            let function = try await runtime.swiftFunction(named: "ManagedSwiftFixtures." + name + "(A) -> A",
                as: ((GenericObjCValue) -> GenericObjCValue).self, genericArguments: [.type(GenericObjCValue.self)])
            #expect(try unsafe function.unsafeInvoke(value) === value)
            await #expect(throws: ABIResolutionError.self) {
                try await runtime.swiftFunction(named: "ManagedSwiftFixtures." + name + "(A) -> A",
                    as: ((NSObject) -> NSObject).self, genericArguments: [.type(NSObject.self)])
            }
        }
    }

    @Test func returnedGenericClosuresPreserveCapturedValuesAndTypedErrors() async throws {
        let runtime = ABIRuntime.shared
        let factory = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeClosureGeneric<A>(A) -> (A) -> A",
            as: ((String) -> NativeSwiftClosure<(String) -> String>).self,
            genericArguments: [.type(String.self)])
        let text = String(repeating: "captured", count: 100)
        let closure = try unsafe factory.unsafeInvoke(text)
        #expect(try unsafe closure.unsafeInvoke("argument") == text)
        let throwing = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeThrowingClosureGeneric<A, B where B: Swift.Error>(A, B) -> (Swift.Bool) throws(B) -> A",
            as: ((String, ScalarFailure) -> NativeSwiftClosure<(Bool) throws(ScalarFailure) -> String>).self,
            genericArguments: [.type(String.self), .type(ScalarFailure.self)])
        let operation = try unsafe throwing.unsafeInvoke(text, ScalarFailure(77))
        #expect(try unsafe operation.unsafeInvoke(false) == text)
        do {
            _ = try unsafe operation.unsafeInvoke(true)
            Issue.record("Expected the captured typed error")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? ScalarFailure)?.code } == 77)
        }
    }

    @MainActor @Test func returnedGenericClosuresComposeWithAsyncAndPacks() async throws {
        let runtime = ABIRuntime.shared
        let asynchronous = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeAsyncClosureGeneric<A where A: Swift.Sendable>(A) -> nonisolated(nonsending) @Sendable (A) async -> A",
            as: ((String) -> NativeSwiftClosure<@Sendable (String) async -> String>).self,
            genericArguments: [.type(String.self)])
        let text = String(repeating: "asynchronous", count: 50)
        let operation = try unsafe asynchronous.unsafeInvoke(text)
        #expect(try unsafe await operation.unsafeInvoke("ignored") == text)
        let pack = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makePackClosureGeneric<each A>() -> (repeat A) -> (repeat A)",
            as: (() -> NativeSwiftClosure<(String, Int64) -> (String, Int64)>).self,
            genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
        let returned = try unsafe pack.unsafeInvoke()
        let output = try unsafe returned.unsafeInvoke(text, Int64(61))
        #expect(output.0 == text && output.1 == 61)
    }

    @Test func returnedGenericClosureReleasesItsCapturedValueAfterTheLastCopy() async throws {
        let state = GenericCaptureState()
        let factory = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeOwnedClosureGeneric<A>(A) -> () -> A",
            as: ((GenericCapture) -> NativeSwiftClosure<() -> GenericCapture>).self,
            genericArguments: [.type(GenericCapture.self)])
        var saved: NativeSwiftClosure<() -> GenericCapture>?
        do {
            let capture = GenericCapture(state)
            let original = try unsafe factory.unsafeInvoke(capture)
            saved = original
            #expect(try unsafe original.unsafeInvoke() === capture)
        }
        #expect(state.deaths.withLock { $0 } == 0)
        withExtendedLifetime(saved) { #expect(state.deaths.withLock { $0 } == 0) }
        saved = nil
        #expect(state.deaths.withLock { $0 } == 1)
    }

    @Test func parameterPacksIncludeEmptySingletonAndConstrainedBindings() async throws {
        let runtime = ABIRuntime.shared
        let name = "ManagedSwiftFixtures.packGeneric<each A>(repeat A) -> (repeat A)"
        let empty = try await runtime.swiftFunction(named: name, as: (() -> Void).self,
            genericArguments: [.pack([])])
        try unsafe empty.unsafeInvoke()
        let single = try await runtime.swiftFunction(named: name, as: ((String) -> String).self,
            genericArguments: [.pack([.type(String.self)])])
        let text = String(repeating: "pack", count: 100)
        #expect(try unsafe single.unsafeInvoke(text) == text)
        let values = try await runtime.swiftFunction(named: name,
            as: ((String, Int64, Bool) -> (String, Int64, Bool)).self,
            genericArguments: [.pack([.type(String.self), .type(Int64.self), .type(Bool.self)])])
        let output = try unsafe values.unsafeInvoke(text, Int64(42), true)
        let control = packGeneric(text, Int64(42), true)
        #expect(output.0 == control.0 && output.1 == control.1 && output.2 == control.2)
        let constrained = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.constrainedPackGeneric<each A where A: Swift.Equatable>(repeat A) -> (repeat A)",
            as: ((String, [Int64]) -> (String, [Int64])).self,
            genericArguments: [.pack([.type(String.self), .type([Int64].self)])])
        let paired = try unsafe constrained.unsafeInvoke(text, [Int64(1), 2])
        #expect(paired.0 == text && paired.1 == [1, 2])
    }

    @MainActor @Test func mixedAndNestedPacksPreserveTupleStorageAndSuspension() async throws {
        let runtime = ABIRuntime.shared
        let text = String(repeating: "nested pack", count: 50)
        let mixed = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.mixedPackGeneric<A, B>(A, repeat B) -> (Swift.Int8, A, repeat B, Swift.Int8)",
            as: ((String, Int64, Bool) -> (Int8, String, Int64, Bool, Int8)).self,
            genericArguments: [.type(String.self), .pack([.type(Int64.self), .type(Bool.self)])])
        let result = try unsafe mixed.unsafeInvoke(text, Int64(37), true)
        #expect(result.0 == 1 && result.1 == text && result.2 == 37 && result.3 && result.4 == 2)
        let nested = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.nestedPackGeneric<each A>((Swift.Int8, repeat A, Swift.Int8)) -> (Swift.Int8, repeat A, Swift.Int8)",
            as: (((Int8, String, Int64, Int8)) -> (Int8, String, Int64, Int8)).self,
            genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
        let tuple = try unsafe nested.unsafeInvoke((Int8(12), text, Int64(93), Int8(-8)))
        #expect(tuple.0 == 12 && tuple.1 == text && tuple.2 == 93 && tuple.3 == -8)
        let suspended = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedPackGeneric<each A>(repeat A) async -> (repeat A)",
            as: ((String, Int64) async -> (String, Int64)).self,
            genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
        let output = try unsafe await suspended.unsafeInvoke(text, Int64(57))
        #expect(output.0 == text && output.1 == 57)
    }

    @Test func packCallbacksConvertRuntimeValuesAndPreserveNativeHandleReferences() async throws {
        let runtime = ABIRuntime()
        let name = "ManagedSwiftFixtures.callbackPackGeneric<each A>((repeat A) -> (repeat A), repeat A) -> (repeat A)"
        let inspect = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.inspectRuntimePack<each A>((repeat A) throws -> Swift.Int64, repeat A) throws -> Swift.Int64",
            as: ((NativeSwiftClosure<(NativeSwiftValue, String) throws -> Int64>, Int64, String) throws -> Int64).self,
            genericArguments: [.pack([.type(Int64.self), .type(String.self)])])
        let inspectBody = try NativeSwiftClosure<(NativeSwiftValue, String) throws -> Int64> { value, text in
            #expect(text == "converted")
            return try value.take(as: Int64.self)
        }
        #expect(try unsafe inspect.unsafeInvoke(inspectBody, Int64(42), "converted") == 42)

        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
            as: ((Int64) -> NativeSwiftValue).self)
        let value = try unsafe make.unsafeInvoke(Int64(42))
        typealias Body = NativeSwiftClosure<(NativeSwiftValue, String) -> (NativeSwiftValue, String)>
        let call = try await runtime.swiftFunction(named: name,
            as: ((Body, NativeSwiftValue, String) -> (NativeSwiftValue, String)).self,
            genericArguments: [.pack([.type(NativeSwiftValue.self), .type(String.self)])])
        let body = try Body { ($0, $1) }
        let result = try unsafe call.unsafeInvoke(body, value, "handle")
        #expect(result.0 === value && result.1 == "handle")
        #expect(!value.isConsumed)
    }

    @Test func packShapeClassesAndCallbacksUseOneNativePackPerExpansion() async throws {
        let runtime = ABIRuntime.shared
        let markerInName = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.Rvz<A, B>(A, repeat B) -> (A, repeat B)",
            as: ((String, Int64) -> (String, Int64)).self,
            genericArguments: [.type(String.self), .pack([.type(Int64.self)])])
        let namedResult = try unsafe markerInName.unsafeInvoke("name", Int64(22))
        #expect(namedResult.0 == "name" && namedResult.1 == 22)
        let pair = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.pairedPackGeneric<each A, B where A.shape == B.shape>(repeat (A, B)) -> (repeat (B, A))",
            as: (((Int64, String), (Bool, Double)) -> ((String, Int64), (Double, Bool))).self,
            genericArguments: [.pack([.type(Int64.self), .type(Bool.self)]), .pack([.type(String.self), .type(Double.self)])])
        let output = try unsafe pair.unsafeInvoke((Int64(34), "value"), (true, 2.5))
        #expect(output.0.0 == "value" && output.0.1 == 34 && output.1.0 == 2.5 && output.1.1)
        let function = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.callbackPackGeneric<each A>((repeat A) -> (repeat A), repeat A) -> (repeat A)",
            as: ((NativeSwiftClosure<(String, Int64) -> (String, Int64)>, String, Int64) -> (String, Int64)).self,
            genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
        let body: NativeSwiftClosure<(String, Int64) -> (String, Int64)> = try NativeSwiftClosure { ($0 + "!", $1 + 1) }
        let called = try unsafe function.unsafeInvoke(body, "callback", Int64(17))
        #expect(called.0 == "callback!" && called.1 == 18)
    }

    @Test func genericTupleElementsUseTheirDeclaredConventions() async throws {
        let runtime = ABIRuntime.shared
        let tuple = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.tupleGeneric<A>((A, Swift.Int8, Swift.Int8)) -> (A, Swift.Int8, Swift.Int8)",
            as: (((String, Int8, Int8)) -> (String, Int8, Int8)).self,
            genericArguments: [.type(String.self)])
        let input: (String, Int8, Int8) = (String(repeating: "tuple", count: 100), -31, 72)
        let output = try unsafe tuple.unsafeInvoke(input)
        let control = tupleGeneric(input)
        #expect(output.0 == control.0 && output.1 == control.1 && output.2 == control.2)

        let pair = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.pairGeneric<A, B>((A, B)) -> (B, A)",
            as: (((String, Int64)) -> (Int64, String)).self,
            genericArguments: [.type(String.self), .type(Int64.self)])
        let swapped = try unsafe pair.unsafeInvoke((input.0, Int64(42)))
        #expect(swapped.0 == 42 && swapped.1 == input.0)

        let callback = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.tupleCallbackGeneric<A>((A, Swift.Int8), ((A, Swift.Int8)) -> (A, Swift.Int8, Swift.Int8)) -> (A, Swift.Int8, Swift.Int8)",
            as: (((String, Int8), NativeSwiftClosure<((String, Int8)) -> (String, Int8, Int8)>) -> (String, Int8, Int8)).self,
            genericArguments: [.type(String.self)])
        let body: NativeSwiftClosure<((String, Int8)) -> (String, Int8, Int8)> = try NativeSwiftClosure {
            ($0.0 + "!", $0.1, -$0.1)
        }
        let called = try unsafe callback.unsafeInvoke((input.0, Int8(27)), body)
        #expect(called.0 == input.0 + "!" && called.1 == 27 && called.2 == -27)
    }

    @MainActor @Test func mixedTupleResultsSurviveAsyncSuspension() async throws {
        let runtime = ABIRuntime.shared
        let large = LargeManagedValue(token: LifetimeToken(), a: 1, b: 2, c: 3, d: 4)
        let input = (String(repeating: "large", count: 100), large, Int64(91))
        let direct = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.largeTupleGeneric<A>((A, ManagedSwiftFixtures.LargeManagedValue, Swift.Int64)) -> (A, ManagedSwiftFixtures.LargeManagedValue, Swift.Int64)",
            as: (((String, LargeManagedValue, Int64)) -> (String, LargeManagedValue, Int64)).self,
            genericArguments: [.type(String.self)])
        let output = try unsafe direct.unsafeInvoke(input)
        #expect(output.0 == input.0 && output.1.token === large.token && output.1.d == 4 && output.2 == 91)
        let suspended = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedLargeTupleGeneric<A>((A, ManagedSwiftFixtures.LargeManagedValue, Swift.Int64)) async -> (A, ManagedSwiftFixtures.LargeManagedValue, Swift.Int64)",
            as: (((String, LargeManagedValue, Int64)) async -> (String, LargeManagedValue, Int64)).self,
            genericArguments: [.type(String.self)])
        let awaited = try unsafe await suspended.unsafeInvoke(input)
        #expect(awaited.0 == input.0 && awaited.1.token === large.token && awaited.1.d == 4 && awaited.2 == 91)
        let pair = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedPairGeneric<A, B>((A, B)) async -> (B, A)",
            as: (((String, Int64)) async -> (Int64, String)).self,
            genericArguments: [.type(String.self), .type(Int64.self)])
        let swapped = try unsafe await pair.unsafeInvoke((input.0, Int64(55)))
        #expect(swapped.0 == 55 && swapped.1 == input.0)
    }

    @MainActor @Test func genericAsyncCallbacksPreserveIsolationTupleResultsAndErrors() async throws {
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedTransformGeneric<A, B>(A, nonisolated(nonsending) (A) async throws -> (B, Swift.Int8)) async throws -> (B, Swift.Int8)",
            as: ((String, NativeSwiftClosure<(String) async throws -> (String, Int8)>) async throws -> (String, Int8)).self,
            genericArguments: [.type(String.self), .type(String.self)])
        let operation: @Sendable (String) async throws -> (String, Int8) = { value in
            MainActor.preconditionIsolated()
            await Task.yield()
            MainActor.preconditionIsolated()
            if value.isEmpty { throw GenericConversionFailure.rejected }
            return (value + "!", 42)
        }
        let body = try NativeSwiftClosure<(String) async throws -> (String, Int8)>(operation)
        let text = String(repeating: "async tuple", count: 50)
        let output = try unsafe await function.unsafeInvoke(text, body)
        #expect(output.0 == text + "!" && output.1 == 42)
        do {
            _ = try unsafe await function.unsafeInvoke("", body)
            Issue.record("Expected the callback's original error")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { $0 is GenericConversionFailure })
        }
    }

    @Test func multipleBindingsConstraintsAndCompositeValuesMatchNativeCalls() async throws {
        let runtime = ABIRuntime.shared
        let equal = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.equalGeneric<A where A: Swift.Equatable>(A, A) -> Swift.Bool",
            as: (([String], [String]) -> Bool).self, genericArguments: [.type([String].self)])
        let values = ["first", String(repeating: "second", count: 80)]
        #expect(try unsafe equal.unsafeInvoke(values, values) == equalGeneric(values, values))
        #expect(try unsafe equal.unsafeInvoke(values, []) == equalGeneric(values, []))
        let select = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.selectGeneric<A, B where A == B.Element, B: Swift.Collection>(A, B) -> A",
            as: ((String, [String]) -> String).self, genericArguments: [.type(String.self), .type([String].self)])
        #expect(try unsafe select.unsafeInvoke("fallback", values) == selectGeneric("fallback", values))
        #expect(try unsafe select.unsafeInvoke("fallback", []) == "fallback")
        let optional = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.optionalGeneric<A>(A?) -> A?",
            as: ((String?) -> String?).self, genericArguments: [.type(String.self)])
        #expect(try unsafe optional.unsafeInvoke(values[1]) == optionalGeneric(Optional(values[1])))
        #expect(try unsafe optional.unsafeInvoke(nil) == nil)
    }

    @Test func genericCallbacksAcceptArgumentsAndPreserveNativeErrors() async throws {
        let transform = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.transformGeneric<A, B>([A], (A) throws -> B) throws -> [B]",
            as: (([Int64], NativeSwiftClosure<(Int64) throws -> String>) throws -> [String]).self,
            genericArguments: [.type(Int64.self), .type(String.self)])
        let callback: NativeSwiftClosure<(Int64) throws -> String> = try NativeSwiftClosure { value in
            if value < 0 { throw GenericConversionFailure.rejected }
            return "value: \(value)"
        }
        let values: [Int64] = [1, 2, 3]
        #expect(try unsafe transform.unsafeInvoke(values, callback) == transformGeneric(values) { "value: \($0)" })
        do {
            _ = try unsafe transform.unsafeInvoke([-1], callback)
            Issue.record("Expected the original callback error")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { $0 is GenericConversionFailure })
        }
    }

    @MainActor @Test func genericAsyncAndTypedErrorsPreserveValuesAcrossSuspension() async throws {
        let runtime = ABIRuntime.shared
        let echo = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedGeneric<A>(A) async -> A",
            as: ((String) async -> String).self, genericArguments: [.type(String.self)])
        let text = String(repeating: "suspended", count: 100)
        #expect(try unsafe await echo.unsafeInvoke(text) == text)
        let failure = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.genericFailure<A, B where B: Swift.Error>(A, B, Swift.Bool) throws(B) -> A",
            as: ((String, ScalarFailure, Bool) throws(ScalarFailure) -> String).self,
            genericArguments: [.type(String.self), .type(ScalarFailure.self)])
        #expect(try unsafe failure.unsafeInvoke(text, ScalarFailure(42), false) == text)
        do {
            _ = try unsafe failure.unsafeInvoke(text, ScalarFailure(42), true)
            Issue.record("Expected the typed failure")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? ScalarFailure)?.code } == 42)
        }
        let suspended = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedGenericFailure<A, B where B: Swift.Error>(A, B, Swift.Bool) async throws(B) -> A",
            as: ((String, ScalarFailure, Bool) async throws(ScalarFailure) -> String).self,
            genericArguments: [.type(String.self), .type(ScalarFailure.self)])
        #expect(try unsafe await suspended.unsafeInvoke(text, ScalarFailure(43), false) == text)
        do {
            _ = try unsafe await suspended.unsafeInvoke(text, ScalarFailure(43), true)
            Issue.record("Expected the suspended typed failure")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? ScalarFailure)?.code } == 43)
        }
    }

    @Test func genericStorageUsesTheActualTypeInsteadOfItsForeignConversion() async throws {
        let runtime = ABIRuntime.shared
        let echo = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
            as: ((GenericPointerWrapper?) -> GenericPointerWrapper?).self, genericArguments: [.type(GenericPointerWrapper?.self)])
        let value = GenericPointerWrapper(pointer: try #require(UnsafeRawPointer(bitPattern: 0x1000)), marker: 42)
        #expect(MemoryLayout<GenericPointerWrapper?>.size > MemoryLayout<UnsafeRawPointer>.size)
        #expect(try unsafe echo.unsafeInvoke(value) == echoGeneric(Optional(value)))
        #expect(try unsafe echo.unsafeInvoke(nil) == nil)

        let marked = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
            as: ((NativeSwiftBorrowing<String>) -> NativeSwiftBorrowing<String>).self,
            genericArguments: [.type(NativeSwiftBorrowing<String>.self)])
        let input = NativeSwiftBorrowing(String(repeating: "owned", count: 100))
        #expect(try unsafe marked.unsafeInvoke(input).value == echoGeneric(input).value)

        let closure = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
            as: ((NativeSwiftClosure<() -> Int64>) -> NativeSwiftClosure<() -> Int64>).self,
            genericArguments: [.type(NativeSwiftClosure<() -> Int64>.self)])
        let returned = try unsafe closure.unsafeInvoke(NativeSwiftClosure { Int64(42) })
        #expect(try unsafe returned.unsafeInvoke() == 42)
    }

    @MainActor @Test func callbacksPreserveClosureWrappersUsedAsNativeGenericData() async throws {
        typealias Value = NativeSwiftClosure<() -> Int64>
        let runtime = ABIRuntime.shared
        let input = try Value { Int64(42) }
        let transform = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.transformGeneric<A, B>([A], (A) throws -> B) throws -> [B]",
            as: (([Value], NativeSwiftClosure<(Value) throws -> Int64>) throws -> [Int64]).self,
            genericArguments: [.type(Value.self), .type(Int64.self)])
        let callback = try NativeSwiftClosure<(Value) throws -> Int64> { value in
            try unsafe value.copy().unsafeInvoke()
        }
        #expect(try unsafe transform.unsafeInvoke([input], callback) == [42])

        let copyForeignData = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.callRuntimeCopy<A>((A) -> A, A) -> A",
            as: ((NativeSwiftClosure<(GenericPointerWrapper) -> GenericPointerWrapper>, GenericPointerWrapper) -> GenericPointerWrapper).self,
            genericArguments: [.type(GenericPointerWrapper.self)])
        let foreignIdentity = try NativeSwiftClosure<(GenericPointerWrapper) -> GenericPointerWrapper> { $0 }
        let foreign = GenericPointerWrapper(pointer: try #require(UnsafeRawPointer(bitPattern: 0x1000)), marker: 42)
        #expect(try unsafe copyForeignData.unsafeInvoke(foreignIdentity, foreign) == foreign)
        #expect(throws: ABIResolutionError.self) { try unsafe foreignIdentity.unsafeInvoke(foreign) as GenericPointerWrapper }

        let produce = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> Value>) -> Value).self,
            genericArguments: [.type(Value.self)])
        let returned = try unsafe NativeSwiftClosure<() -> Value>.withUnsafeNonescaping({ input }) { body in
            #expect(throws: ABIResolutionError.self) { try unsafe body.unsafeInvoke() as Value }
            return try unsafe produce.unsafeInvoke(body)
        }
        #expect(try unsafe returned.unsafeInvoke() == 42)
    }

    @Test func capturingCallbacksMatchCompilerGeneratedCalls() async throws {
        let runtime = ABIRuntime.shared
        let boolean = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> Bool>) -> Bool).self, genericArguments: [.type(Bool.self)])
        for value in [true, false] {
            let callback = try NativeSwiftClosure { value }
            #expect(try unsafe boolean.unsafeInvoke(callback) == referenceGenericBool(value))
        }
        let stringType = try await runtime.swiftType(named: "Swift.String")
        let string = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> String>) -> String).self, genericArguments: [.type(stringType)])
        let input = String(repeating: "managed", count: 100)
        let callback = try NativeSwiftClosure { input + "!" }
        for _ in 0..<20 {
            #expect(try unsafe string.unsafeInvoke(callback) == referenceGenericString(input))
        }
    }

    @MainActor @Test func nonescapingApplyKeepsCallerIsolation() async throws {
        let run = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> Bool>) -> Bool).self, genericArguments: [.type(Bool.self)])
        var calls = 0
        let result = try unsafe NativeSwiftClosure<() -> Bool>.withUnsafeNonescaping({ calls += 1; return calls == 1 }) {
            try unsafe run.unsafeInvoke($0)
        }
        #expect(result && calls == 1)
    }

    @Test func genericArgumentsAndResultsPreserveReferenceOwnership() async throws {
        let echo = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
            as: ((NSObject) -> NSObject).self, genericArguments: [.type(NSObject.self)])
        weak var observed: NSObject?
        var result: NSObject?
        do {
            let object = NSObject()
            observed = object
            result = try unsafe echo.unsafeInvoke(object)
            #expect(result === object)
        }
        withExtendedLifetime(result) { #expect(observed != nil) }
        result = nil
        #expect(observed == nil)
        let choose = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.chooseGeneric<A>(A, () -> A, Swift.Bool) -> A",
            as: ((String, NativeSwiftClosure<() -> String>, Bool) -> String).self, genericArguments: [.type(String.self)])
        let callback = try NativeSwiftClosure { "from callback" }
        #expect(try unsafe choose.unsafeInvoke("input", callback, false) == "input")
        #expect(try unsafe choose.unsafeInvoke("input", callback, true) == "from callback")
    }

    @Test func failedConversionDoesNotEnterNativeCode() async throws {
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.countedGeneric<A>(A, Swift.Int64, Swift.UnsafeMutablePointer<Swift.Int32>) -> A",
            as: ((String, RejectGenericArgument, UnsafeMutablePointer<Int32>) -> String).self, genericArguments: [.type(String.self)])
        var calls: Int32 = 0
        try withUnsafeMutablePointer(to: &calls) { pointer in
            #expect(throws: GenericConversionFailure.rejected) {
                try unsafe function.unsafeInvoke(String(repeating: "input", count: 100), RejectGenericArgument(), pointer)
            }
        }
        #expect(calls == 0)
    }

    @Test func reabstractedNativeCopiesRetainCapturesAndReleaseAfterFinalUse() async throws {
        let runtime = ABIRuntime.shared
        let store = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.storeGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> String>) -> String).self, genericArguments: [.type(String.self)])
        let fire = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.fireGeneric()", as: (() -> Void).self)
        let clear = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.clearGeneric()", as: (() -> Void).self)
        let state = GenericCaptureState()
        do {
            let capture = GenericCapture(state)
            let callback = try NativeSwiftClosure { capture.value() }
            #expect(try unsafe store.unsafeInvoke(callback).count == 700)
        }
        #expect(state.deaths.withLock { $0 } == 0)
        try unsafe fire.unsafeInvoke()
        try unsafe clear.unsafeInvoke()
        #expect(state.calls.withLock { $0 } == 2)
        #expect(state.deaths.withLock { $0 } == 1)
    }

    @Test func reabstractionIsReleasedWhenLaterConversionFails() async throws {
        let runtime = ABIRuntime.shared
        let function = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.genericCallbackThenArgument<A>(() -> A, Swift.Int64) -> A",
            as: ((NativeSwiftClosure<() -> String>, RejectGenericArgument) -> String).self, genericArguments: [.type(String.self)])
        let state = GenericCaptureState()
        do {
            let capture = GenericCapture(state)
            let callback = try NativeSwiftClosure { capture.value() }
            #expect(throws: GenericConversionFailure.rejected) { try unsafe function.unsafeInvoke(callback, RejectGenericArgument()) }
        }
        #expect(state.calls.withLock { $0 } == 0)
        #expect(state.deaths.withLock { $0 } == 1)
    }

    @Test func emptyGenericResultsRemainFormallyIndirect() async throws {
        let run = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> Void>) -> Void).self, genericArguments: [.type(Void.self)])
        let calls = GenericCaptureState()
        let body = try NativeSwiftClosure { calls.calls.withLock { $0 += 1 } }
        try unsafe run.unsafeInvoke(body)
        #expect(calls.calls.withLock { $0 } == 1)
    }

    @Test func incompatibleSubstitutionsAndUnsupportedFormalShapesFailPreparation() async throws {
        let runtime = ABIRuntime.shared
        await #expect(throws: ABIResolutionError.self) {
            try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
                as: ((Bool) -> Bool).self, genericArguments: [.type(String.self)])
        }
        for declaration in ["Example.run<A, B>(A) -> A", "Example.run<A where A: Swift.Equatable>(A) -> A",
                            "Example.run<A>(Swift.Array<A>) -> A", "Example.run<A>(A) async -> A",
                            "Example.run<A>((A) -> A) -> A"] {
            await #expect(throws: ABIResolutionError.self) {
                try await runtime.swiftFunction(named: declaration, as: ((Bool) -> Bool).self, genericArguments: [.type(Bool.self)])
            }
        }
    }
}
