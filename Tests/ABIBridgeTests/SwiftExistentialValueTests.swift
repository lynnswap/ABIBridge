#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import ManagedSwiftFixtures
import Testing

struct SwiftExistentialValueTests {
#if DEBUG
    @Test func declarationCallbackAuthenticationPreservesClassExistentialIdentity() async throws {
        typealias Signature = (NativeSwiftClosure<(ManyObjectProtocols) -> ManyObjectProtocols>, ManyObjectProtocols) -> ManyObjectProtocols
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.applyManyClassExistentialClosure(_:_:)", as: Signature.self)
        let plan = try SwiftGenericCallPlan(symbol: function.symbol, genericArguments: [],
            signature: SwiftFunctionSignature(Signature.self), resolver: .shared)
        let closure = try #require(plan.arguments.first?.closure)
        // The arm64e compiler fixture hashes the formally class-based type,
        // despite passing this many object/witness components indirectly.
        #expect(closure.discriminator == 59948)
    }

    @Test func metadataKindsAndAuthenticationKeepDistinctContracts() throws {
        #expect(SwiftExistentialRepresentation((any ExistentialValue).Type.self) == nil)
        #expect(SwiftExistentialRepresentation((any ExistentialValue.Type).self) == nil)
        #expect(SwiftExistentialRepresentation((any Collection<Int>).self) != nil)
        #expect(try SwiftValueCodec<any Collection<Int>>().type.size == MemoryLayout<any Collection<Int>>.size)
        // Swift 6.3 reports one word of generic storage for this composition,
        // while its native declaration uses object and witness pointers.
        #expect(throws: ABIResolutionError.self) { _ = try SwiftValueCodec<(any Error & AnyObject)>() }
        #expect(try swiftClosureAuthType(Any.self) == "-indirect")
        #expect(try swiftClosureAuthType(ManyObjectProtocols.self) == "-class")
        #expect(swiftClosureDiscriminator(parameters: [try swiftClosureAuthType(Any.self)], result: try swiftClosureAuthType(Any.self)) == 55683)
        #expect(swiftClosureDiscriminator(parameters: [try swiftClosureAuthType((any ExistentialObjectValue)?.self)], result: try swiftClosureAuthType((any ExistentialObjectValue)?.self)) == 30130)
        #expect(swiftClosureDiscriminator(parameters: [try swiftClosureAuthType((any Error)?.self)], result: try swiftClosureAuthType((any Error)?.self)) == 1845)
    }
#endif
    @Test func extendedExistentialsKeepAssociatedTypeConstraints() async throws {
        let runtime = ABIRuntime.shared
        let collection = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoExtendedCollection(_:)",
            as: ((any Collection<Int>) -> any Collection<Int>).self)
        let ordinaryResult: any Collection<Int> = try unsafe collection.unsafeInvoke([1, 2, 3])
        #expect(Array(ordinaryResult) == [1, 2, 3])
        let source = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoExtendedSource(_:)",
            as: ((any ExistentialSource<Int>) -> any ExistentialSource<Int>).self)
        let value = ExistentialIntSource(42)
        #expect(try unsafe source.unsafeInvoke(value) === value)
        let generic = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGenericExtendedCollection<A>(any Swift.Collection<Self.Element == A>) -> any Swift.Collection<Self.Element == A>",
            as: ((any Collection<Int>) -> any Collection<Int>).self, genericArguments: [.type(Int.self)])
        let genericResult: any Collection<Int> = try unsafe generic.unsafeInvoke([40, 2])
        #expect(Array(genericResult) == [40, 2])
        let made = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeGenericExtendedCollection<A>(A) -> any Swift.Collection<Self.Element == A>",
            as: ((Int) -> any Collection<Int>).self, genericArguments: [.type(Int.self)])
        let madeResult: any Collection<Int> = try unsafe made.unsafeInvoke(42)
        #expect(Array(madeResult) == [42])
        let runtimeOnly = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeGenericExtendedCollection<A>(A) -> any Swift.Collection<Self.Element == A>",
            as: ((Int) -> NativeSwiftValue).self, genericArguments: [.type(Int.self)])
        let owned = try unsafe runtimeOnly.unsafeInvoke(42)
        let copied = try owned.withCopy { value -> [Int]? in
            guard let collection = value as? any Collection<Int> else { return nil }
            return Array(collection)
        }
        #expect(copied == [42])
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGenericExtendedCollection<A>(any Swift.Collection<Self.Element == A>) -> any Swift.Collection<Self.Element == A>",
                as: ((any Collection<Int>) -> any Collection<Int>).self, genericArguments: [.type(String.self)])
        }
    }

    @Test func runtimeOnlyExistentialsConstructMissingProviderShapes() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeFreshExistential<A>(A) -> any ManagedSwiftFixtures.FreshExistentialSource<Self.Element == A>",
            as: ((Int) -> NativeSwiftValue).self, genericArguments: [.type(Int.self)])
        let result = try unsafe call.unsafeInvoke(42)
        #expect(try result.withCopy { ($0 as? any CustomStringConvertible)?.description } == "42")
        #expect(result.type.name.contains("FreshExistentialSource"))
        let pair = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeFreshExistentialPair<A, B>(A, B) -> any ManagedSwiftFixtures.FreshExistentialPair<Self.First == A, Self.Second == B>",
            as: ((Int, String) -> NativeSwiftValue).self, genericArguments: [.type(Int.self), .type(String.self)])
        let paired = try unsafe pair.unsafeInvoke(42, "value")
        #expect(try paired.withCopy { ($0 as? any CustomStringConvertible)?.description } == "42:value")
        let object = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeFreshExistentialClass<A>(A) -> any ManagedSwiftFixtures.FreshExistentialClass<Self.Element == A>",
            as: ((Int) -> NativeSwiftValue).self, genericArguments: [.type(Int.self)])
        let objectValue = try unsafe object.unsafeInvoke(43)
        #expect(try objectValue.withCopy { ($0 as? any CustomStringConvertible)?.description } == "43")
    }

    @Test func compositionShapesKeepAssociatedTypeProtocolIdentity() async throws {
        let runtime = ABIRuntime.shared
        let left = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeLeftConstrainedComposition() -> any ManagedSwiftFixtures.RuntimeExtendedLeft & ManagedSwiftFixtures.RuntimeExtendedRight<Self.ManagedSwiftFixtures.RuntimeExtendedLeft.Element == Swift.Int>",
            as: (() -> NativeSwiftValue).self)
        let right = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeRightConstrainedComposition() -> any ManagedSwiftFixtures.RuntimeExtendedLeft & ManagedSwiftFixtures.RuntimeExtendedRight<Self.ManagedSwiftFixtures.RuntimeExtendedRight.Element == Swift.Int>",
            as: (() -> NativeSwiftValue).self)
        let first = try unsafe left.unsafeInvoke()
        let second = try unsafe right.unsafeInvoke()
        #expect(first.type != second.type)
        #expect(first.type.name.contains("RuntimeExtendedLeft.Element == Swift.Int"))
        #expect(second.type.name.contains("RuntimeExtendedRight.Element == Swift.Int"))
        #expect(try first.withCopy { ($0 as? any CustomStringConvertible)?.description } == "both")
        #expect(try second.withCopy { ($0 as? any CustomStringConvertible)?.description } == "both")
    }

    @Test func extendedExistentialCallbacksUseTheirContainerConvention() async throws {
        let runtime = ABIRuntime.shared
        typealias Source = NativeSwiftClosure<(any ExistentialSource<Int>) -> any ExistentialSource<Int>>
        let source = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.applyExtendedSource(_:_:)",
            as: ((Source, any ExistentialSource<Int>) -> any ExistentialSource<Int>).self)
        let value = ExistentialIntSource(42)
        #expect(try unsafe source.unsafeInvoke(.init { $0 }, value) === value)
        typealias CollectionBody = NativeSwiftClosure<(any Collection<Int>) -> any Collection<Int>>
        let collection = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.applyExtendedCollection(_:_:)",
            as: ((CollectionBody, any Collection<Int>) -> any Collection<Int>).self)
        let callback = try CollectionBody { $0 }
        let result: any Collection<Int> = try unsafe collection.unsafeInvoke(callback, [42])
        #expect(Array(result) == [42])
    }

    @Test func anyAndProtocolContainersOpenInlineAndBoxedValues() async throws {
        let runtime = ABIRuntime.shared
        let any = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoAny(_:)", as: ((Any) -> Any).self)
        let echo = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoExistential(_:)",
            as: ((any ExistentialValue) -> any ExistentialValue).self)
        let open = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.openExistential(_:)",
            as: ((any ExistentialValue) -> Int64).self)
        let values: [any ExistentialValue] = [InlineExistentialValue(41), BoxedExistentialValue(ErrorLifetimeToken(), 42)]
        for value in values {
            let erased = try unsafe any.unsafeInvoke(value)
            #expect((erased as? any ExistentialValue)?.number == value.number)
            let returned = try unsafe echo.unsafeInvoke(value)
            #expect(returned.number == value.number)
            #expect(try unsafe open.unsafeInvoke(returned) == value.number)
        }
        #expect(try unsafe any.unsafeInvoke("ordinary") as? String == "ordinary")
    }

    @Test func ownedResultsKeepBoxedPayloadsAliveUntilFinalRelease() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.echoAny(_:)", as: ((Any) -> Any).self)
        let counts = ArgumentCounts()
        weak var observed: ErrorLifetimeToken?
        var result: Any?
        do {
            let token = ErrorLifetimeToken { counts.destroyed() }
            observed = token
            result = try unsafe call.unsafeInvoke(BoxedExistentialValue(token, 42))
        }
        #expect(observed != nil && (result as? BoxedExistentialValue)?.number == 42)
        var copy = result
        result = nil
        #expect(observed != nil && (copy as? BoxedExistentialValue)?.number == 42)
        copy = nil
        #expect(observed == nil && counts.destructions == 1)
    }

    @Test func compositionsKeepEveryProtocolWitness() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.echoComposition(_:)",
            as: ((any ExistentialValue & ExistentialLabel) -> any ExistentialValue & ExistentialLabel).self)
        for value: any ExistentialValue & ExistentialLabel in [InlineExistentialValue(41), BoxedExistentialValue(ErrorLifetimeToken(), 42)] {
            let result = try unsafe call.unsafeInvoke(value)
            #expect(result.number == value.number && result.label == value.label)
        }
    }

    @Test func classConstrainedContainersUseDirectAndLargeIndirectLayouts() async throws {
        let runtime = ABIRuntime.shared
        let small = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoClassExistential(_:)",
            as: ((any ExistentialObjectValue) -> any ExistentialObjectValue).self)
        let large = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoManyClassExistential(_:)",
            as: ((ManyObjectProtocols) -> ManyObjectProtocols).self)
        let object = ExistentialObject(ErrorLifetimeToken(), 42)
        #expect(try unsafe small.unsafeInvoke(object) === object)
        #expect(try unsafe large.unsafeInvoke(object) === object)
    }

    @Test func errorExistentialPreservesItsBoxAndPayload() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.echoErrorExistential(_:)",
            as: ((any Error) -> any Error).self)
        let token = ErrorLifetimeToken()
        let result = try unsafe call.unsafeInvoke(ManagedFailure(token, 42))
        #expect((result as? ManagedFailure)?.token === token && (result as? ManagedFailure)?.code == 42)
    }

    @Test func optionalContainersDistinguishNilFromPayloads() async throws {
        let runtime = ABIRuntime.shared
        let any = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoOptionalAny(_:)", as: ((Any?) -> Any?).self)
        let value = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoOptionalExistential(_:)",
            as: (((any ExistentialValue)?) -> (any ExistentialValue)?).self)
        let object = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoOptionalClass(_:)",
            as: (((any ExistentialObjectValue)?) -> (any ExistentialObjectValue)?).self)
        let error = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoOptionalError(_:)",
            as: (((any Error)?) -> (any Error)?).self)
        #expect(try unsafe any.unsafeInvoke(nil) == nil)
        #expect(try unsafe any.unsafeInvoke("value") as? String == "value")
        #expect(try unsafe value.unsafeInvoke(nil) == nil)
        #expect(try unsafe value.unsafeInvoke(InlineExistentialValue(42))?.number == 42)
        let reference = ExistentialObject(ErrorLifetimeToken(), 42)
        #expect(try unsafe object.unsafeInvoke(nil) == nil)
        #expect(try unsafe object.unsafeInvoke(reference) === reference)
        #expect(try unsafe error.unsafeInvoke(nil) == nil)
        #expect((try unsafe error.unsafeInvoke(ScalarFailure(42)) as? ScalarFailure)?.code == 42)
    }

    @Test func consumingAndInoutPreserveFailureSemantics() async throws {
        let runtime = ABIRuntime.shared
        let consume = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.consumeExistential(_:_:)",
            as: ((NativeSwiftConsuming<any ExistentialValue>, Bool) throws(ScalarFailure) -> Int64).self)
        let replace = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.replaceExistential(_:_:_:)",
            as: ((NativeSwiftInout<any ExistentialValue>, any ExistentialValue, Bool) throws(ScalarFailure) -> Void).self)
        let value: any ExistentialValue = BoxedExistentialValue(ErrorLifetimeToken(), 42)
        #expect(try unsafe consume.unsafeInvoke(.init(value), false) == 42)
        do { _ = try unsafe consume.unsafeInvoke(.init(value), true); Issue.record("Expected failure") }
        catch let error as NativeSwiftError { error.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) } }
        #expect(value.number == 42)
        let buffer = NativeSwiftInout<any ExistentialValue>(InlineExistentialValue(1))
        do { try unsafe replace.unsafeInvoke(buffer, value, true); Issue.record("Expected failure") }
        catch let error as NativeSwiftError { error.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) } }
        #expect(buffer.value.number == 42 && buffer.value is BoxedExistentialValue)
    }

    @Test func asyncContainersRetainValuesAcrossSuspensionAndCancellation() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.asyncExistential(_:_:_:)",
            as: (@concurrent (AsyncGate, any ExistentialValue, Bool) async throws(ScalarFailure) -> any ExistentialValue).self)
        for cancel in [false, true] {
            let gate = AsyncGate()
            let counts = ArgumentCounts()
            weak var observed: ErrorLifetimeToken?
            let task: Task<any ExistentialValue, any Error>
            do {
                let token = ErrorLifetimeToken { counts.destroyed() }
                observed = token
                let value: any ExistentialValue = BoxedExistentialValue(token, 42)
                task = Task { try unsafe await call.unsafeInvoke(gate, value, false) }
            }
            await gate.waitUntilSuspended()
            #expect(observed != nil)
            if cancel { task.cancel() }
            await gate.open()
            do { #expect(try await task.value.number == 42 && !cancel) }
            catch let error as NativeSwiftError {
                error.withUnderlyingError { #expect(cancel && ($0 as? ScalarFailure)?.code == 42) }
                #expect(observed == nil && counts.destructions == 1)
            }
        }
    }

    @Test func generatedAndReturnedClosuresCarryOpaqueContainers() async throws {
        typealias Callback = NativeSwiftClosure<(any ExistentialValue) -> any ExistentialValue>
        let runtime = ABIRuntime.shared
        let apply = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.applyExistentialClosure(_:_:)",
            as: ((Callback, any ExistentialValue) -> any ExistentialValue).self)
        let callback = try Callback { InlineExistentialValue($0.number + 1) }
        #expect(try unsafe apply.unsafeInvoke(callback, BoxedExistentialValue(ErrorLifetimeToken(), 41)).number == 42)
        let factory = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeExistentialClosure(_:)",
            as: ((any ExistentialValue) -> Callback).self)
        let stored = try unsafe factory.unsafeInvoke(BoxedExistentialValue(ErrorLifetimeToken(), 42))
        #expect(try unsafe stored.unsafeInvoke(InlineExistentialValue(0)).number == 42)
        #expect(try unsafe stored.unsafeInvoke(InlineExistentialValue(7)).number == 7)

        let applyAny = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.applyAnyExistentialClosure(_:_:)",
            as: ((NativeSwiftClosure<(Any) -> Any>, Any) -> Any).self)
        #expect(try unsafe applyAny.unsafeInvoke(NativeSwiftClosure<(Any) -> Any> { $0 }, "value") as? String == "value")
    }

    @Test func generatedClassAndErrorCallbacksUseTheirDistinctConventions() async throws {
        let runtime = ABIRuntime.shared
        let apply = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.applyClassExistentialClosure(_:_:)",
            as: ((NativeSwiftClosure<(any ExistentialObjectValue) -> any ExistentialObjectValue>, any ExistentialObjectValue) -> any ExistentialObjectValue).self)
        let large = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.applyManyClassExistentialClosure(_:_:)",
            as: ((NativeSwiftClosure<(ManyObjectProtocols) -> ManyObjectProtocols>, ManyObjectProtocols) -> ManyObjectProtocols).self)
        let error = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.applyErrorExistentialClosure(_:_:)",
            as: ((NativeSwiftClosure<(any Error) -> any Error>, any Error) -> any Error).self)
        let object = ExistentialObject(ErrorLifetimeToken(), 42)
        #expect(try unsafe apply.unsafeInvoke(.init { $0 }, object) === object)
        #expect(try unsafe large.unsafeInvoke(.init { $0 }, object) === object)
        #expect((try unsafe error.unsafeInvoke(.init { $0 }, ScalarFailure(42)) as? ScalarFailure)?.code == 42)
    }

    @Test func optionalCallbacksPreserveNilAndAuthentication() async throws {
        let runtime = ABIRuntime.shared
        typealias Object = NativeSwiftClosure<((any ExistentialObjectValue)?) -> (any ExistentialObjectValue)?>
        typealias Failure = NativeSwiftClosure<((any Error)?) -> (any Error)?>
        let object = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.applyOptionalClassClosure(_:_:)",
            as: ((Object, (any ExistentialObjectValue)?) -> (any ExistentialObjectValue)?).self)
        let error = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.applyOptionalErrorClosure(_:_:)",
            as: ((Failure, (any Error)?) -> (any Error)?).self)
        #expect(try unsafe object.unsafeInvoke(.init { $0 }, nil) == nil)
        #expect(try unsafe error.unsafeInvoke(.init { $0 }, nil) == nil)
    }

    @Test func asyncGeneratedCallbackReturnsAnOwnedExistential() async throws {
        typealias Callback = NativeSwiftClosure<@Sendable @concurrent (any ExistentialValue) async -> any ExistentialValue>
        let body: @Sendable (any ExistentialValue) async -> any ExistentialValue = { value in
            await Task.yield()
            return InlineExistentialValue(value.number + 1)
        }
        let apply = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.applyAsyncExistentialClosure(_:_:)",
            as: (@concurrent (Callback, any ExistentialValue) async -> any ExistentialValue).self)
        #expect(try unsafe await apply.unsafeInvoke(Callback(body), InlineExistentialValue(41)).number == 42)
    }
}
